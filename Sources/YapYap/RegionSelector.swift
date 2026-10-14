import AppKit
import SwiftUI

/// Dims every screen and lets the user drag a rectangle. Esc or right-click cancels.
final class RegionSelector {
    private var panels: [NSPanel] = []
    private var escape: HotKey?
    private var completion: ((CGRect?) -> Void)?

    /// Calls back with the region in CoreGraphics (top-left) coordinates, or nil.
    func begin(_ completion: @escaping (CGRect?) -> Void) {
        finish(nil)
        self.completion = completion
        for screen in NSScreen.screens {
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .screenSaver
            panel.hasShadow = false
            panel.isReleasedWhenClosed = false
            panel.ignoresMouseEvents = false // explicit false also catches clicks on transparent pixels
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.sharingType = Demo.sharing
            let view = SelectionView { [weak self] rect in self?.finish(rect) }
            panel.contentView = view
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panels.forEach { $0.animator().alphaValue = 1 }
        }
        NSCursor.crosshair.push()
        escape = HotKey(keyCode: Keys.escape, modifiers: 0) { [weak self] in self?.finish(nil) }
    }

    private func finish(_ appKitRect: NSRect?) {
        guard completion != nil || !panels.isEmpty else { return }
        panels.forEach { $0.orderOut(nil) }
        panels = []
        escape = nil
        NSCursor.pop()
        let done = completion
        completion = nil
        done?(appKitRect.map(Geometry.flip))
    }
}

final class SelectionView: NSView {
    private let onDone: (NSRect?) -> Void
    private var start: NSPoint?
    private var current: NSPoint?
    private let hint = PassthroughHostingView(rootView: SelectionHint())

    private static let dim = NSColor.black.withAlphaComponent(0.32)
    private static let radius: CGFloat = 6

    init(onDone: @escaping (NSRect?) -> Void) {
        self.onDone = onDone
        super.init(frame: .zero)
        addSubview(hint)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func layout() {
        super.layout()
        // Top centre, clear of the menu bar.
        let size = hint.fittingSize
        let top = window?.screen.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 0
        hint.frame = NSRect(x: (bounds.width - size.width) / 2, y: bounds.height - top - size.height - 16, width: size.width, height: size.height)
    }

    private var selection: NSRect? {
        guard let start, let current else { return nil }
        return NSRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(start.x - current.x), height: abs(start.y - current.y))
            .integral
    }

    /// For `--snapshots`: shows a selection without dragging.
    func preview(from a: NSPoint, to b: NSPoint) {
        start = a
        current = b
        hint.alphaValue = 0
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; hint.animator().alphaValue = 0 }
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        guard let rect = selection, rect.width > 12, rect.height > 8, let window else { return onDone(nil) }
        onDone(window.convertToScreen(convert(rect, to: nil)))
    }

    override func rightMouseDown(with event: NSEvent) { onDone(nil) }

    override func draw(_ dirtyRect: NSRect) {
        guard let rect = selection, rect.width > 1, rect.height > 1 else {
            Self.dim.setFill()
            bounds.fill()
            return
        }
        let hole = NSBezierPath(roundedRect: rect, xRadius: Self.radius, yRadius: Self.radius)

        // Dim everything except the selection. Nearly clear (not fully: fully transparent
        // pixels drop mouse events) so the text being chosen reads undimmed.
        let outside = NSBezierPath(rect: bounds)
        outside.append(hole)
        outside.windingRule = .evenOdd
        Self.dim.setFill()
        outside.fill()
        NSColor.black.withAlphaComponent(0.01).setFill()
        hole.fill()

        // Hairline dark edge so the white border shows on white pages too.
        NSColor.black.withAlphaComponent(0.35).setStroke()
        let edge = NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: Self.radius + 1, yRadius: Self.radius + 1)
        edge.lineWidth = 1
        edge.stroke()
        NSColor.white.setStroke()
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: Self.radius, yRadius: Self.radius)
        border.lineWidth = 1.5
        border.stroke()

        drawHandles(rect)
        drawSize(rect)
    }

    private func drawHandles(_ rect: NSRect) {
        guard rect.width > 30, rect.height > 30 else { return }
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor.white.setFill()
        for p in [NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: rect.maxX, y: rect.minY),
                  NSPoint(x: rect.minX, y: rect.maxY), NSPoint(x: rect.maxX, y: rect.maxY)] {
            NSBezierPath(ovalIn: NSRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// "640 × 320" in a dark pill under the selection, or inside it near the screen's bottom edge.
    private func drawSize(_ rect: NSRect) {
        let text = "\(Int(rect.width)) × \(Int(rect.height))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        let pill = NSSize(width: size.width + 16, height: size.height + 8)
        var origin = NSPoint(x: rect.midX - pill.width / 2, y: rect.minY - pill.height - 8)
        if origin.y < 8 { origin.y = rect.minY + 8 }
        origin.x = min(max(origin.x, 8), bounds.width - pill.width - 8)
        let box = NSRect(origin: origin, size: pill)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: box, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        text.draw(at: NSPoint(x: box.minX + 8, y: box.minY + 4), withAttributes: attrs)
    }
}

/// Lets clicks fall through to the selection view underneath.
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct SelectionHint: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.dashed")
                .foregroundStyle(.secondary)
            Text("Drag over the text to read")
                .font(.callout.weight(.medium))
            Text("esc")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
            Text("to cancel")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .glassBackground(in: Capsule())
        .padding(10)
        .fixedSize()
    }
}
