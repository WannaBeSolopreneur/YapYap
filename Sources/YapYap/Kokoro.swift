import AVFoundation
import KokoroSwift
import MLX
import MLXUtilsLibrary
import YapYapCore
import ZIPFoundation

/// Kokoro-82M neural voice, on-device via MLX. Text is spoken in sentence-sized chunks:
/// each is synthesized on a background queue while the previous one plays, and the
/// model's per-token timestamps drive the word highlight.
///
/// The model is ~330 MB of GPU memory, so it's only loaded when a read is about to start
/// (`prepare()`, on the read shortcut) and released after `idleUnload` seconds without reading.
final class KokoroSpeaker: SpeechEngine {
    var onWord: ((Int) -> Void)?
    var onFinish: (() -> Void)?
    private(set) var isPaused = false

    /// How long the model stays loaded after the last read. Reloading costs ~0.3 s (more if
    /// macOS has evicted the file), so back-to-back reads stay instant.
    static var idleUnload: TimeInterval = 10 * 60

    private let queue = DispatchQueue(label: "YapYap.Kokoro", qos: .userInitiated)
    /// Queue only.
    private var tts: KokoroTTS?
    /// The selected voice's style vectors (~0.5 MB). Queue only.
    private var voice: (name: String, array: MLXArray)?
    /// Main thread's view of whether the model is loaded, for the "Loading…" toast.
    private var isLoaded = false
    /// Between speak() and stop(). Main thread.
    private var isSpeaking = false
    private var unloadWork: DispatchWorkItem?
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: Double(KokoroTTS.Constants.samplingRate), channels: 1)!

    /// Bumped on every speak/stop so audio from an old request is dropped.
    private var generation = 0
    /// (seconds into playback, word index), in order.
    private var timeline: [(time: Double, word: Int)] = []
    private var scheduledEnd = 0.0
    private var lastWord = -1
    private var timer: Timer?

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func speak(_ doc: Doc, from wordIndex: Int) {
        stop()
        guard let voiceID = Settings.shared.voiceID, let name = Self.voiceName(from: voiceID) else { return }
        let gen = generation
        let chunks = doc.chunks(from: wordIndex)
        let spoken = doc.speechText(skippingLinks: Settings.shared.skipLinks) as NSString
        let speed = Float(Settings.shared.speed)
        // At most two chunks waiting to play, so a speed change or stop wastes little work.
        let slots = DispatchSemaphore(value: 2)
        unloadWork?.cancel()
        isSpeaking = true
        if !isLoaded { Toast.show("Loading Kokoro voice…") }

        queue.async { [weak self] in
            guard let self else { return }
            guard let tts = self.loadModel(), let voice = self.loadVoice(name) else {
                return DispatchQueue.main.async { Toast.show("Kokoro voice files are missing") }
            }
            let language: Language = name.hasPrefix("b") ? .enGB : .enUS
            for (n, range) in chunks.enumerated() {
                slots.wait()
                guard self.isCurrent(gen) else { slots.signal(); return }
                let text = spoken.substring(with: range)
                // A chunk that was only a link has nothing to say.
                guard !text.allSatisfy(\.isWhitespace) else { slots.signal(); continue }
                let speech = SpeechText.collapsingSpaces(text)
                guard let (samples, tokens) = try? tts.generateAudio(voice: voice, language: language, text: speech.text, speed: speed),
                      !samples.isEmpty
                else { slots.signal(); continue }
                // Token ranges are in `text`; map them to words of the whole doc.
                let marks: [(Double, Int)] = (tokens ?? []).compactMap { t in
                    guard let start = t.start_ts, t.phonemes != nil,
                          let word = doc.wordIndex(atUTF16: range.location + min(speech.original(t.tokenRange.lowerBound.utf16Offset(in: speech.text)), range.length))
                    else { return nil }
                    return (start, word)
                }
                Memory.clearCache()
                DispatchQueue.main.async {
                    guard self.generation == gen else { slots.signal(); return }
                    self.play(samples, marks: marks, isLast: n == chunks.count - 1, gen: gen, slots: slots)
                }
            }
        }
    }

    /// A read is about to start (shortcut pressed): load the model and voice now, while the
    /// region is being chosen and the text recognized, and run it once to warm up its kernels.
    func prepare() {
        guard Self.isInstalled, let name = Settings.shared.voiceID.flatMap(Self.voiceName) else { return }
        unloadWork?.cancel()
        queue.async { [weak self] in
            guard let self else { return }
            let wasLoaded = self.tts != nil
            guard let tts = self.loadModel(), let voice = self.loadVoice(name) else { return }
            if !wasLoaded {
                _ = try? tts.generateAudio(voice: voice, language: name.hasPrefix("b") ? .enGB : .enUS, text: "Ready.")
                Memory.clearCache()
            }
            // Pressed the shortcut but never read anything: still let go eventually. A read in
            // progress schedules its own unload when it stops.
            DispatchQueue.main.async { if !self.isSpeaking { self.scheduleUnload() } }
        }
    }

    /// Releases the model and voice after `idleUnload` seconds unless another read starts.
    private func scheduleUnload() {
        unloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isLoaded = false
            self.queue.async {
                self.tts = nil
                self.voice = nil
                // Freed arrays go to MLX's buffer cache; hand that memory back to the system.
                Memory.clearCache()
            }
        }
        unloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleUnload, execute: work)
    }

    func togglePause() {
        guard timer != nil else { return }
        isPaused.toggle()
        if isPaused { player.pause() } else { player.play() }
    }

    func stop() {
        generation += 1
        isSpeaking = false
        scheduleUnload()
        timer?.invalidate()
        timer = nil
        player.stop()
        engine.stop()
        timeline = []
        scheduledEnd = 0
        lastWord = -1
        isPaused = false
    }

    // MARK: Playback

    private func play(_ samples: [Float], marks: [(Double, Int)], isLast: Bool, gen: Int, slots: DispatchSemaphore) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { slots.signal(); return }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }

        if !engine.isRunning {
            do { try engine.start() } catch { return Toast.show("Couldn't start audio") }
        }
        // If synthesis fell behind, the player ran dry and this chunk starts now.
        let start = max(scheduledEnd, playbackTime)
        timeline += marks.map { (start + $0.0, $0.1) }
        scheduledEnd = start + Double(samples.count) / format.sampleRate

        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            slots.signal()
            guard isLast else { return }
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.stop()
                self.onFinish?()
            }
        }
        if timer == nil {
            if !isPaused { player.play() }
            timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in self?.tick() }
        }
    }

    private var playbackTime: Double {
        guard let node = player.lastRenderTime, let t = player.playerTime(forNodeTime: node) else { return 0 }
        return Double(t.sampleTime) / t.sampleRate
    }

    private func tick() {
        guard !isPaused else { return }
        let now = playbackTime
        guard let mark = timeline.last(where: { $0.time <= now }), mark.word != lastWord else { return }
        lastWord = mark.word
        onWord?(mark.word)
    }

    private func isCurrent(_ gen: Int) -> Bool {
        DispatchQueue.main.sync { generation == gen }
    }

    /// Called on `queue`; a load reads ~330 MB of weights.
    private func loadModel() -> KokoroTTS? {
        if let tts { return tts }
        guard Self.isInstalled else { return nil }
        Memory.cacheLimit = 64 * 1024 * 1024
        tts = KokoroTTS(modelPath: Self.folder.appendingPathComponent(Self.modelFile))
        DispatchQueue.main.async { self.isLoaded = true }
        return tts
    }

    /// Called on `queue`; keeps only the voice in use.
    private func loadVoice(_ name: String) -> MLXArray? {
        if let voice, voice.name == name { return voice.array }
        guard let array = Self.readVoice(name) else { return nil }
        voice = (name, array)
        return array
    }

    // MARK: Offline rendering

    /// Synthesizes `doc` in one go (for `--vo`): mono samples at 24 kHz, and when each word starts.
    /// Same chunking, link skipping and token-to-word mapping as live reading.
    static func render(_ doc: Doc, voiceName: String, speed: Float = 1) -> (samples: [Float], words: [(index: Int, start: Double)])? {
        guard isInstalled, let voice = readVoice(voiceName) else { return nil }
        let tts = KokoroTTS(modelPath: folder.appendingPathComponent(modelFile))
        let language: Language = voiceName.hasPrefix("b") ? .enGB : .enUS
        let spoken = doc.speechText(skippingLinks: Settings.shared.skipLinks) as NSString
        let rate = Double(KokoroTTS.Constants.samplingRate)
        var samples: [Float] = []
        var words: [(Int, Double)] = []
        for range in doc.chunks(from: 0) {
            let text = spoken.substring(with: range)
            let speech = SpeechText.collapsingSpaces(text)
            guard !text.allSatisfy(\.isWhitespace),
                  let (audio, tokens) = try? tts.generateAudio(voice: voice, language: language, text: speech.text, speed: speed) else { continue }
            let offset = Double(samples.count) / rate
            for t in tokens ?? [] {
                guard let start = t.start_ts, t.phonemes != nil,
                      let w = doc.wordIndex(atUTF16: range.location + min(speech.original(t.tokenRange.lowerBound.utf16Offset(in: speech.text)), range.length)),
                      words.last?.0 != w else { continue }
                words.append((w, offset + start))
            }
            samples += audio
        }
        return (samples, words)
    }

    // MARK: Voices and files

    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("YapYap/Kokoro")
    private static let modelFile = "kokoro-v1_0.safetensors"
    private static let voicesFile = "voices.npz"
    /// The weights and voice styles kokoro-ios is tested against.
    private static let downloads = [
        (modelFile, URL(string: "https://media.githubusercontent.com/media/mlalma/KokoroTestApp/main/Resources/kokoro-v1_0.safetensors")!),
        (voicesFile, URL(string: "https://raw.githubusercontent.com/mlalma/KokoroTestApp/main/Resources/voices.npz")!),
    ]

    static var isInstalled: Bool {
        downloads.allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.0).path) }
    }

    private static let idPrefix = "kokoro:"

    static func voiceName(from id: String) -> String? {
        id.hasPrefix(idPrefix) ? String(id.dropFirst(idPrefix.count)) : nil
    }

    static func id(for name: String) -> String { idPrefix + name }

    /// Main thread only.
    private static var cachedNames: [String]?

    /// English voices (a = American, b = British; then f/m), best-known first. Read from the
    /// archive's directory, so no voice data is loaded just to fill a menu.
    static func voiceNames() -> [String] {
        if cachedNames == nil, isInstalled, let archive = try? Archive(url: folder.appendingPathComponent(voicesFile), accessMode: .read, pathEncoding: nil) {
            let favourites = ["af_heart", "af_bella", "bf_emma", "am_michael", "bm_george"]
            cachedNames = archive.map { String($0.path.split(separator: ".")[0]) }
                .filter { $0.hasPrefix("a") || $0.hasPrefix("b") }
                .sorted { a, b in
                    let (ia, ib) = (favourites.firstIndex(of: a) ?? .max, favourites.firstIndex(of: b) ?? .max)
                    return ia != ib ? ia < ib : a < b
                }
        }
        return cachedNames ?? []
    }

    /// One voice's style vectors, decoded from just its entry in voices.npz.
    static func readVoice(_ name: String) -> MLXArray? {
        guard let archive = try? Archive(url: folder.appendingPathComponent(voicesFile), accessMode: .read, pathEncoding: nil),
              let entry = archive[name + ".npy"] else { return nil }
        var data = Data()
        data.reserveCapacity(Int(entry.uncompressedSize))
        guard (try? archive.extract(entry, skipCRC32: true) { data.append($0) }) != nil else { return nil }
        return NpyzReader.read(data: data, name: name)?[name]
    }

    /// The chosen voice is a Kokoro one and its files are present.
    static var isSelected: Bool {
        Settings.shared.voiceID.flatMap(voiceName) != nil && isInstalled
    }

    static var missingDownloads: [(file: String, url: URL)] {
        downloads.filter { !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.0).path) }.map { ($0.0, $0.1) }
    }

    /// Bytes of model + voices, for download progress.
    static let downloadSize: Int64 = 327_115_152 + 14_629_684

    /// "Heart" from "af_heart".
    static func shortName(for name: String) -> String {
        name.split(separator: "_", maxSplits: 1).last.map { $0.capitalized } ?? name
    }

    /// "US · Female" from "af_heart".
    static func detail(for name: String) -> String {
        guard let code = name.split(separator: "_").first, code.count == 2 else { return "" }
        return (code.first == "b" ? "UK" : "US") + " · " + (code.last == "m" ? "Male" : "Female")
    }

    /// Removes the downloaded model and voices.
    static func uninstall() {
        try? FileManager.default.removeItem(at: folder)
        cachedNames = nil
    }
}

/// Picks Apple's synthesizer or Kokoro from the chosen voice and makes sure only one talks.
final class VoiceRouter: SpeechEngine {
    var onWord: ((Int) -> Void)? {
        didSet { apple.onWord = onWord; kokoro.onWord = onWord }
    }
    var onFinish: (() -> Void)? {
        didSet { apple.onFinish = onFinish; kokoro.onFinish = onFinish }
    }
    var isPaused: Bool { active.isPaused }

    private let apple = Speaker()
    private let kokoro = KokoroSpeaker()
    private var active: SpeechEngine

    init() {
        active = apple
    }

    func prepare() {
        if KokoroSpeaker.isSelected { kokoro.prepare() }
    }

    func speak(_ doc: Doc, from wordIndex: Int) {
        let usesKokoro = KokoroSpeaker.isSelected
        let next: SpeechEngine = usesKokoro ? kokoro : apple
        if next !== active { active.stop() }
        active = next
        active.speak(doc, from: wordIndex)
    }

    func togglePause() { active.togglePause() }
    func stop() { active.stop() }
}
