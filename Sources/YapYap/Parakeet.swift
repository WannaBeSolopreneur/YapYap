import AVFoundation
import FluidAudio
import os

/// NVIDIA Parakeet speech to text (through FluidAudio), on the Neural Engine. Chosen in
/// Settings → Dictation → Engine. The model downloads once and stays loaded while YapYap runs.
actor ParakeetEngine {
    static let shared = ParakeetEngine()
    private static let log = Logger(subsystem: "cc.yapyap.app", category: "parakeet")

    /// Ultra: v3 retrained, 25 languages, and the most accurate in our tests (2026-10-20: 9% word
    /// errors on four test clips, v2 and v3 10%, Apple 16%; phonon2 spells numbers as words).
    /// `YAPYAP_PARAKEET_MODEL` or the `parakeetModel` default picks v2, v3 or phonon2 to compare.
    static let version: AsrModelVersion = {
        let name = ProcessInfo.processInfo.environment["YAPYAP_PARAKEET_MODEL"]
            ?? UserDefaults.standard.string(forKey: "parakeetModel") ?? "ultra"
        switch name {
        case "v2": return .v2
        case "v3": return .v3
        case "phonon2": return .phonon2
        default: return .ultra
        }
    }()

    private var manager: AsrManager?
    private var loading: Task<AsrManager, Error>?
    private var ctc: Task<CtcModels, Error>?

    nonisolated static var isDownloaded: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
    }

    var isLoaded: Bool { manager != nil }

    /// The 25 European languages Parakeet v3 (and Ultra) understands. Macs set to another language
    /// keep Apple's model, which covers more, and never download Parakeet.
    static let languages: Set<String> = ["bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "hr", "hu", "it",
                                         "lt", "lv", "mt", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "uk"]
    static var speaksMacLanguage: Bool { languages.contains(Locale.current.language.languageCode?.identifier ?? "en") }

    /// Loaded and ready to dictate. Until then dictation uses Apple's model. Main thread.
    @MainActor static var isReady = false
    @MainActor private static var preparing = false

    /// Downloads (the first time, ~700 MB in the background) and loads Parakeet, and the names model
    /// when names from the screen are on. Call on the main thread; does nothing if already under way.
    @MainActor static func prepare() {
        guard !isReady, !preparing, speaksMacLanguage else { return }
        preparing = true
        let names = Settings.shared.useScreenContext
        Task {
            do {
                try await shared.load()
                if names { try? await shared.loadNames() }
                await MainActor.run { isReady = true }
            } catch {
                log.error("Parakeet not ready: \(error, privacy: .public)")
            }
            await MainActor.run { preparing = false }
        }
    }

    /// Frees the memory and deletes the downloaded models. Picking Parakeet again fetches them again.
    @MainActor static func remove() {
        isReady = false
        Task {
            await shared.unload()
            for folder in [AsrModels.defaultCacheDirectory(for: version), CtcModels.defaultCacheDirectory(for: .ctc110m)] {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

    private func unload() async {
        await manager?.cleanup()
        manager = nil
        ctc = nil
        spotters = nil
    }

    private func loadNames() async throws { _ = try await ctcModels() }

    /// Downloads (the first time) and loads the model. Safe to call again while it's loading.
    @discardableResult
    func load() async throws -> AsrManager {
        if let manager { return manager }
        if let loading { return try await loading.value }
        let task = Task { () -> AsrManager in
            let started = Date()
            let models = try await AsrModels.downloadAndLoad(version: Self.version)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            Self.log.info("Parakeet loaded in \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) s")
            return manager
        }
        loading = task
        defer { loading = nil }
        let loaded = try await task.value
        manager = loaded
        return loaded
    }

    /// 16 kHz mono samples to text.
    func transcribe(_ samples: [Float]) async throws -> ASRResult {
        let manager = try await load()
        // Under a second can come back empty; pad with silence.
        let padded = samples.count < 16_000 ? samples + [Float](repeating: 0, count: 16_000 - samples.count) : samples
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(padded, decoderState: &state)
    }

    /// Respells words the model misheard as names from the screen, where the audio supports it.
    /// FluidAudio's own rescoring also swaps in names that look nothing like what was heard ("Hey Tig"
    /// became "Priya Shah"), so this takes its evidence and makes a stricter choice: see `pick`.
    func respell(_ result: ASRResult, samples: [Float], names: [String]) async -> String {
        guard !names.isEmpty, let timings = result.tokenTimings, !timings.isEmpty else { return result.text }
        do {
            let (spotter, rescorer, vocabulary) = try await spotting(names)
            let spot = try await spotter.spotKeywordsWithLogProbs(audioSamples: samples, customVocabulary: vocabulary, minScore: nil)
            guard !spot.logProbs.isEmpty else { return result.text }
            let config = ContextBiasingConstants.rescorerConfig(forVocabSize: vocabulary.terms.count)
            let evidence = rescorer.ctcTokenEvaluateCandidates(
                transcript: result.text, tokenTimings: timings, logProbs: spot.logProbs,
                frameDuration: spot.frameDuration, cbw: config.cbw, marginSeconds: 0.5, minSimilarity: config.minSimilarity)
            let candidates = evidence.candidates.compactMap { c -> NameCandidate? in
                guard let range = c.baseTextUTF8Range else { return nil }
                return NameCandidate(heard: c.basePhrase, name: c.canonicalTerm, range: range, similarity: c.similarity,
                                     passed: c.comparisonPassed,
                                     margin: (c.rawVocabularyCTCScore ?? 0) + (c.effectiveBoost ?? 0) - (c.rawOriginalCTCScore ?? 0))
            }
            if ProcessInfo.processInfo.environment["YAPYAP_DEBUG"] != nil {
                for c in candidates {
                    FileHandle.standardError.write("[candidate '\(c.heard)' → '\(c.name)' similarity \(String(format: "%.2f", c.similarity)) passed=\(c.passed)]\n".data(using: .utf8)!)
                }
            }
            return NameCandidate.apply(NameCandidate.pick(candidates), to: evidence.baseText)
        } catch {
            Self.log.error("Names not applied: \(error, privacy: .public)")
            return result.text
        }
    }

    /// Spotter and rescorer for a list of names, kept while the list doesn't change.
    private var spotters: (names: [String], spotter: CtcKeywordSpotter, rescorer: VocabularyRescorer, vocabulary: CustomVocabularyContext)?

    private func spotting(_ names: [String]) async throws -> (CtcKeywordSpotter, VocabularyRescorer, CustomVocabularyContext) {
        if let spotters, spotters.names == names { return (spotters.spotter, spotters.rescorer, spotters.vocabulary) }
        let models = try await ctcModels()
        let directory = CtcModels.defaultCacheDirectory(for: models.variant)
        let tokenizer = try await CtcTokenizer.load(from: directory)
        let terms = names.compactMap { name -> CustomVocabularyTerm? in
            let tokens = tokenizer.encode(name)
            return tokens.isEmpty ? nil : CustomVocabularyTerm(text: name, ctcTokenIds: tokens)
        }
        let vocabulary = CustomVocabularyContext(terms: terms)
        let spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
        let rescorer = try await VocabularyRescorer.create(spotter: spotter, vocabulary: vocabulary, ctcModelDirectory: directory)
        spotters = (names, spotter, rescorer, vocabulary)
        return (spotter, rescorer, vocabulary)
    }

    /// The small CTC model that spots the names (~100 MB), fetched the first time names are used.
    private func ctcModels() async throws -> CtcModels {
        if let ctc { return try await ctc.value }
        let task = Task { try await CtcModels.downloadAndLoad() }
        ctc = task
        do {
            return try await task.value
        } catch {
            ctc = nil
            throw error
        }
    }
}

/// Dictation through Parakeet. It has no streaming results like Apple's analyzer, so while you talk
/// it re-reads the recent audio about every 0.7 s for the bar, and reads all of it once you finish.
/// State is only touched on the main queue, like AnalyzerTranscriber.
final class ParakeetTranscriber: Transcriber, @unchecked Sendable {
    var onText: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?

    private static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    /// The bar shows one line, so the preview only needs the last few seconds.
    private static let previewSamples = 12 * 16_000

    private let mic: AudioSource
    private let audio = SampleBuffer()
    private var names: [String] = []
    private var timer: Timer?
    private var previewing = false
    private var previewedCount = 0
    private var stopped = false

    init(source: AudioSource = Microphone()) {
        mic = source
    }

    func setContext(_ terms: [String]) { names = terms }

    func start(_ done: @escaping (Error?) -> Void) {
        mic.onLevel = { [weak self] in self?.onLevel?($0) }
        Task {
            do {
                if mic is Microphone, let error = await Self.microphoneAccess() { throw error }
                // Already on disk: listen straight away while it loads. Otherwise download first.
                if !ParakeetEngine.isDownloaded {
                    DispatchQueue.main.async { Toast.show("Downloading the Parakeet speech model (once)…", for: 4) }
                    try await ParakeetEngine.shared.load()
                }
                try mic.start(format: Self.format) { [audio] in audio.append($0) }
                DispatchQueue.main.async {
                    if self.stopped { return self.mic.stop() }
                    self.timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in self?.preview() }
                    done(nil)
                }
                try await ParakeetEngine.shared.load()
            } catch {
                DispatchQueue.main.async {
                    self.stop()
                    done(error)
                }
            }
        }
    }

    private func preview() {
        let count = audio.count
        guard !previewing, !stopped, count - previewedCount >= 8_000 else { return }
        previewing = true
        previewedCount = count
        let recent = audio.suffix(Self.previewSamples)
        Task {
            let text = try? await ParakeetEngine.shared.transcribe(recent).text
            DispatchQueue.main.async {
                self.previewing = false
                if !self.stopped, let text, !text.isEmpty { self.onText?(text) }
            }
        }
    }

    func finish(_ done: @escaping (String) -> Void) {
        stop()
        let samples = audio.all
        let names = self.names
        Task {
            var text = ""
            if samples.count >= 4_000, let result = try? await ParakeetEngine.shared.transcribe(samples) {
                text = await ParakeetEngine.shared.respell(result, samples: samples, names: names)
            }
            let final = text.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { done(final) }
        }
    }

    func cancel() { stop() }

    private func stop() {
        stopped = true
        timer?.invalidate()
        timer = nil
        mic.stop()
    }
}

/// Microphone samples, appended on the audio thread and read on others.
private final class SampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let new = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        lock.withLock { samples.append(contentsOf: new) }
    }

    var count: Int { lock.withLock { samples.count } }
    var all: [Float] { lock.withLock { samples } }
    func suffix(_ n: Int) -> [Float] { lock.withLock { Array(samples.suffix(n)) } }
}

/// A name from the screen that might be what was said in place of some words of the transcript.
struct NameCandidate: Equatable {
    var heard: String
    var name: String
    /// UTF-8 byte range of `heard` in the transcript.
    var range: Range<Int>
    /// How alike the spellings are, 0...1.
    var similarity: Float
    /// The audio matches the name better than what was transcribed.
    var passed: Bool
    /// By how much (log probability).
    var margin: Float

    /// Swaps a name in only when the audio favours it, it's spelled much like what was heard and has
    /// as many words, so a sound-alike is fixed ("Sioban" to "Siobhan") but other words are left alone.
    static func pick(_ candidates: [NameCandidate]) -> [NameCandidate] {
        let likely = candidates.filter { c in
            c.passed && c.similarity >= 0.6
                && c.heard.split(separator: " ").count == c.name.split(separator: " ").count
                && c.heard.caseInsensitiveCompare(c.name) != .orderedSame
        }
        var chosen: [NameCandidate] = []
        for c in likely.sorted(by: { $0.margin > $1.margin }) where !chosen.contains(where: { $0.range.overlaps(c.range) }) {
            chosen.append(c)
        }
        return chosen
    }

    static func apply(_ chosen: [NameCandidate], to text: String) -> String {
        var bytes = Array(text.utf8)
        for c in chosen.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) where c.range.upperBound <= bytes.count {
            bytes.replaceSubrange(c.range, with: Array(c.name.utf8))
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// YapYap's memory as Activity Monitor counts it, for the test tools.
enum Diagnostics {
    static func memoryMB() -> Double { vmInfo().map { Double($0.phys_footprint) / 1_048_576 } ?? 0 }
    static func peakMemoryMB() -> Double { vmInfo().map { Double($0.ledger_phys_footprint_peak) / 1_048_576 } ?? 0 }

    private static func vmInfo() -> task_vm_info_data_t? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info : nil
    }
}
