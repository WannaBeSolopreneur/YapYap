import AppKit
import YapYapCore

/// When dictation starts: the names and terms in the window you're typing in, so the recognizer
/// spells them right ("Priya", not "Prius"). One still image, read with Vision on this Mac and
/// thrown away; only the word list reaches the recognizer, and nothing is kept.
enum ScreenContext {
    /// Calls back on the main queue, only when there's something useful. Needs Screen Recording.
    static func terms(in app: NSRunningApplication?, done: @escaping ([String]) -> Void) {
        guard Settings.shared.useScreenContext, Capture.hasPermission,
              let pid = app?.processIdentifier, let window = Capture.frontWindow(of: pid) else { return }
        Capture.image(of: window.id) { image in
            guard let image else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let lines = (try? OCR.lines(in: image, fast: true)) ?? []
                let terms = ContextTerms.from(lines.map(\.text).joined(separator: "\n"))
                DispatchQueue.main.async { if !terms.isEmpty { done(terms) } }
            }
        }
    }
}
