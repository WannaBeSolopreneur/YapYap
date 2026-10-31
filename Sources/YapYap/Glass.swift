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

/// YapYap's logo: the app icon, the pixel mark, or a monochrome template version for the menu bar.
enum Logo {
    static var appIcon: Image { Image(nsImage: NSApp.applicationIconImage) }

    /// The mark from the website and the TikTok show: a pixel speech bubble with the yellow highlight across it.
    /// Same 16x16 grid as web/brand/make_brand.py. # ink, w/p/s bubble light/fill/shade, t text, y highlight.
    static let grid = [
        "................",
        "...##########...",
        "..#wwwwwwwwww#..",
        ".#ppttttttttpp#.",
        ".#pppppppppppp#.",
        "#yyyyyyyyyyyyyy#",
        "#yyyyyyyyyyyyyy#",
        ".#pppppppppppp#.",
        ".#ppttttttttpp#.",
        ".#pppppppppppp#.",
        ".#pptttttppppp#.",
        "..#ssssssssss#..",
        "...#ss#######...",
        "...#s#..........",
        "....#...........",
        "................",
    ]

    private static func draw(points: CGFloat, color: (Character) -> NSColor?) -> NSImage {
        var cells: [(NSRect, NSColor)] = []
        for (y, row) in grid.enumerated() {
            for (x, c) in row.enumerated() {
                if let fill = color(c) { cells.append((NSRect(x: CGFloat(x) * points, y: CGFloat(y) * points, width: points, height: points), fill)) }
            }
        }
        return NSImage(size: NSSize(width: 16 * points, height: 16 * points), flipped: true) { _ in
            for (rect, fill) in cells { fill.setFill(); rect.fill() }
            return true
        }
    }

    private static func hex(_ v: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }

    /// The full-colour mark, `points` per pixel (1.5 draws it 24 pt wide, crisp on Retina).
    static func mark(points: CGFloat) -> NSImage {
        let palette: [Character: NSColor] = ["#": hex(0x0f1828), "w": hex(0xdcebf7), "p": hex(0xa7c7e7),
                                             "s": hex(0x5b7db1), "t": hex(0x3e5c84), "y": hex(0xffd166)]
        return draw(points: points) { palette[$0] }
    }

    /// Menu bar: the bubble's outline and the highlight solid, the text lines faint, the inside clear.
    static let menuBar: NSImage = {
        let image = draw(points: 1) { c in
            switch c {
            case "#", "y": .black
            case "t": .black.withAlphaComponent(0.5)
            default: nil
            }
        }
        image.isTemplate = true
        return image
    }()
}
