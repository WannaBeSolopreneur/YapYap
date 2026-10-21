import AppKit
import SwiftUI

/// `YapYap --snapshots <dir>` renders every surface, light and dark, to PNGs for design review.
enum Snapshots {
    static func run(into dir: URL, sample: Bool = false) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let model = sample ? sampleModel() : AppModel.shared
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let surfaces: [(String, AnyView)] = [
            ("menubar-icon", AnyView(Image(nsImage: Logo.menuBar).resizable().frame(width: 72, height: 64))),
            ("app-home", AnyView(PageSnapshot(page: .home))),
            ("app-home-narrow", AnyView(PageSnapshot(page: .home, width: 860))),
            ("app-reading", AnyView(PageSnapshot(page: .reading))),
            ("app-settings", AnyView(PageSnapshot(page: .settings))),
            ("bar", AnyView(PlayerBarView())),
            ("dictation", AnyView(DictationBarView())),
            ("dictation-leftover", AnyView(DictationBarView().environment(leftoverModel()))),
            ("settings-reading", AnyView(ReadingSettings().frame(width: 520))),
            ("settings-dictation", AnyView(DictationSettings().frame(width: 520))),
            ("settings-general", AnyView(GeneralSettings().frame(width: 520))),
            ("settings-saved", AnyView(SavedTextSettings(store: SavedText(storage: MemoryStorage(items: [
                SavedItem(name: "Email address", value: "sam@example.com"),
                SavedItem(name: "Home address", value: "1 Main Street, Springfield"),
                SavedItem(name: "ElevenLabs key", value: "sk_0123456789abcdef", secret: true),
                SavedItem(name: "", value: "sam@work.example.com"),
                SavedItem(name: "", value: ""),
            ]))).frame(width: 560))),
            ("dictation-saved", AnyView(DictationBarView().environment(confirmingModel()))),
            ("save-selection-key", AnyView(SaveSelectionView(text: "sk-ant-api03-AbCdEf0123456789xyz", name: "Anthropic key", secret: true) { _ in })),
            ("save-selection-text", AnyView(SaveSelectionView(text: "sam@example.com", name: "Email address", secret: false) { _ in })),
            ("welcome-1", AnyView(WelcomeView(initialStep: 0))),
            ("welcome-2", AnyView(WelcomeView(initialStep: 1))),
            ("welcome-3", AnyView(WelcomeView(initialStep: 2))),
        ]
        for (name, dragging) in [("selector-idle", false), ("selector-drag", true)] {
            let size = NSSize(width: 760, height: 440)
            let page = NSHostingView(rootView: SamplePage().frame(width: size.width, height: size.height))
            page.frame = NSRect(origin: .zero, size: size)
            let selector = SelectionView { _ in }
            selector.frame = page.bounds
            if dragging { selector.preview(from: NSPoint(x: 90, y: 300), to: NSPoint(x: 520, y: 170)) }
            let container = NSView(frame: page.frame)
            container.addSubview(page)
            container.addSubview(selector)
            selector.needsLayout = true
            renderView(container, appearance: .aqua, to: dir.appendingPathComponent("\(name).png"))
        }
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            for (name, view) in surfaces {
                render(view.environment(model), appearance: appearance, to: dir.appendingPathComponent("\(name)-\(suffix).png"))
            }
        }
    }

    /// The capsule about to paste a saved item.
    private static func confirmingModel() -> AppModel {
        let model = AppModel(history: History(file: nil))
        model.previewSaved("Pasting ElevenLabs key…")
        return model
    }

    /// The capsule after dictating with no text box in focus.
    private static func leftoverModel() -> AppModel {
        let model = AppModel(history: History(file: nil))
        model.previewLeftover("Hi Siobhan, can you send the Fernway numbers to Tadhg and Priya Shah before Thursday? I'll bring the slides.")
        return model
    }

    /// Made-up history and name, so screenshots never show what you really read or said.
    private static func sampleModel() -> AppModel {
        let history = History(file: nil)
        history.addRead("The quiet return of the public library. Visits are up for the third year in a row.", words: 1840, seconds: 610, keep: true)
        history.addDictation("Sounds good. I'll bring my laptop and the numbers. See you on the fourth floor at nine.", keep: true)
        history.addRead("Sleep and Recall in Adult Learners. Adults who slept within three hours of a study session recalled more.", words: 960, seconds: 330, keep: true)
        history.addDictation("Hi Brenda, yeah, I can do the numbers. The venue's booked for Wednesday and I'll present the roadmap.", keep: true)
        history.addDictation("Pick up dry cleaning and renew passport.", keep: true)
        let model = AppModel(history: history)
        model.fullUserName = "Sam Rivera"
        return model
    }

    private static func render(_ view: some View, appearance: NSAppearance.Name, to url: URL) {
        let host = NSHostingView(rootView: view.padding(20).background(Color(nsColor: .windowBackgroundColor)))
        host.frame.size = host.fittingSize
        renderView(host, appearance: appearance, to: url)
    }

    private static func renderView(_ host: NSView, appearance: NSAppearance.Name, to url: URL) {
        host.appearance = NSAppearance(named: appearance)
        let size = host.frame.size
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}


/// A plain document page to draw the region selector over.
private struct SamplePage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Chapter 3").font(.title.bold())
            Text("Reading along makes it easier to stay focused. Each word lights up as it is spoken, so your eyes never lose their place. When the page scrolls, the highlight follows.")
            Text("Select any part of the screen and YapYap will read just that part, in reading order, even across columns.")
            Text("Nothing leaves your Mac.").foregroundStyle(.secondary)
        }
        .font(.system(size: 17, design: .serif))
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white)
        .foregroundStyle(.black)
    }
}

/// The main window on a given page.
private struct PageSnapshot: View {
    let page: Navigation.Page
    var width: CGFloat = 1000
    var body: some View {
        AppShell()
            .frame(width: width, height: 680)
            .onAppear { Navigation.shared.page = page }
            .onDisappear { Navigation.shared.page = .home }
    }
}
