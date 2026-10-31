import AppKit
import AVFoundation
import Combine
import SwiftUI

/// First launch: sell first, ask second, then a first win. What YapYap does (a short demo
/// loop) → the three permissions on one page → try both shortcuts for real.
enum WelcomeWindow {
    private static var window: NSWindow?
    static let permissionsStep = 1

    static var allGranted: Bool { Capture.hasPermission && DictationAccess.allGranted }

    /// Where to open. Mid-setup (say, after the Screen Recording restart) that's back on the
    /// permissions page, not the start.
    static var firstNeededStep: Int {
        let anyGranted = Capture.hasPermission || DictationAccess.microphone || DictationAccess.accessibility
        if !Settings.shared.hasOnboarded { return anyGranted ? permissionsStep : 0 }
        return allGranted ? 0 : permissionsStep
    }

    static func show(at step: Int? = nil) {
        let step = step ?? firstNeededStep
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 500),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.title = "Welcome to YapYap"
            w.center()
            window = w
        }
        window?.contentViewController = NSHostingController(rootView: WelcomeView(initialStep: step).environment(AppModel.shared))
        window?.setContentSize(NSSize(width: 580, height: 500))
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    static func close() {
        window?.close()
    }

    static var nsWindow: NSWindow? { window }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var step: Int
    private let steps = 3

    init(initialStep: Int) {
        _step = State(initialValue: initialStep)
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: IntroStep()
                case WelcomeWindow.permissionsStep: PermissionsStep(onGranted: { withAnimation { step = WelcomeWindow.permissionsStep + 1 } })
                default: TryItStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 44)
            .padding(.top, 32)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            .id(step)

            Divider()

            HStack {
                StepDots(count: steps, current: step)
                Spacer()
                if step > 0 {
                    Button("Back") { withAnimation { step -= 1 } }
                        .keyboardShortcut(.cancelAction)
                }
                if step < steps - 1 {
                    Button(step == 0 ? "Get Started" : "Continue") { withAnimation { step += 1 } }
                        .keyboardShortcut(.defaultAction)
                        .glassButtonStyle(prominent: true)
                        // YapYap can't work without these, so there's no skipping them.
                        .disabled(step == WelcomeWindow.permissionsStep && !model.allPermissionsGranted)
                } else {
                    Button("Start Using YapYap") {
                        model.settings.hasOnboarded = true
                        model.stop()
                        WelcomeWindow.close()
                        MainWindow.show()
                    }
                    .keyboardShortcut(.defaultAction)
                    .glassButtonStyle(prominent: true)
                }
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 580, height: 500)
    }
}

private struct StepDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: i == current ? 18 : 7, height: 7)
            }
        }
        .animation(.snappy, value: current)
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

private struct StepHeader: View {
    /// An SF Symbol, or nil for the app icon.
    var symbol: String?
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.tint)
                    .frame(height: 56)
            } else {
                Logo.appIcon
                    .resizable()
                    .frame(width: 88, height: 88)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.title.weight(.semibold))
            Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct IntroStep: View {
    var body: some View {
        VStack(spacing: 22) {
            DemoLoop()
                .aspectRatio(960.0 / 520.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .accessibilityLabel("A web page being read aloud, each word highlighted as it's spoken")
            VStack(spacing: 8) {
                Text("ON-DEVICE AI PRODUCTIVITY TOOLS")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.navy)
                    .padding(.bottom, 4)
                Text("Listen to anything.\nDictate anywhere.")
                    .font(Theme.display(30))
                    .multilineTextAlignment(.center)
                Text("YapYap reads any text on your screen aloud and types what you say, in every app. Everything happens on your Mac.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The website's demo, cut to six silent seconds and looped. Only alive while it's on screen.
private struct DemoLoop: NSViewRepresentable {
    final class PlayerView: NSView {
        let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?

        init(url: URL) {
            super.init(frame: .zero)
            wantsLayer = true
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspectFill
            self.layer = layer
            player.isMuted = true
            // Doesn't stop the user's music or take over media keys.
            player.preventsDisplaySleepDuringVideoPlayback = false
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            player.play()
        }

        required init?(coder: NSCoder) { fatalError() }

        func stop() {
            player.pause()
            looper?.disableLooping()
            looper = nil
            player.removeAllItems()
        }
    }

    func makeNSView(context: Context) -> NSView {
        guard let url = Bundle.main.url(forResource: "welcome-demo", withExtension: "mp4") else {
            // Running outside the app bundle: show the icon instead.
            let image = NSImageView(image: NSApp.applicationIconImage)
            image.imageScaling = .scaleProportionallyUpOrDown
            return image
        }
        return PlayerView(url: url)
    }

    func updateNSView(_ view: NSView, context: Context) {}

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        (view as? PlayerView)?.stop()
    }
}

private struct PermissionsStep: View {
    @Environment(AppModel.self) private var model
    let onGranted: () -> Void
    @State private var askedScreen = false
    @State private var askedAccessibility = false
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 22) {
            StepHeader(symbol: model.allPermissionsGranted ? "checkmark.shield" : "lock.shield",
                       title: "Three permissions",
                       subtitle: "Each one switches on part of YapYap. Nothing you read or say leaves your Mac.")

            VStack(spacing: 0) {
                AccessRow(symbol: "mic.fill", title: "Microphone",
                          detail: "Hears you only while you dictate: hold \(model.settings.dictationShortcut.displayKeys.joined()), or tap it to keep listening.") {
                    if model.micAllowed { Allowed() } else { Button("Allow") { DictationAccess.requestMicrophone() } }
                }
                if DictationAccess.needsSpeech {
                    Divider()
                    AccessRow(symbol: "waveform", title: "Speech Recognition", detail: "Turns what you say into text.") {
                        if model.speechAllowed { Allowed() } else { Button("Allow") { DictationAccess.requestSpeech() } }
                    }
                }
                Divider()
                AccessRow(symbol: "accessibility", title: "Accessibility", detail: "Pastes what you dictate into other apps.") {
                    if model.accessibilityAllowed {
                        Allowed()
                    } else {
                        Button("Open Settings") {
                            askedAccessibility = true
                            DictationAccess.requestAccessibility()
                        }
                    }
                }
                Divider()
                AccessRow(symbol: "rectangle.dashed.badge.record", title: "Screen Recording",
                          detail: model.screenRecordingNeedsRestart ? "Turned on. YapYap restarts to use it and comes back here." : "Sees the words in the window you ask it to read.") {
                    if model.hasPermission {
                        Allowed()
                    } else if model.screenRecordingNeedsRestart {
                        Button("Restart YapYap") { Permission.relaunch() }
                            .glassButtonStyle(prominent: true)
                    } else {
                        Button("Open Settings") {
                            askedScreen = true
                            Permission.request()
                        }
                    }
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            hint
            Spacer(minLength: 0)
        }
        .onReceive(poll) { _ in
            let had = model.allPermissionsGranted
            model.refreshPermission()
            if !had && model.allPermissionsGranted { onGranted() }
        }
    }

    @ViewBuilder
    private var hint: some View {
        Group {
            if model.allPermissionsGranted {
                Label("All set", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
            } else if askedScreen && !model.screenRecordingNeedsRestart && !model.hasPermission {
                Text("Turn on **YapYap** under Screen Recording. If macOS offers to **Quit & Reopen**, go ahead: you'll land back here.")
            } else if askedAccessibility && !model.accessibilityAllowed {
                Text("Turn on **YapYap** under Accessibility, then come back here.")
            } else {
                Text("Each one ticks green as soon as it's on.")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Allowed: View {
    var body: some View {
        Label("Allowed", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
    }
}

/// One permission: what it's for, and its button or status.
private struct AccessRow<Trailing: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct TryItStep: View {
    @Environment(AppModel.self) private var model
    @State private var dictated = ""
    @FocusState private var boxFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Try it").font(.title.weight(.semibold))
                Text("Two shortcuts. That's all there is to it.").foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    BigKeys(keys: model.settings.regionShortcut.displayKeys, size: 26)
                    Text("Press, then drag over this:").font(.callout.weight(.medium))
                }
                Text("Reading along makes it easier to stay focused. Each word lights up as it's spoken, so your eyes never lose their place.")
                    .font(.system(size: 15, design: .serif))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                HStack(spacing: 6) {
                    Text("Voice").foregroundStyle(.secondary)
                    VoiceMenu()
                    Spacer()
                    if model.download.state == .downloading {
                        ProgressView(value: model.download.fraction).frame(width: 90)
                        Text("Getting natural voices…").foregroundStyle(.secondary)
                    } else if !model.kokoroInstalled {
                        Button(model.download.state == .idle ? "Get natural voices (340 MB)" : "Retry natural voices") {
                            model.settings.autoDownloadVoices = true
                            model.download.start()
                        }
                        .buttonStyle(.link)
                    }
                }
                .font(.caption)
            }
            .card(padding: 14)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    BigKeys(keys: model.settings.dictationShortcut.displayKeys, size: 26)
                    Text("Click the box, hold, say something, let go:").font(.callout.weight(.medium))
                }
                TextField("Your words appear here", text: $dictated, axis: .vertical)
                    .lineLimit(2...3)
                    .textFieldStyle(.roundedBorder)
                    .focused($boxFocused)
                if !dictated.isEmpty && model.settings.removeFillers {
                    Label("Ums and stumbles were tidied up for you.", systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .card(padding: 14)

            Spacer(minLength: 0)
        }
    }
}
