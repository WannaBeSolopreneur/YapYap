import SwiftUI

/// Liquid Glass on macOS 26+, the frosted materials of earlier releases otherwise,
/// so views are written once.
extension View {
    @ViewBuilder
    func glassBackground(in shape: some Shape, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.stroke(.primary.opacity(0.08), lineWidth: 0.5))
        }
    }

    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}

/// Groups glass shapes so they blend into each other on macOS 26+.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// A keyboard shortcut drawn as keycaps, e.g. ⌥ ⌘ R.
struct KeyCaps: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .frame(minWidth: 18, minHeight: 18)
                    .padding(.horizontal, key.count > 1 ? 4 : 0)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            }
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keys.joined(separator: " "))
    }
}

extension HighlightStyle {
    var swiftUIColor: Color { Color(nsColor: color) }
}

enum Shortcuts {
    /// The rest, beyond the two main shortcuts. (⌥⌘R, read the front window, still works but
    /// isn't advertised: reading a region is the one way to read.)
    static let fixed: [(title: String, keys: [String])] = [
        ("Pause or resume", ["⌥", "⌘", "P"]),
        ("Faster", ["⌥", "⌘", "="]),
        ("Slower", ["⌥", "⌘", "−"]),
        ("Stop", ["esc"]),
        ("Read from a word", ["⌥", "click"]),
    ]
}

/// YapYap's logo: the app icon, or a monochrome template version for the menu bar.
enum Logo {
    static var appIcon: Image { Image(nsImage: NSApp.applicationIconImage) }

    /// Three text lines with the highlighted one in the middle, as in the app icon.
    static let menuBar: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 16), flipped: true) { _ in
            NSColor.black.withAlphaComponent(0.55).setFill()
            for (y, w) in [(1.5, 13.0), (5.0, 11.0), (12.5, 13.0)] {
                NSBezierPath(roundedRect: NSRect(x: 3, y: y, width: w, height: 1.6), xRadius: 0.8, yRadius: 0.8).fill()
            }
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 1, y: 7.6, width: 16, height: 3.6), xRadius: 1.8, yRadius: 1.8).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
