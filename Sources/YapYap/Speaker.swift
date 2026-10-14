import AVFoundation
import YapYapCore

/// Apple's synthesizer or Kokoro: anything that can speak a Doc from a word
/// and report which word is being spoken.
protocol SpeechEngine: AnyObject {
    var onWord: ((Int) -> Void)? { get set }
    var onFinish: (() -> Void)? { get set }
    var isPaused: Bool { get }
    func speak(_ doc: Doc, from wordIndex: Int)
    func togglePause()
    func stop()
    /// A read is about to start; load anything slow now.
    func prepare()
}

extension SpeechEngine {
    func prepare() {}
}

final class Speaker: NSObject, SpeechEngine, AVSpeechSynthesizerDelegate {
    var onWord: ((Int) -> Void)?
    var onFinish: (() -> Void)?
    var isPaused: Bool { synth.isPaused }

    private let synth = AVSpeechSynthesizer()
    private var utterance: AVSpeechUtterance?
    private var doc: Doc?
    private var offset = 0

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ doc: Doc, from wordIndex: Int) {
        guard doc.words.indices.contains(wordIndex) else { return }
        stop()
        self.doc = doc
        offset = doc.words[wordIndex].range.location
        let spoken = doc.speechText(skippingLinks: Settings.shared.skipLinks)
        let u = AVSpeechUtterance(string: (spoken as NSString).substring(from: offset))
        u.voice = Speaker.voice()
        // AVSpeech rates aren't linear; this maps 0.5×…2.5× to roughly 0.35…0.7.
        u.rate = Float(min(max(0.5 + 0.15 * log2(Settings.shared.speed), 0.1), 0.85))
        u.prefersAssistiveTechnologySettings = false
        utterance = u
        // Speaking in the same run-loop turn as stopSpeaking is sometimes dropped.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.utterance === u else { return }
            self.synth.speak(u)
        }
    }

    func togglePause() {
        if synth.isPaused { synth.continueSpeaking() } else { synth.pauseSpeaking(at: .word) }
    }

    func stop() {
        utterance = nil
        if synth.isSpeaking || synth.isPaused { synth.stopSpeaking(at: .immediate) }
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange, utterance u: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self, u === self.utterance, let i = self.doc?.wordIndex(atUTF16: range.location + self.offset) else { return }
            self.onWord?(i)
        }
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self, u === self.utterance else { return }
            self.utterance = nil
            self.onFinish?()
        }
    }

    // MARK: Voices

    /// Voices for the user's language, best quality first, without novelty voices.
    static func voices() -> [AVSpeechSynthesisVoice] {
        let lang = String(AVSpeechSynthesisVoice.currentLanguageCode().prefix(2))
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(lang) }
            .filter { !$0.identifier.hasPrefix("com.apple.speech.synthesis.voice") && !$0.identifier.hasPrefix("com.apple.eloquence") }
            .sorted { ($0.quality.rawValue, $1.name) > ($1.quality.rawValue, $0.name) }
    }

    static func voice() -> AVSpeechSynthesisVoice? {
        if let id = Settings.shared.voiceID, let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        let code = AVSpeechSynthesisVoice.currentLanguageCode()
        let all = voices()
        return all.first { $0.language == code } ?? all.first
    }

    static func qualityName(for v: AVSpeechSynthesisVoice) -> String {
        switch v.quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return ""
        }
    }
}
