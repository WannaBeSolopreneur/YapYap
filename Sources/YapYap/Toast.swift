import AppKit

/// Small HUD near the top of the screen for status ("Reading…", "Speed 1.5×").
/// Never takes focus from the app being read.
enum Toast {
    private static var panel: NSPanel?
    private static var label: NSTextField?
    private static var hideWork: DispatchWorkItem?

    static func show(_ text: String, for seconds: Double = 1.6) {
        let panel = self.panel ?? makePanel()
        label?.stringValue = text
        label?.sizeToFit()
        let size = NSSize(width: (label?.frame.width ?? 100) + 32, height: 36)
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height - 24, width: size.width, height: size.height), display: true)
        }
        label?.frame.origin = NSPoint(x: 16, y: (size.height - (label?.frame.height ?? 0)) / 2)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 }) { panel.orderOut(nil) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private static func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.sharingType = Demo.sharing

        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 10
        fx.layer?.masksToBounds = true
        p.contentView = fx

        let l = NSTextField(labelWithString: "")
        l.font = .systemFont(ofSize: 14, weight: .medium)
        l.textColor = .labelColor
        fx.addSubview(l)
        label = l
        panel = p
        return p
    }
}
