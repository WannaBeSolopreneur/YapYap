import AppKit
import SwiftUI

/// Floating glass capsule at the bottom of the screen while reading. Never takes focus
/// from the app being read; kept out of captures via `Controller.excludedWindows`.
final class PlayerBarPanel: NSPanel {
    private var host: NSHostingView<AnyView>?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        isMovable = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Bottom centre of the screen showing `frame` (global, top-left origin).
    func show(near frame: CGRect) {
        if host == nil {
            // Built lazily: AppModel.shared owns this panel and must finish initializing first.
            let view = NSHostingView(rootView: AnyView(PlayerBarView().environment(AppModel.shared)))
            view.sizingOptions = [.intrinsicContentSize]
            contentView = view
            host = view
        }
        let appKitFrame = Geometry.flip(frame)
        let screen = NSScreen.screens.first { $0.frame.intersects(appKitFrame) } ?? NSScreen.main
        guard let area = screen?.visibleFrame, let size = host?.fittingSize else { return }
        let origin = NSPoint(x: (area.midX - size.width / 2).rounded(), y: area.minY + 20)
        setFrame(NSRect(origin: origin, size: size), display: true)

        if !isVisible {
            alphaValue = 0
            orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; animator().alphaValue = 1 }
    }

    func fadeOut() {
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; animator().alphaValue = 0 }) { [weak self] in
            guard let self, self.alphaValue == 0 else { return }
            self.orderOut(nil)
        }
    }
}

struct PlayerBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            TransportButtons(size: .large, showsStop: false)

            Divider().frame(height: 22)

            status
                .frame(width: 150, alignment: .leading)

            speedMenu

            Button {
                model.stop()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.borderless)
            .help("Stop (esc)")
            .accessibilityLabel("Stop")
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { progressLine }
        .glassBackground(in: Capsule())
        .padding(12) // room for the glass shadow inside the panel
        .fixedSize()
    }

    @ViewBuilder
    private var status: some View {
        if let message = model.message {
            Label(message, systemImage: "exclamationmark.circle")
                .lineLimit(1)
                .foregroundStyle(.secondary)
        } else if model.phase == .preparing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(KokoroSpeaker.isSelected ? "Loading voice…" : "Reading text…")
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.phase == .paused ? "Paused" : "Reading")
                    .font(.callout.weight(.medium))
                Text(model.voiceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
        }
    }

    private var speedMenu: some View {
        Menu {
            ForEach(Settings.speeds, id: \.self) { s in
                Button {
                    model.setSpeed(s)
                } label: {
                    if abs(model.settings.speed - s) < 0.01 {
                        Label(String(format: "%g×", s), systemImage: "checkmark")
                    } else {
                        Text(String(format: "%g×", s))
                    }
                }
            }
        } label: {
            Text(String(format: "%g×", model.settings.speed))
                .monospacedDigit()
                .font(.callout.weight(.medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Speed")
    }

    private var progressLine: some View {
        GeometryReader { geo in
            Capsule()
                .fill(.tint)
                .frame(width: max(0, geo.size.width - 40) * model.progress, height: 2)
                .offset(x: 20)
                .animation(.linear(duration: 0.2), value: model.progress)
        }
        .frame(height: 2)
        .padding(.bottom, 3)
        .opacity(model.phase == .preparing ? 0 : 1)
    }
}
