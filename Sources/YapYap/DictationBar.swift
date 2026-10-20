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

    /// Bumped by show(), so a fade-out that's still finishing doesn't hide what was just shown.
    private var generation = 0

    /// Bottom centre of the screen with the mouse on it.
    func show() {
        generation += 1
        if host == nil {
            // Built lazily: AppModel.shared owns this panel and must finish initializing first.
            let view: NSHostingView<AnyView> = FirstClickHostingView(rootView: AnyView(DictationBarView().environment(AppModel.shared)))
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
        let shown = generation
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; animator().alphaValue = 0 }) { [weak self] in
            guard let self, self.generation == shown else { return }
            self.orderOut(nil)
        }
    }

    /// Fits the panel to its content again, keeping it at the bottom centre: the Copy card is
    /// taller than the capsule. Call after the content has had a chance to redraw.
    func refit() {
        guard isVisible, let size = host?.fittingSize, size != frame.size else { return }
        setFrame(NSRect(x: (frame.midX - size.width / 2).rounded(), y: frame.minY, width: size.width, height: size.height), display: true)
    }
}

/// The panel never becomes key, so the first click has to count: Done and Cancel work in one click
/// while the app you're typing in keeps focus.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct DictationBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let text = model.leftover {
            LeftoverCard(text: text)
        } else {
            capsule
        }
    }

    private var capsule: some View {
        HStack(spacing: 12) {
            mic
            Text(caption)
                .font(.callout)
                .foregroundStyle(model.dictationText.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(width: 300, alignment: .leading)
                .animation(nil, value: model.dictationText)
            // Same width either way, so the capsule doesn't resize when hands-free starts.
            ZStack(alignment: .trailing) {
                if model.dictationHandsFree {
                    HStack(spacing: 6) {
                        capsuleButton("xmark", label: "Cancel", tint: .secondary) { model.cancelDictation() }
                        capsuleButton("checkmark", label: "Done", tint: .accentColor) { model.finishDictation() }
                    }
                } else {
                    KeyCaps(keys: model.settings.dictationShortcut.displayKeys)
                        .opacity(model.dictationPhase == .listening ? 1 : 0)
                }
            }
            .frame(width: 62, alignment: .trailing)
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .glassBackground(in: Capsule())
        .padding(12) // room for the glass shadow inside the panel
        .fixedSize()
        .accessibilityElement(children: model.dictationHandsFree ? .contain : .combine)
    }

    private func capsuleButton(_ symbol: String, label: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(.primary.opacity(0.08), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private var caption: String {
        switch model.dictationPhase {
        case .starting: return "Getting ready…"
        case .finishing: return model.dictationText.isEmpty ? "Finishing…" : model.dictationText
        case .polishing: return "Tidying up…"
        case .idle, .listening:
            guard model.dictationText.isEmpty else { return model.dictationText }
            if model.dictationHandsFree {
                return "Listening… press \(model.settings.dictationShortcut.displayKeys.joined()) or ✓ to type"
            }
            return "Listening… let go to type"
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

/// Dictated with nowhere to type: everything that was said, ready to copy and paste anywhere.
private struct LeftoverCard: View {
    @Environment(AppModel.self) private var model
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble")
                    .foregroundStyle(.secondary)
                Text("No text box here. Copy it and paste anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button { model.dismissLeftover() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(.primary.opacity(0.08), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Close (Esc)")
                .accessibilityLabel("Close")
            }
            Text(text)
                .font(.callout)
                .lineLimit(8)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Spacer()
                // Drawn by hand: the panel never becomes key (your app keeps focus), and system
                // prominent buttons turn grey in windows that aren't key.
                Button { model.copyLeftover() } label: {
                    Label(model.leftoverCopied ? "Copied" : "Copy",
                          systemImage: model.leftoverCopied ? "checkmark" : "doc.on.doc")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .frame(minWidth: 96)
                        .background(model.leftoverCopied ? Color.green : Color.accentColor, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(model.leftoverCopied)
                .accessibilityLabel(model.leftoverCopied ? "Copied" : "Copy")
            }
        }
        .padding(14)
        .frame(width: 400)
        .glassBackground(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(12) // room for the glass shadow inside the panel
        .fixedSize()
    }
}
