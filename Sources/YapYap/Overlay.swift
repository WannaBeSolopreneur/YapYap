import AppKit

/// Transparent, click-through panel laid exactly over the window being read.
final class OverlayPanel: NSPanel {
    let highlight = HighlightView()

    init(frame: CGRect) {
        super.init(contentRect: Geometry.flip(frame), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        sharingType = Demo.sharing
        contentView = highlight
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Moves to a new CoreGraphics (top-left) frame.
    func place(_ frame: CGRect) {
        setFrame(Geometry.flip(frame), display: true)
    }
}

final class HighlightView: NSView {
    /// Normalized, bottom-left origin — the same space as Vision boxes.
    var word: CGRect? { didSet { needsDisplay = true } }
    var line: CGRect? { didSet { needsDisplay = true } }
    var onClick: ((CGPoint) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        onClick?(CGPoint(x: p.x / bounds.width, y: p.y / bounds.height))
    }

    func clear() {
        word = nil
        line = nil
    }

    private func denormalize(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX * bounds.width, y: r.minY * bounds.height, width: r.width * bounds.width, height: r.height * bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let settings = Settings.shared

        if settings.ruler, let line {
            let band = denormalize(line).insetBy(dx: 0, dy: -4)
            NSColor.black.withAlphaComponent(0.35).setFill()
            NSRect(x: 0, y: band.maxY, width: bounds.width, height: bounds.height - band.maxY).fill()
            NSRect(x: 0, y: 0, width: bounds.width, height: max(band.minY, 0)).fill()
        }

        guard let word else { return }
        let r = denormalize(word).insetBy(dx: -3, dy: -2)
        let color = settings.style.color
        if settings.style == .underline {
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY - 1, width: r.width, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
        } else {
            color.withAlphaComponent(settings.opacity).setFill()
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        }
    }
}
