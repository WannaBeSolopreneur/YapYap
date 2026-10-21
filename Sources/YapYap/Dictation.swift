import AppKit
import os
import AVFoundation
import Carbon
import YapYapCore
import Speech

/// Hold the dictation shortcut, talk, let go: what you said is typed into the app you were in.
/// Speech recognition runs on device. Everything here runs on the main thread.
final class Dictation {
    enum Phase {
        case idle
        /// Asking for permission, loading the speech model, starting the mic.
        case starting
        case listening
        /// Shortcut released; waiting for the last words, then typing them.
        case finishing
        /// Apple Intelligence is tidying the text.
        case polishing
        /// A saved item was asked for: "Pasting Email address…", a moment to press Esc.
        case confirming
    }

    /// How to clean up what was said before typing it.
    struct Cleanup {
        /// Strip um, uh and the like.
        var removeFillers = true
        /// Then tidy with Apple Intelligence, if it's available.
        var polish = true

        static var current: Cleanup {
            Cleanup(removeFillers: Settings.shared.removeFillers, polish: Settings.shared.polishDictation)
        }
    }

    private(set) var phase = Phase.idle
    /// Listening without the shortcut held: a quick tap started it, and the next press, Done or
    /// Esc ends it.
    private(set) var handsFree = false
    /// Whether the session that just typed its text was hands-free (for the anonymous stats).
    private(set) var lastWasHandsFree = false
    /// "parakeet" or "apple", for the usage stats.
    private(set) var lastEngine = "apple"
    /// What has been heard so far, for the live preview.
    private(set) var text = ""
    /// Microphone loudness, 0…1.
    private(set) var level: Float = 0

    var onStateChange: (() -> Void)?
    var onMessage: ((String) -> Void)?
    /// The final text, once typed (or left on the clipboard).
    var onTyped: ((String) -> Void)?
    /// Nothing that takes text had focus: the words are on the clipboard, to show with a Copy button.
    var onNoTextBox: ((String) -> Void)?
    /// A saved item was pasted (or copied, when there was nowhere to paste it).
    var onSavedPasted: ((SavedItem) -> Void)?
    /// A saved item with nowhere to paste it: on the clipboard, to show with a Copy button.
    var onSavedNoTextBox: ((SavedItem) -> Void)?

    private let makeTranscriber: () -> Transcriber
    private let inserter: TextInserting
    private let polisher: TextPolishing
    private let cleanup: () -> Cleanup
    private let saved: (String) -> SavedItem?
    private let requiresOwnerCheck: () -> Bool
    private let checkOwner: (String, @escaping (Bool) -> Void) -> Void
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private var transcriber: Transcriber?
    /// The app to type into: whichever was in front when the shortcut went down.
    private var target: NSRunningApplication?
    private var releasedEarly = false
    /// Bumped on every start so callbacks from an abandoned session are dropped.
    private var session = 0
    private var pressedAt: Date?
    private let now: () -> Date
    /// Ends a forgotten hands-free session, so the mic is never left on for long.
    private var handsFreeLimit: DispatchWorkItem?

    /// A press shorter than this is a tap, which keeps listening hands-free.
    static let tapLength: TimeInterval = 0.35
    /// Hands-free sessions finish and type on their own after this long.
    static let handsFreeMaximum: TimeInterval = 10 * 60
    /// How long "Pasting …" shows before it's pasted, to catch the wrong item with Esc.
    static let confirmDelay: TimeInterval = 0.5

    init(makeTranscriber: @escaping () -> Transcriber = Dictation.systemTranscriber, inserter: TextInserting = Paster(),
         polisher: TextPolishing = Dictation.systemPolisher(), cleanup: @escaping () -> Cleanup = { .current },
         saved: @escaping (String) -> SavedItem? = { SavedText.shared.match($0) },
         requiresOwnerCheck: @escaping () -> Bool = { Settings.shared.requireTouchIDForSecrets },
         checkOwner: @escaping (String, @escaping (Bool) -> Void) -> Void = OwnerCheck.confirm,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1) },
         now: @escaping () -> Date = Date.init) {
        self.makeTranscriber = makeTranscriber
        self.inserter = inserter
        self.polisher = polisher
        self.cleanup = cleanup
        self.saved = saved
        self.requiresOwnerCheck = requiresOwnerCheck
        self.checkOwner = checkOwner
        self.schedule = schedule
        self.now = now
    }

    static func systemPolisher() -> TextPolishing {
        if #available(macOS 26, *) { return Polisher() }
        return NoPolisher()
    }

    static func systemTranscriber() -> Transcriber {
        // Dictation starts on the main thread.
        if Settings.shared.dictationEngine == .parakeet, MainActor.assumeIsolated({ ParakeetEngine.isReady }) {
            if let file = Demo.dictationAudio, let source = try? FileAudioSource(url: file) { return ParakeetTranscriber(source: source) }
            return ParakeetTranscriber()
        }
        if Settings.shared.dictationEngine == .parakeet {
            // Still downloading or loading: Apple's model this time.
            MainActor.assumeIsolated { ParakeetEngine.prepare() }
        }
        if #available(macOS 26, *), let file = Demo.dictationAudio, let source = try? FileAudioSource(url: file) {
            return AnalyzerTranscriber(source: source)
        }
        if #available(macOS 26, *) { return AnalyzerTranscriber() }
        return RecognizerTranscriber()
    }

    /// Shortcut pressed (or Start Dictation chosen, with `handsFree`).
    func begin(target: NSRunningApplication?, handsFree: Bool = false) {
        guard phase == .idle else { return }
        session += 1
        let id = session
        self.target = target
        releasedEarly = false
        pressedAt = now()
        if handsFree { startHandsFree() }
        text = ""
        level = 0
        let transcriber = makeTranscriber()
        self.transcriber = transcriber
        lastEngine = transcriber is ParakeetTranscriber ? "parakeet" : "apple"
        transcriber.onText = { [weak self] text in
            guard let self, self.session == id, self.text != text else { return }
            self.text = text
            self.onStateChange?()
        }
        transcriber.onLevel = { [weak self] level in
            guard let self, self.session == id, self.level != level else { return }
            self.level = level
            self.onStateChange?()
        }
        setPhase(.starting)
        let options = cleanup()
        if options.removeFillers && options.polish { polisher.prepare() }
        transcriber.start { [weak self] error in
            guard let self, self.session == id else { return }
            if let error {
                self.reset()
                let known = error as? DictationError
                self.onMessage?(known?.message ?? error.localizedDescription)
                if let pane = known?.settingsPane { DictationAccess.openPane(pane) }
                return
            }
            self.setPhase(.listening)
            if self.releasedEarly { self.end() }
        }
    }

    /// Shortcut released. After a hold, finish and type; after a quick tap, keep listening hands-free.
    func release() {
        guard !handsFree, phase == .starting || phase == .listening else { return }
        if let pressedAt, now().timeIntervalSince(pressedAt) < Self.tapLength {
            startHandsFree()
            onStateChange?()
            return
        }
        end()
    }

    private func startHandsFree() {
        handsFree = true
        let id = session
        let limit = DispatchWorkItem { [weak self] in
            guard let self, self.session == id else { return }
            self.end()
        }
        handsFreeLimit = limit
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.handsFreeMaximum, execute: limit)
    }

    /// Stop listening, then clean up and type what was said: shortcut released after a hold,
    /// or pressed again / Done in hands-free mode.
    func end() {
        if handsFree {
            handsFree = false
            handsFreeLimit?.cancel()
            lastWasHandsFree = true
        } else if phase == .starting || phase == .listening {
            lastWasHandsFree = false
        }
        switch phase {
        case .starting:
            releasedEarly = true
        case .listening:
            setPhase(.finishing)
            let id = session
            transcriber?.finish { [weak self] said in
                guard let self, self.session == id else { return }
                // Before any tidying, which could change the words of the request.
                if let item = self.saved(Fillers.strip(said)) { return self.confirm(item) }
                let options = self.cleanup()
                let filtered = options.removeFillers ? Fillers.strip(said) : said
                guard !filtered.isEmpty else { return self.reset() }
                guard options.removeFillers && options.polish else { return self.type(filtered) }
                self.text = filtered
                self.setPhase(.polishing)
                self.polisher.polish(filtered) { [weak self] polished in
                    guard let self, self.session == id else { return }
                    // Only if it's still what was said; otherwise the plain filtered text.
                    let faithful = polished.flatMap { Fillers.isFaithful($0, to: said) ? $0 : nil }
                    self.type(faithful ?? filtered)
                }
            }
        case .idle, .finishing, .polishing, .confirming:
            break
        }
    }

    /// Shows which item is about to be pasted, then pastes it unless Esc cancelled. Keys and
    /// passwords ask for Touch ID first when Settings says so.
    private func confirm(_ item: SavedItem) {
        let id = session
        text = "Pasting \(item.name)…"
        setPhase(.confirming)
        schedule(Self.confirmDelay) { [weak self] in
            guard let self, self.session == id else { return }
            guard item.secret, self.requiresOwnerCheck() else { return self.paste(item) }
            self.checkOwner("paste your \(item.name)") { [weak self] allowed in
                guard let self, self.session == id else { return }
                allowed ? self.paste(item) : self.reset()
            }
        }
    }

    private func paste(_ item: SavedItem) {
        let target = self.target
        reset()
        onSavedPasted?(item)
        let copied: () -> Void = { [weak self] in self?.onSavedNoTextBox?(item) }
        if !inserter.insert(item.value, into: target, secret: item.secret, noField: copied) {
            onMessage?("Copied \(item.name). Press ⌘V to paste, or allow YapYap in Accessibility to paste it for you.")
        }
    }

    private func type(_ text: String) {
        let target = self.target
        reset()
        onTyped?(text)
        let copied: () -> Void = { [weak self] in
            if let show = self?.onNoTextBox { show(text) }
            else { self?.onMessage?("No text box here, so it's copied. Press ⌘V to paste it where you want it.") }
        }
        if !inserter.insert(text, into: target, noField: copied) {
            onMessage?("Copied what you said. Press ⌘V to paste, or allow YapYap in Accessibility to type it for you.")
        }
    }

    /// Names and terms from the screen, to spell them right. Ignored once listening has ended.
    func setContext(_ terms: [String]) {
        guard phase == .starting || phase == .listening, !terms.isEmpty else { return }
        transcriber?.setContext(terms)
    }

    /// Stops without typing anything.
    func cancel() {
        guard phase != .idle else { return }
        transcriber?.cancel()
        reset()
    }

    private func reset() {
        session += 1
        // Pressed and let go without polishing (nothing said, cancelled, failed).
        polisher.discard()
        transcriber = nil
        target = nil
        level = 0
        handsFree = false
        handsFreeLimit?.cancel()
        handsFreeLimit = nil
        pressedAt = nil
        setPhase(.idle)
    }

    private func setPhase(_ p: Phase) {
        phase = p
        onStateChange?()
    }
}

enum DictationError: Error {
    case noMicrophone
    case microphoneDenied
    case speechDenied
    case unavailable

    var message: String {
        switch self {
        case .noMicrophone: return "No microphone found"
        case .microphoneDenied: return "Allow YapYap to use the microphone in Privacy & Security"
        case .speechDenied: return "Allow YapYap to use Speech Recognition in Privacy & Security"
        case .unavailable: return "Speech recognition isn't available for your language"
        }
    }

    var settingsPane: String? {
        switch self {
        case .microphoneDenied: return "Privacy_Microphone"
        case .speechDenied: return "Privacy_SpeechRecognition"
        default: return nil
        }
    }
}

// MARK: Speech to text

/// Listens to the microphone and turns it into text. Callbacks arrive on the main queue.
protocol Transcriber: AnyObject {
    /// Everything heard so far, as it changes.
    var onText: ((String) -> Void)? { get set }
    var onLevel: ((Float) -> Void)? { get set }
    /// Calls back with nil once listening, or with what went wrong.
    func start(_ done: @escaping (Error?) -> Void)
    /// Stops listening; calls back with the final text.
    func finish(_ done: @escaping (String) -> Void)
    func cancel()
    /// Words to favour, such as names on screen. May arrive after listening has started.
    func setContext(_ terms: [String])
}

extension Transcriber {
    func setContext(_ terms: [String]) {}

    /// Asks for the microphone the first time; nil when it's allowed.
    static func microphoneAccess() async -> DictationError? {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return nil
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio) ? nil : .microphoneDenied
        default: return .microphoneDenied
        }
    }
}

/// macOS 26+: SpeechAnalyzer with the dictation model (DictationTranscriber), which honours names
/// from the screen, or SpeechTranscriber for languages it doesn't cover. The model is a system
/// asset, downloaded once and shared with other apps.
@available(macOS 26, *)
/// State is only touched on the main queue; background tasks hop there before using it.
final class AnalyzerTranscriber: Transcriber, @unchecked Sendable {
    private static let log = Logger(subsystem: "cc.yapyap.app", category: "dictation")
    var onText: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?

    private let mic: AudioSource
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?
    private var transcript = Transcript()
    private var cancelled = false
    /// Names and terms to favour; applied as soon as the analyzer exists.
    private var contextTerms: [String] = []

    init(source: AudioSource = Microphone()) {
        mic = source
    }

    func start(_ done: @escaping (Error?) -> Void) {
        mic.onLevel = { [weak self] in self?.onLevel?($0) }
        Task {
            do {
                try await self.prepare()
                DispatchQueue.main.async {
                    // Released and cancelled while the model was loading.
                    if self.cancelled { return self.stopAudio() }
                    done(nil)
                }
            } catch {
                DispatchQueue.main.async {
                    self.stopAudio()
                    done(error)
                }
            }
        }
    }

    private func prepare() async throws {
        if mic is Microphone, let error = await Self.microphoneAccess() { throw error }

        // The dictation model first: it's the one that uses the names from the screen (the general
        // SpeechTranscriber ignores AnalysisContext). The general model covers other languages.
        let module: any SpeechModule
        if let locale = await DictationTranscriber.supportedLocale(equivalentTo: .current) {
            var preset = DictationTranscriber.Preset.progressiveLongDictation
            preset.transcriptionOptions.insert(.punctuation)
            let transcriber = DictationTranscriber(locale: locale, preset: preset)
            results = consume(transcriber.results) { ($0.text, $0.isFinal) }
            module = transcriber
        } else if SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) {
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            results = consume(transcriber.results) { ($0.text, $0.isFinal) }
            module = transcriber
        } else {
            throw DictationError.unavailable
        }

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            DispatchQueue.main.async { Toast.show("Downloading the speech model (once)…", for: 3) }
            try await request.downloadAndInstall()
        }

        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        let analyzer = SpeechAnalyzer(modules: [module])
        try await analyzer.prepareToAnalyze(in: format)
        let terms = await MainActor.run {
            self.analyzer = analyzer
            return self.contextTerms
        }
        if !terms.isEmpty { await Self.apply(terms, to: analyzer) }

        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.input = input
        try mic.start(format: format) { input.yield(AnalyzerInput(buffer: $0)) }
        try await analyzer.start(inputSequence: stream)
    }

    private func consume<S: AsyncSequence>(_ sequence: S, _ read: @escaping (S.Element) -> (AttributedString, Bool)) -> Task<Void, Never> {
        Task {
            do {
                for try await result in sequence {
                    let (text, isFinal) = read(result)
                    let string = String(text.characters)
                    DispatchQueue.main.async {
                        self.transcript.receive(string, isFinal: isFinal)
                        self.onText?(self.transcript.text)
                    }
                }
            } catch {}
        }
    }

    func setContext(_ terms: [String]) {
        contextTerms = terms
        guard let analyzer else { return } // still loading: prepare() applies them
        Task { await Self.apply(terms, to: analyzer) }
    }

    private static func apply(_ terms: [String], to analyzer: SpeechAnalyzer) async {
        let context = AnalysisContext()
        context.contextualStrings[.general] = terms
        do {
            try await analyzer.setContext(context)
            log.debug("Context set: \(terms.count) terms")
        } catch {
            log.error("Context not set: \(error, privacy: .public)")
        }
    }

    func finish(_ done: @escaping (String) -> Void) {
        stopAudio()
        Task {
            try? await analyzer?.finalizeAndFinishThroughEndOfInput()
            await results?.value
            // After every result already queued on main.
            DispatchQueue.main.async { done(self.transcript.text) }
        }
    }

    func cancel() {
        cancelled = true
        stopAudio()
        results?.cancel()
        Task { await analyzer?.cancelAndFinishNow() }
    }

    private func stopAudio() {
        mic.stop()
        input?.finish()
    }
}

/// macOS 15: SFSpeechRecognizer, strictly on device. Languages it can only do on Apple's
/// servers are refused rather than sending audio off the Mac.
/// State is only touched on the main queue, like AnalyzerTranscriber.
final class RecognizerTranscriber: Transcriber, @unchecked Sendable {
    var onText: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?

    private let mic = Microphone()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var transcript = Transcript()
    private var finished: ((String) -> Void)?
    private var isDone = false
    private var contextTerms: [String] = []

    /// Recognition may have begun; the request still takes new strings for the audio to come.
    func setContext(_ terms: [String]) {
        contextTerms = terms
        request?.contextualStrings = terms
    }

    func start(_ done: @escaping (Error?) -> Void) {
        mic.onLevel = { [weak self] in self?.onLevel?($0) }
        Task {
            let error = await Self.prepareAccess()
            DispatchQueue.main.async {
                if let error { return done(error) }
                do {
                    try self.listen()
                    done(nil)
                } catch {
                    self.cancel()
                    done(error)
                }
            }
        }
    }

    private static func prepareAccess() async -> DictationError? {
        if let error = await microphoneAccess() { return error }
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            status = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        }
        return status == .authorized ? nil : .speechDenied
    }

    private func listen() throws {
        guard let recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { throw DictationError.unavailable }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = true
        request.contextualStrings = contextTerms
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            DispatchQueue.main.async {
                guard let self, !self.isDone else { return }
                if let text {
                    // Each result is the whole utterance so far.
                    self.transcript.receive(text, isFinal: false)
                    self.onText?(self.transcript.text)
                }
                if isFinal || error != nil { self.complete() }
            }
        }
        try mic.start(format: nil) { request.append($0) }
    }

    func finish(_ done: @escaping (String) -> Void) {
        mic.stop()
        guard task != nil, !isDone else { return done(transcript.text) }
        finished = done
        request?.endAudio()
        // Don't wait forever if the recognizer never sends a final result.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.complete() }
    }

    private func complete() {
        guard !isDone else { return }
        isDone = true
        mic.stop()
        finished?(transcript.text)
        finished = nil
    }

    func cancel() {
        isDone = true
        mic.stop()
        task?.cancel()
    }
}

/// Where dictation audio comes from: the microphone, or a file for testing.
protocol AudioSource: AnyObject {
    /// Called on the main queue.
    var onLevel: ((Float) -> Void)? { get set }
    /// Delivers buffers in `format` (or the source's own when nil) to `handle`, on another thread.
    func start(format: AVAudioFormat?, _ handle: @escaping (AVAudioPCMBuffer) -> Void) throws
    func stop()
}

/// The default input device, converted to the format a recognizer wants, with a level meter.
final class Microphone: AudioSource {
    /// Called on the main queue.
    var onLevel: ((Float) -> Void)?
    private let engine = AVAudioEngine()
    private var running = false
    /// Audio thread only. The meter needs ~15 updates a second, not one per buffer.
    private var lastMeter = 0.0

    /// `handle` is called on an audio thread.
    func start(format: AVAudioFormat?, _ handle: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw DictationError.noMicrophone }
        let outFormat = format ?? inFormat
        let converter = outFormat == inFormat ? nil : AVAudioConverter(from: inFormat, to: outFormat)
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            self?.meter(buffer)
            if let converter {
                if let converted = Self.convert(buffer, with: converter) { handle(converted) }
            } else {
                handle(buffer)
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        running = true
    }

    func stop() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let ratio = converter.outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }

    private func meter(_ buffer: AVAudioPCMBuffer) {
        let now = CACurrentMediaTime()
        guard now - lastMeter >= 1.0 / 15 else { return }
        lastMeter = now
        guard let level = Self.level(of: buffer) else { return }
        DispatchQueue.main.async { self.onLevel?(level) }
    }

    /// Loudness of a buffer, 0…1: −50 dB (quiet room) … 0 dB, quantized so tiny changes don't
    /// redraw anything.
    static func level(of buffer: AVAudioPCMBuffer) -> Float? {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return nil }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        return (max(0, min(1, (20 * log10(max(rms, 1e-6)) + 50) / 50)) * 20).rounded() / 20
    }
}

/// Plays an audio file into dictation at real-time speed, like someone talking. For `--transcribe`
/// and `--demo`.
final class FileAudioSource: AudioSource {
    /// Called on the main queue.
    var onLevel: ((Float) -> Void)?
    /// Called on the main queue when the first buffer is delivered.
    var onPlay: (() -> Void)?
    private let file: AVAudioFile
    private var stopped = false

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
    }

    func start(format: AVAudioFormat?, _ handle: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let inFormat = file.processingFormat
        let converter = format.flatMap { $0 == inFormat ? nil : AVAudioConverter(from: inFormat, to: $0) }
        let chunk: AVAudioFrameCount = 2048
        let onPlay = self.onPlay ?? Demo.onDictationAudio
        DispatchQueue.main.async { onPlay?() }
        Thread.detachNewThread { [self] in
            while !stopped, let buffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk),
                  (try? file.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0 {
                if let level = Microphone.level(of: buffer) { DispatchQueue.main.async { self.onLevel?(level) } }
                if let converter {
                    if let converted = Microphone.convert(buffer, with: converter) { handle(converted) }
                } else {
                    handle(buffer)
                }
                Thread.sleep(forTimeInterval: Double(buffer.frameLength) / inFormat.sampleRate)
            }
        }
    }

    func stop() { stopped = true }
}

// MARK: Typing it out

protocol TextInserting {
    /// False when the text was only left on the clipboard (no permission to type).
    /// `noField` is called instead of typing when nothing that takes text has focus; the text
    /// is then left on the clipboard to paste wherever the user wants.
    /// `secret`: a key or password, marked so clipboard managers skip it.
    func insert(_ text: String, into app: NSRunningApplication?, secret: Bool, noField: @escaping () -> Void) -> Bool
}

extension TextInserting {
    func insert(_ text: String, into app: NSRunningApplication?, noField: @escaping () -> Void) -> Bool {
        insert(text, into: app, secret: false, noField: noField)
    }
}

/// Types text into another app by pasting: clipboard, ⌘V, then the old clipboard back.
/// Pasting works in every kind of text field, unlike setting text through Accessibility.
/// Sending ⌘V needs the Accessibility permission; without it the text stays on the clipboard.
struct Paster: TextInserting {
    func insert(_ text: String, into app: NSRunningApplication?, secret: Bool, noField: @escaping () -> Void) -> Bool {
        let board = NSPasteboard.general
        let saved = Self.copyItems(of: board)
        // This Mac only: not to other devices over Universal Clipboard, and marked so
        // clipboard managers don't keep it (nspasteboard.org conventions).
        board.prepareForNewContents(with: .currentHostOnly)
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        if secret { item.setData(Data(), forType: Self.concealed) }
        board.writeObjects([item])
        let ours = board.changeCount

        guard CGPreflightPostEventAccess() else {
            CGRequestPostEventAccess()
            return false
        }

        var delay = 0.0
        if let app, app != NSWorkspace.shared.frontmostApplication {
            app.activate()
            delay = 0.15
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if Self.focusIsClearlyNotText() {
                // Nowhere to type: keep the words on the clipboard, as an ordinary copy.
                Self.copy(text, secret: secret)
                return noField()
            }
            Self.pressCommandV()
            // Give the app time to read the clipboard before putting the old contents back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard board.changeCount == ours, !saved.isEmpty else { return }
                board.prepareForNewContents(with: .currentHostOnly)
                board.writeObjects(saved)
            }
        }
        return true
    }

    /// True when the focused thing isn't somewhere text can be typed, so the words go to the
    /// Copy card instead of a ⌘V that would land nowhere (or, on the desktop, make Finder save a
    /// text clipping file). Finder (windows and the desktop) always gets the card: it reports a
    /// selected file's name as an editable text field, so a paste there renamed the file.
    /// Elsewhere, text boxes are recognised by what they do: an editable value, a text cursor or
    /// selection, or a text role. Anything else focused gets the card. When an app won't say
    /// what's focused, it gets the paste, as many don't describe their text boxes.
    static func focusIsClearlyNotText() -> Bool {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" { return true }
        let (result, focused) = focusedElement()
        guard result == .success, let element = focused else { return result == .noValue }
        return !looksLikeText(element)
    }

    private static func looksLikeText(_ element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue {
            return true
        }
        var range: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success, range != nil {
            return true
        }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        return (role as? String).map(textRoles.contains) ?? false
    }

    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// Marks a password: clipboard managers don't keep or show it (nspasteboard.org).
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Puts text on the clipboard to paste yourself; a secret stays on this Mac and out of clipboard managers.
    static func copy(_ text: String, secret: Bool = false) {
        let board = NSPasteboard.general
        if secret {
            board.prepareForNewContents(with: .currentHostOnly)
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            item.setData(Data(), forType: concealed)
            board.writeObjects([item])
        } else {
            board.clearContents()
            board.setString(text, forType: .string)
        }
    }

    /// The front app's focused element. Asked of the app itself: the system-wide element often
    /// answers "cannot complete" (-25204) on current macOS.
    private static func focusedElement() -> (AXError, AXUIElement?) {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return (.noValue, nil) }
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &focused)
        guard result == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return (result, nil) }
        return (result, (focused as! AXUIElement))
    }

    /// "AXTextArea (value settable)", or what went wrong, for `--focus`.
    static func describeFocus() -> String {
        let (result, focused) = focusedElement()
        guard let element = focused else { return "no focused element (AXError \(result.rawValue))" }
        var role: CFTypeRef?, subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return "\(role as? String ?? "?")/\(subrole as? String ?? "-")\(settable.boolValue ? " (value settable)" : "")"
    }


    private static func pressCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
            // Exactly ⌘, even if the user is still holding ⌥ from the shortcut.
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }

    private static func copyItems(of board: NSPasteboard) -> [NSPasteboardItem] {
        (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }
}

// MARK: Permissions

/// What dictation needs before it can run: the microphone, Accessibility to press ⌘V,
/// and on macOS 15 Speech Recognition. The Welcome guide won't move on until all are allowed.
enum DictationAccess {
    static var microphone: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    static var accessibility: Bool { AXIsProcessTrusted() }
    /// SpeechAnalyzer (macOS 26+) doesn't ask; SFSpeechRecognizer does.
    static var needsSpeech: Bool {
        if #available(macOS 26, *) { return false }
        return true
    }
    static var speech: Bool { !needsSpeech || SFSpeechRecognizer.authorizationStatus() == .authorized }
    static var allGranted: Bool { microphone && accessibility && speech }

    /// Asks the first time; after a "Don't Allow", only System Settings can change it.
    static func requestMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        } else {
            openPane("Privacy_Microphone")
        }
    }

    static func requestSpeech() {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { _ in }
        } else {
            openPane("Privacy_SpeechRecognition")
        }
    }

    /// Adds YapYap to the Accessibility list (switched off) and opens it.
    static func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary)
        openPane("Privacy_Accessibility")
    }

    static func openPane(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}
