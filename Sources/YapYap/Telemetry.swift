import Foundation
import TelemetryDeck

/// Anonymous usage stats, sent with TelemetryDeck while "Share anonymous usage stats" is on
/// (the default; it can be turned off in Settings). Counts, timings and setting names only: never what was read or said, and
/// never which app or window it came from. TelemetryDeck identifies an install by a random ID it
/// hashes before sending; there's no account and no hardware ID.
///
/// The App ID is set at build time (scripts/build-app.sh, overridable with `TELEMETRYDECK_APP_ID`).
/// A build without one never loads the SDK, sends nothing and hides the setting.
final class Telemetry {
    static let shared = Telemetry()

    typealias Send = (_ name: String, _ parameters: [String: String], _ value: Double?) -> Void

    private let appID: String?
    private let isOn: () -> Bool
    /// nil: the real SDK. Tests pass a recorder and the SDK is never started.
    private let sink: Send?
    private var started = false

    init(appID: String? = Bundle.main.object(forInfoDictionaryKey: "TelemetryDeckAppID") as? String,
         isOn: @escaping () -> Bool = { Settings.shared.shareUsageStats },
         sink: Send? = nil) {
        self.appID = appID.flatMap { $0.isEmpty ? nil : $0 }
        self.isOn = isOn
        self.sink = sink
    }

    /// Whether this build can send anything; the setting is hidden otherwise.
    var isAvailable: Bool { appID != nil }

    /// Starts or stops the SDK to match the setting. Called at launch and when it changes.
    func update() {
        let want = isAvailable && isOn()
        guard want != started else { return }
        started = want
        guard sink == nil, let appID else { return }
        if want {
            TelemetryDeck.initialize(config: TelemetryDeck.Config(appID: appID))
        } else {
            TelemetryDeck.terminate()
        }
    }

    // MARK: Signals. Every parameter value comes from a fixed set or is a number.

    enum Source: String { case window, region }

    /// The first word was spoken, `wait` seconds after the read was asked for.
    func readStarted(source: Source, wait: TimeInterval) {
        signal("Read.started", ["source": source.rawValue, "voice": Self.voice], value: wait)
    }

    func readFinished(words: Int, seconds: Double) {
        signal("Read.finished", ["voice": Self.voice, "speed": String(Settings.shared.speed),
                                 "minutes": Self.bucket(seconds / 60)], value: Double(words))
    }

    /// `reason`: noWindow, captureFailed or noText.
    func readFailed(_ reason: String) {
        signal("Read.failed", ["reason": reason])
    }

    /// `handsFree`: started with a tap or the menu instead of holding the shortcut.
    /// `engine`: parakeet or apple.
    func dictated(words: Int, handsFree: Bool = false, engine: String = "apple") {
        let s = Settings.shared
        let cleanup = !s.removeFillers ? "none" : s.polishDictation ? "polish" : "fillers"
        signal("Dictation.finished", ["cleanup": cleanup, "mode": handsFree ? "handsFree" : "hold", "engine": engine], value: Double(words))
    }

    private func signal(_ name: String, _ parameters: [String: String] = [:], value: Double? = nil) {
        update()
        guard started else { return }
        if let sink {
            sink(name, parameters, value)
        } else {
            TelemetryDeck.signal(name, parameters: parameters, floatValue: value)
        }
    }

    private static var voice: String { KokoroSpeaker.isSelected ? "natural" : "system" }

    /// Rough size, so a long session isn't a fingerprint: "<1", "1-5", "5-15", "15+".
    static func bucket(_ minutes: Double) -> String {
        switch minutes {
        case ..<1: return "<1"
        case ..<5: return "1-5"
        case ..<15: return "5-15"
        default: return "15+"
        }
    }
}
