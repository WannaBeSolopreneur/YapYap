import SwiftUI

/// The menu-bar icon's menu: a native macOS menu for a quick glance and the controls that
/// matter right now. The home window and Settings hold everything else.
struct StatusMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.allPermissionsGranted {
            Button("Finish Setup…") { WelcomeWindow.show(at: WelcomeWindow.permissionsStep) }
            Divider()
        }

        if model.dictationPhase != .idle {
            Text(model.dictationPhase == .polishing ? "Tidying up…" : "Listening…")
            Divider()
        } else if model.isReading {
            Text(readingStatus)
            Button(model.phase == .paused ? "Resume" : "Pause") { model.togglePause() }
                .keyboardShortcut("p", modifiers: [.option, .command])
            Button("Previous Sentence") { model.skip(by: -1) }
            Button("Next Sentence") { model.skip(by: 1) }
            Button("Stop") { model.stop() }
            Divider()
        }

        Button("Read Aloud") { model.readRegion() }
            .keyboardShortcut(model.settings.regionShortcut.keyboardShortcut)
            .disabled(!model.hasPermission)
        Text("Dictate: hold \(model.settings.dictationShortcut.displayKeys.joined())")

        Divider()

        Button("Open YapYap") { MainWindow.show() }
        Button("Settings…") { MainWindow.show(.settings) }
            .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit YapYap") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    private var readingStatus: String {
        switch model.phase {
        case .preparing: return "Getting ready…"
        case .paused: return "Paused · \(Int(model.progress * 100))%"
        default: return "Reading · \(Int(model.progress * 100))%"
        }
    }
}
