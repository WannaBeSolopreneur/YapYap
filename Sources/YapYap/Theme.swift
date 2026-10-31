import AppKit
import SwiftUI

/// YapYap's look, shared with the website: system type, the accent blue, and the yellow
/// highlight as the signature colour. Light and dark come from the dynamic colours here.
enum Theme {
    /// The website's highlight, #ffeb4d.
    static let highlight = Color(red: 1, green: 0.922, blue: 0.302)
    /// Card fill: the site's #f5f5f7 tile in light mode, a raised grey in dark.
    static let card = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.06)
            : NSColor(red: 0.961, green: 0.961, blue: 0.969, alpha: 1)
    })
    static let cornerRadius: CGFloat = 14
    static let ready = Color.green
    static let attention = Color.orange

    /// The brand navy from the icon and the website (#1b2a41); the show's powder blue (#a7c7e7) in dark mode.
    static let navy = dynamic(light: (0.106, 0.165, 0.255), dark: (0.655, 0.780, 0.906))
    /// Window and sidebar: a warm paper grey. The pages sit on `canvas`, a sheet above it.
    static let sidebar = dynamic(light: (0.949, 0.945, 0.933), dark: (0.110, 0.110, 0.118))
    static let canvas = dynamic(light: (0.988, 0.984, 0.976), dark: (0.149, 0.149, 0.157))
    static let hairline = Color.primary.opacity(0.08)

    /// The brand's pixel type, Press Start 2P (bundled in Resources/Fonts); for the wordmark only.
    static func pixel(_ size: CGFloat) -> Font { .custom("PressStart2P-Regular", size: size) }

    /// Display type for headlines and big numbers: New York, Apple's serif.
    static func display(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    private static func dynamic(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

/// YapYap's pixel mark and name, top of the sidebar, as on the website and in the TikTok show.
struct Wordmark: View {
    private static let mark = Logo.mark(points: 1.5)

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: Self.mark)
                .interpolation(.none)
                .frame(width: 24, height: 24)
            Text("YAPYAP")
                .font(Theme.pixel(13))
                .foregroundStyle(Theme.navy)
                .padding(.top, 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("YapYap")
    }
}

extension View {
    /// A rounded tile, like the cards on the website.
    func card(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    /// Small print under a Settings section.
    func settingsFootnote() -> some View {
        self.font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
    }
}

/// A shortcut drawn as large physical keys, the hero of the home window and Welcome.
struct BigKeys: View {
    let keys: [String]
    var size: CGFloat = 34

    var body: some View {
        HStack(spacing: 6) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                    .frame(minWidth: size, minHeight: size)
                    .padding(.horizontal, key.count > 1 ? 8 : 0)
                    .background(.background, in: RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).strokeBorder(.separator))
                    .shadow(color: .black.opacity(0.12), radius: 0, y: 1.5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keys.joined(separator: " "))
    }
}

/// "Press → Drag → Listen": how a shortcut is used, in the website's three-word rhythm.
struct StepRow: View {
    let steps: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(steps.indices, id: \.self) { i in
                if i > 0 {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                Text(steps[i])
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(steps.joined(separator: ", then "))
    }
}

/// A word with the reading highlight behind it.
struct Highlighted: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundStyle(.black)
            .padding(.horizontal, 3)
            .background(Theme.highlight, in: RoundedRectangle(cornerRadius: 3))
    }
}

extension KeyCombo {
    /// The same combination for a SwiftUI menu item, so menus show it; nil for keys menus can't draw.
    var keyboardShortcut: KeyboardShortcut? {
        guard keyName.count == 1, let char = keyName.lowercased().first else { return nil }
        var mods: EventModifiers = []
        if modifiers & cmdKeyMask != 0 { mods.insert(.command) }
        if modifiers & optionKeyMask != 0 { mods.insert(.option) }
        if modifiers & controlKeyMask != 0 { mods.insert(.control) }
        if modifiers & shiftKeyMask != 0 { mods.insert(.shift) }
        return KeyboardShortcut(KeyEquivalent(char), modifiers: mods)
    }
}

// Carbon's modifier masks, without importing Carbon into every view file.
private let cmdKeyMask = 1 << 8
private let shiftKeyMask = 1 << 9
private let optionKeyMask = 1 << 11
private let controlKeyMask = 1 << 12
