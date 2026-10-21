import SwiftUI

/// Which page the main window shows. Shared so the menu bar and ⌘, can open a page directly.
@Observable
final class Navigation {
    static let shared = Navigation()

    enum Page: String, CaseIterable, Identifiable {
        case home, reading, dictation, saved, settings
        var id: Self { self }

        var title: String {
            switch self {
            case .home: return "Home"
            case .reading: return "Reading"
            case .dictation: return "Dictation"
            case .saved: return "Saved"
            case .settings: return "Settings"
            }
        }

        var symbol: String {
            switch self {
            case .home: return "house"
            case .reading: return "speaker.wave.2"
            case .dictation: return "mic"
            case .saved: return "list.bullet.clipboard"
            case .settings: return "gearshape"
            }
        }
    }

    var page = Page.home
}

/// The main window: sidebar with the wordmark and pages, and the current page on a sheet beside it.
struct AppShell: View {
    @Environment(AppModel.self) private var model
    @State private var navigation = Navigation.shared

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(navigation: navigation)
                .frame(width: 210)
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.canvas, in: pageShape)
                // Clipped, the 1 pt stroke leaves a half-point hairline inside the edge.
                .overlay(pageShape.stroke(Theme.hairline, lineWidth: 1))
                .clipShape(pageShape)
                .padding([.top, .bottom, .trailing], 8)
        }
        .background(Theme.sidebar)
        .ignoresSafeArea()
        .onAppear { model.refreshPermission() }
    }

    /// The sheet the pages sit on. Its right-hand corners follow the window's own corner curve
    /// (macOS 26+), so the two outlines run parallel instead of meeting at odd angles.
    private var pageShape: AnyShape {
        if #available(macOS 26, *) {
            return AnyShape(ConcentricRectangle(topLeadingCorner: .fixed(12), topTrailingCorner: .concentric(minimum: .fixed(12)),
                                                          bottomLeadingCorner: .fixed(12), bottomTrailingCorner: .concentric(minimum: .fixed(12))))
        }
        return AnyShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var page: some View {
        switch navigation.page {
        case .home: HomePage()
        case .reading: SettingsPage(title: "Reading", subtitle: "How YapYap sounds and how it highlights.") { ReadingSettings() }
        case .dictation: SettingsPage(title: "Dictation", subtitle: "What happens to your words before they're typed.") { DictationSettings() }
        case .saved: SettingsPage(title: "Saved", subtitle: "Say a name to paste it: your email address, a home address, an API key.") { SavedTextSettings() }
        case .settings: SettingsPage(title: "Settings", subtitle: "Shortcuts, permissions and history.") { GeneralSettings() }
        }
    }
}

private struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Bindable var navigation: Navigation

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Wordmark()
                .padding(.horizontal, 10)
                .padding(.top, 52) // below the window's traffic lights
                .padding(.bottom, 22)

            ForEach([Navigation.Page.home, .reading, .dictation, .saved]) { page in
                item(page)
            }

            Spacer()

            Divider().padding(.horizontal, 6).padding(.bottom, 8)
            item(.settings, badge: !model.allPermissionsGranted)
            SidebarButton(title: "Help", symbol: "questionmark.circle", selected: false) {
                WelcomeWindow.show(at: 0)
            }
            .padding(.bottom, 14)
        }
        .padding(.horizontal, 10)
    }

    private func item(_ page: Navigation.Page, badge: Bool = false) -> some View {
        SidebarButton(title: page.title, symbol: page.symbol, selected: navigation.page == page, badge: badge) {
            navigation.page = page
        }
    }
}

private struct SidebarButton: View {
    let title: String
    let symbol: String
    let selected: Bool
    var badge = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                Spacer()
                if badge {
                    Text("1")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Color.red.opacity(0.85), in: Circle())
                        .accessibilityLabel("Needs attention")
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(selected ? Color.primary.opacity(0.08) : hovering ? Color.primary.opacity(0.04) : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A Settings form as a page: big title, a line of explanation, then the form.
private struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 26, weight: .semibold))
                    .tracking(-0.4)
                Text(subtitle)
                    .foregroundStyle(.secondary)
                content
                    .scrollContentBackground(.hidden) // sections sit straight on the page
                    .padding(.horizontal, -20) // the grouped form brings its own margins
                    .padding(.top, 6)
            }
            .frame(maxWidth: 600, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.top, 40)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
    }
}
