import AppKit
import Observation

enum HighlightStyle: String, CaseIterable {
    case yellow, peach, blue, underline

    var title: String {
        switch self {
        case .yellow: return "Soft Yellow"
        case .peach: return "Peach"
        case .blue: return "Light Blue"
        case .underline: return "Underline"
        }
    }

    var color: NSColor {
        switch self {
        case .yellow: return NSColor(red: 1.0, green: 0.92, blue: 0.3, alpha: 1)
        case .peach: return NSColor(red: 1.0, green: 0.72, blue: 0.55, alpha: 1)
        case .blue: return NSColor(red: 0.55, green: 0.8, blue: 1.0, alpha: 1)
        case .underline: return NSColor(red: 0.9, green: 0.2, blue: 0.15, alpha: 1)
        }
    }
}

/// User preferences, observable so every window updates live. Saved to UserDefaults
/// under the same keys as before.
@Observable
final class Settings {
    static let shared = Settings()
    static let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5]

    @ObservationIgnored private let defaults = UserDefaults.standard

    var speed: Double {
        didSet {
            let clamped = min(max(speed, 0.5), 2.5)
            if clamped != speed { speed = clamped }
            defaults.set(speed, forKey: "speed")
        }
    }
    var style: HighlightStyle { didSet { defaults.set(style.rawValue, forKey: "style") } }
    var opacity: Double { didSet { defaults.set(opacity, forKey: "opacity") } }
    var ruler: Bool { didSet { defaults.set(ruler, forKey: "ruler") } }
    var voiceID: String? { didSet { defaults.set(voiceID, forKey: "voiceID") } }
    var hasOnboarded: Bool { didSet { defaults.set(hasOnboarded, forKey: "hasOnboarded") } }
    /// Don't read web and email addresses aloud.
    var skipLinks: Bool { didSet { defaults.set(skipLinks, forKey: "skipLinks") } }
    var regionShortcut: KeyCombo {
        didSet { defaults.set(try? JSONEncoder().encode(regionShortcut), forKey: "regionShortcut") }
    }
    /// Strip um, uh and the like from dictation.
    var removeFillers: Bool { didSet { defaults.set(removeFillers, forKey: "removeFillers") } }
    /// Then tidy it with Apple Intelligence, on device.
    var polishDictation: Bool { didSet { defaults.set(polishDictation, forKey: "polishDictation") } }
    /// Remember what was read and dictated, for the home page. Totals are kept either way.
    var keepHistory: Bool { didSet { defaults.set(keepHistory, forKey: "keepHistory") } }
    /// Before dictating, read the names in the window you're typing in so they're spelled right.
    var useScreenContext: Bool { didSet { defaults.set(useScreenContext, forKey: "useScreenContext") } }
    /// Fetch the natural (Kokoro) voices on launch when they're missing. Turned off when you remove them.
    var autoDownloadVoices: Bool { didSet { defaults.set(autoDownloadVoices, forKey: "autoDownloadVoices") } }
    /// Send anonymous usage stats (counts and timings, never text). On unless turned off.
    var shareUsageStats: Bool { didSet { defaults.set(shareUsageStats, forKey: "shareUsageStats") } }
    /// Held down to dictate.
    var dictationShortcut: KeyCombo {
        didSet { defaults.set(try? JSONEncoder().encode(dictationShortcut), forKey: "dictationShortcut") }
    }

    private init() {
        speed = defaults.object(forKey: "speed") as? Double ?? 1.0
        style = HighlightStyle(rawValue: defaults.string(forKey: "style") ?? "") ?? .yellow
        opacity = defaults.object(forKey: "opacity") as? Double ?? 0.45
        ruler = defaults.bool(forKey: "ruler")
        voiceID = defaults.string(forKey: "voiceID")
        hasOnboarded = defaults.bool(forKey: "hasOnboarded")
        skipLinks = defaults.object(forKey: "skipLinks") as? Bool ?? true
        regionShortcut = defaults.data(forKey: "regionShortcut").flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) } ?? .defaultRegion
        keepHistory = defaults.object(forKey: "keepHistory") as? Bool ?? true
        removeFillers = defaults.object(forKey: "removeFillers") as? Bool ?? true
        polishDictation = defaults.object(forKey: "polishDictation") as? Bool ?? true
        autoDownloadVoices = defaults.object(forKey: "autoDownloadVoices") as? Bool ?? true
        useScreenContext = defaults.object(forKey: "useScreenContext") as? Bool ?? true
        shareUsageStats = defaults.object(forKey: "shareUsageStats") as? Bool ?? true
        dictationShortcut = defaults.data(forKey: "dictationShortcut").flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) } ?? .defaultDictation
    }
}
