import AppKit
import SwiftUI

struct YapYapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            StatusMenu()
                .environment(model)
        } label: {
            Group {
                if let symbol = model.menuBarSymbol {
                    Image(systemName: symbol)
                } else {
                    Image(nsImage: Logo.menuBar)
                }
            }
            .accessibilityLabel("YapYap")
        }
        .menuBarExtraStyle(.menu)

        // Settings are pages in the main window; ⌘, opens that page.
        .commands {
            CommandGroup(after: .appInfo) {
                if Updates.shared.isAvailable {
                    Button("Check for Updates…") { Updates.shared.checkNow() }
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { MainWindow.show(.settings) }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

extension AppModel {
    /// nil shows the logo.
    var menuBarSymbol: String? {
        switch phase {
        case .idle, .preparing: return nil
        case .reading: return "speaker.wave.2.fill"
        case .paused: return "pause.circle"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ note: Notification) {
        let model = AppModel.shared
        model.openWelcome = { WelcomeWindow.show() }

        model.registerHotKeys()
        model.telemetry.update()
        Updates.shared.start()
        model.downloadVoicesIfNeeded()
        if model.settings.dictationEngine == .parakeet { ParakeetEngine.prepare() }

        // Remember the last app the user was in, in case one of our windows is frontmost.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != getpid() else { return }
            model.controller.lastApp = app
        }
        model.controller.lastApp = NSWorkspace.shared.frontmostApplication

        // `open -a YapYap --args --welcome` shows the first-launch guide again, for checking it.
        if CommandLine.arguments.contains("--welcome") {
            WelcomeWindow.show(at: 0)
        } else if !Settings.shared.hasOnboarded || !WelcomeWindow.allGranted {
            WelcomeWindow.show()
        } else {
            MainWindow.show()
        }
    }

    /// Dock icon clicked, or opened again from Finder or Spotlight.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { MainWindow.show() }
        return true
    }

    func applicationDidBecomeActive(_ note: Notification) {
        AppModel.shared.refreshPermission()
    }
}
