import AppKit
import SwiftUI

/// YapYap's main window: sidebar and pages. Opens on launch and when you click the Dock icon.
/// Closing it leaves YapYap running, with its shortcuts and menu-bar icon, and frees the
/// window: a hidden SwiftUI hierarchy would keep redrawing on every state change.
enum MainWindow {
    private static var window: NSWindow?
    private static var closeObserver: Any?

    static func show(_ page: Navigation.Page? = nil) {
        if let page { Navigation.shared.page = page }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "YapYap"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 860, height: 560)
            w.contentViewController = NSHostingController(rootView: AppShell().environment(AppModel.shared))
            w.setFrameAutosaveName("MainWindow")
            if !w.setFrameUsingName("MainWindow") || w.frame.width < 860 {
                w.setContentSize(NSSize(width: 1000, height: 680))
                w.center()
            }
            window = w
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
                closeObserver = nil
                // After AppKit finishes closing it.
                DispatchQueue.main.async { window = nil }
            }
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
