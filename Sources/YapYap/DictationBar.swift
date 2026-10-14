import AppKit
import SwiftUI

/// Glass capsule at the bottom of the screen while dictating: mic level and the words so far.
/// Never takes focus, so the text lands in the app you were typing in.
final class DictationPanel: NSPanel {
    private var host: NSHostingView<AnyView>?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        isMovable = false
        ignoresMouseEvents = true
        level = .statusBar
        sharingType = Demo.sharing
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Bottom centre of the screen with the mouse on it.
    func show() {
        if host == nil {
            // Built lazily: AppModel.shared owns this panel and must finish initializing first.
            let view = NSHostingView(rootView: AnyView(DictationBarView().environment(AppModel.shared)))
            view.sizingOptions = [.intrinsicContentSize]
            contentView = view
            host = view
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let area = screen?.visibleFrame, let size = host?.fittingSize else { return }
        setFrame(NSRect(x: (area.midX - size.width / 2).rounded(), y: area.minY + 20, width: size.width, height: size.height), display: true)
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; animator().alphaValue = 1 }
    }

    func fadeOut() {
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; animator().alphaValue = 0 }) { [weak self] in
            guard let self, self.alphaValue == 0 else { return }
            self.orderOut(nil)
        }
    }
}

struct DictationBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            mic
            Text(caption)
                .font(.callout)
                .foregroundStyle(model.dictationText.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(width: 300, alignment: .leading)
                .animation(nil, value: model.dictationText)
            KeyCaps(keys: model.settings.dictationShortcut.displayKeys)
                .opacity(model.dictationPhase == .listening ? 1 : 0)
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .glassBackground(in: Capsule())
        .padding(12) // room for the glass shadow inside the panel
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private var caption: String {
        switch model.dictationPhase {
        case .starting: return "Getting ready…"
        case .finishing: return model.dictationText.isEmpty ? "Finishing…" : model.dictationText
        case .polishing: return "Tidying up…"
        case .idle, .listening: return model.dictationText.isEmpty ? "Listening… let go to type" : model.dictationText
        }
    }

    @ViewBuilder
    private var mic: some View {
        ZStack {
            Circle()
                .fill(.red.opacity(0.18))
                .scaleEffect(0.75 + 0.6 * CGFloat(model.micLevel))
                .animation(.easeOut(duration: 0.08), value: model.micLevel)
            if model.dictationPhase == .polishing {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tint)
                    .symbolEffect(.pulse)
            } else if model.dictationPhase == .starting || model.dictationPhase == .finishing {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.red)
            }
        }
        .frame(width: 28, height: 28)
    }
}
