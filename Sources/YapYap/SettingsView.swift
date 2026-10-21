import SwiftUI

/// The forms behind the main window's Reading, Dictation and Settings pages. Rarely changed
/// options fold away under "More options" so the common ones stay easy to find.

// MARK: Reading

struct ReadingSettings: View {
    @Environment(AppModel.self) private var model
    @State private var showsMore = false

    var body: some View {
        @Bindable var settings = model.settings

        Form {
            Section {
                LabeledContent("Voice") {
                    HStack {
                        VoiceMenu()
                        Button("Preview", systemImage: "play.circle") { model.previewVoice() }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Hear this voice")
                    }
                }
                LabeledContent("Speed") {
                    HStack {
                        Slider(value: Binding(get: { settings.speed }, set: { model.setSpeed($0) }), in: 0.5...2.5, step: 0.25) {
                            Text("Speed")
                        } minimumValueLabel: {
                            Image(systemName: "tortoise")
                        } maximumValueLabel: {
                            Image(systemName: "hare")
                        }
                        .labelsHidden()
                        Text(String(format: "%g×", settings.speed))
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                    .frame(width: 260)
                }
                KokoroDownloadRow(title: "Natural voices", allowsRemove: true)
            } footer: {
                Text("Natural voices (Kokoro) sound the most human and run on your Mac. English only. Speed also changes with ⌥⌘= and ⌥⌘−.")
                    .settingsFootnote()
            }

            Section {
                HighlightPreview()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                LabeledContent("Highlight") {
                    HStack(spacing: 10) {
                        ForEach(HighlightStyle.allCases, id: \.self) { style in
                            Swatch(style: style, selected: settings.style == style) { settings.style = style }
                        }
                    }
                }
            }

            Section {
                DisclosureGroup("More options", isExpanded: $showsMore) {
                    LabeledContent("Highlight opacity") {
                        Slider(value: $settings.opacity, in: 0.2...0.8).frame(width: 200)
                    }
                    .disabled(settings.style == .underline)
                    Toggle("Reading ruler (dim the other lines)", isOn: $settings.ruler)
                    Toggle("Skip web and email addresses", isOn: Binding(
                        get: { settings.skipLinks },
                        set: { settings.skipLinks = $0; model.controller.restartIfReading() }))
                    Button("Get More System Voices…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent")!)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: settings.style) { model.controller.refreshHighlight() }
        .onChange(of: settings.opacity) { model.controller.refreshHighlight() }
        .onChange(of: settings.ruler) { model.controller.refreshHighlight() }
    }
}

private struct Swatch: View {
    let style: HighlightStyle
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if style == .underline {
                    Circle().fill(.background)
                    Capsule().fill(style.swiftUIColor).frame(width: 12, height: 3).offset(y: 4)
                } else {
                    Circle().fill(style.swiftUIColor)
                }
                Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 0.5)
            }
            .frame(width: 22, height: 22)
            .padding(3)
            .overlay(Circle().strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .help(style.title)
        .accessibilityLabel(style.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Three lines of sample text with one word highlighted the way it will be on screen.
private struct HighlightPreview: View {
    @Environment(AppModel.self) private var model
    private let lines = [["The", "quick", "brown", "fox"], ["jumps", "over", "the", "lazy", "dog,"], ["then", "naps", "in", "the", "sun."]]

    var body: some View {
        let settings = model.settings
        VStack(alignment: .leading, spacing: 6) {
            ForEach(lines.indices, id: \.self) { li in
                HStack(spacing: 5) {
                    ForEach(lines[li].indices, id: \.self) { wi in
                        word(lines[li][wi], highlighted: li == 1 && wi == 3, settings: settings)
                    }
                }
                .opacity(settings.ruler && li != 1 ? 0.35 : 1)
            }
        }
        .font(.system(size: 17, design: .serif))
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
        .accessibilityLabel("Preview of the highlight")
    }

    @ViewBuilder
    private func word(_ text: String, highlighted: Bool, settings: Settings) -> some View {
        if !highlighted {
            Text(text)
        } else if settings.style == .underline {
            Text(text).overlay(alignment: .bottom) {
                Capsule().fill(settings.style.swiftUIColor).frame(height: 3).offset(y: 3)
            }
        } else {
            Text(text)
                .padding(.horizontal, 3)
                .background(settings.style.swiftUIColor.opacity(settings.opacity), in: RoundedRectangle(cornerRadius: 4))
                .padding(.horizontal, -3)
        }
    }
}

// MARK: Dictation

struct DictationSettings: View {
    @Environment(AppModel.self) private var model
    /// Checked when the tab appears; Apple Intelligence can be turned on while YapYap runs.
    @State private var aiStatus = AppleIntelligence.status
    /// The files are checked on disk, which SwiftUI doesn't watch.
    @State private var parakeetRemoved = false

    var body: some View {
        @Bindable var settings = model.settings

        Form {
            Section {
                LabeledContent("Dictate") {
                    KeyCaps(keys: ["hold"] + settings.dictationShortcut.displayKeys)
                }
                LabeledContent("Hands-free") {
                    KeyCaps(keys: ["tap"] + settings.dictationShortcut.displayKeys)
                }
                Toggle("Remove filler words", isOn: $settings.removeFillers)
                Toggle("Spell names from the screen", isOn: $settings.useScreenContext)
            } footer: {
                footnote("Tap the shortcut to keep listening without holding it; tap it again or click ✓ to type, or press Esc to cancel. Takes out um, uh, er and hmm before typing. Spelling names from the screen reads the window you're typing in, on your Mac, so names like Priya come out right; nothing is saved. Change the shortcut under General.")
            }

            Section {
                Picker("Speech model", selection: $settings.dictationEngine) {
                    Text("Parakeet").tag(DictationEngine.parakeet)
                    Text("Apple").tag(DictationEngine.apple)
                }
                .onChange(of: settings.dictationEngine) { _, engine in
                    // Have it ready before the next dictation.
                    if engine == .parakeet { ParakeetEngine.prepare() }
                }
                if settings.dictationEngine == .apple, !parakeetRemoved, ParakeetEngine.isDownloaded {
                    Button("Remove Parakeet download") {
                        ParakeetEngine.remove()
                        parakeetRemoved = true
                    }
                }
            } footer: {
                footnote(settings.dictationEngine == .apple
                    ? "Apple's dictation model, built into macOS."
                    : !ParakeetEngine.speaksMacLanguage
                    ? "Parakeet understands 25 European languages, not your Mac's language, so Apple's model is used."
                    : "NVIDIA's Parakeet, more accurate than Apple's model, running on your Mac. It downloads once (about 700 MB) in the background; until then Apple's model is used. Uses about 450 MB of memory while YapYap is open.")
            }

            Section {
                Toggle("Tidy up with Apple Intelligence", isOn: $settings.polishDictation)
                    .disabled(!settings.removeFillers || aiStatus != nil)
            } footer: {
                if let aiStatus {
                    footnote(aiStatus)
                } else {
                    footnote("Also removes \"like\" and \"you know\" when they're filler, stutters, and corrections: \"Tuesday, no, Wednesday\" becomes \"Wednesday\". Runs on your Mac and usually adds less than a second. If the result doesn't match what you said, the plain version is typed instead.")
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { aiStatus = AppleIntelligence.status }
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
    }
}

/// Click, then press a key combination. Esc cancels; the reset button restores the default.
struct ShortcutRecorder: View {
    let combo: KeyCombo
    let defaultCombo: KeyCombo
    private var isDefault: Bool { combo == defaultCombo }
    /// Returns an error message when the combination can't be used.
    let onRecord: (KeyCombo) -> String?
    let onReset: () -> Void
    let onRecordingChange: (Bool) -> Void

    @State private var recording = false
    @State private var error: String?
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    recording ? stop() : start()
                } label: {
                    Group {
                        if recording {
                            Text("Type shortcut…")
                                .foregroundStyle(.secondary)
                        } else {
                            KeyCaps(keys: combo.displayKeys)
                        }
                    }
                    .frame(minHeight: 22)
                    .padding(.horizontal, 4)
                    .padding(.horizontal, 6)
                    .background(recording ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(recording ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: recording ? 1.5 : 0.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(recording ? "Press a key combination, or Esc to cancel" : "Click to change")
                .accessibilityLabel(recording ? "Recording shortcut" : "Shortcut \(combo.displayKeys.joined(separator: " ")). Click to change")

                if !isDefault {
                    Button {
                        stop()
                        error = nil
                        onReset()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Reset to \(defaultCombo.displayKeys.joined())")
                    .accessibilityLabel("Reset to default")
                }
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        error = nil
        recording = true
        onRecordingChange(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc
                stop()
                return nil
            }
            guard let combo = KeyCombo(event: event) else {
                error = "Include ⌘, ⌥ or ⌃, or use an F-key"
                return nil
            }
            stop()
            error = onRecord(combo)
            return nil
        }
    }

    private func stop() {
        guard recording else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        onRecordingChange(false)
    }
}

// MARK: General

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var showsOtherShortcuts = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Read aloud") {
                    ShortcutRecorder(
                        combo: model.settings.regionShortcut,
                        defaultCombo: .defaultRegion,
                        onRecord: { model.setRegionShortcut($0) },
                        onReset: { _ = model.setRegionShortcut(.defaultRegion) },
                        onRecordingChange: { model.suspendHotKeys($0) }
                    )
                }
                LabeledContent("Dictate (hold)") {
                    ShortcutRecorder(
                        combo: model.settings.dictationShortcut,
                        defaultCombo: .defaultDictation,
                        onRecord: { model.setDictationShortcut($0) },
                        onReset: { _ = model.setDictationShortcut(.defaultDictation) },
                        onRecordingChange: { model.suspendHotKeys($0) }
                    )
                }
                DisclosureGroup("Other shortcuts", isExpanded: $showsOtherShortcuts) {
                    ForEach(Shortcuts.fixed, id: \.title) { shortcut in
                        LabeledContent(shortcut.title) { KeyCaps(keys: shortcut.keys) }
                    }
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("They work in any app. Click a shortcut to change it.")
                    .settingsFootnote()
            }
            Section {
                Toggle("Open YapYap at login", isOn: Binding(get: { model.launchesAtLogin }, set: { model.setLaunchesAtLogin($0) }))
            }
            Section {
                PermissionRow(title: "Microphone", granted: model.micAllowed) { DictationAccess.requestMicrophone() }
                if DictationAccess.needsSpeech {
                    PermissionRow(title: "Speech Recognition", granted: model.speechAllowed) { DictationAccess.requestSpeech() }
                }
                PermissionRow(title: "Accessibility", granted: model.accessibilityAllowed) { DictationAccess.requestAccessibility() }
                if model.screenRecordingNeedsRestart {
                    LabeledContent("Screen Recording") {
                        Button("Restart YapYap") { Permission.relaunch() }
                    }
                } else {
                    PermissionRow(title: "Screen Recording", granted: model.hasPermission) { Permission.request() }
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Screen Recording is for reading. Microphone and Accessibility are for dictation.")
                    .settingsFootnote()
            }
            Section {
                Toggle("Keep history on this Mac", isOn: Binding(get: { model.settings.keepHistory }, set: { model.settings.keepHistory = $0 }))
                LabeledContent("Recent reads and dictations") {
                    Button("Clear History…") { confirmClear() }
                        .disabled(model.history.entries.isEmpty)
                }
            } header: {
                Text("History")
            } footer: {
                Text("Shown on Home so you can copy or replay them. Saved only on this Mac; totals are kept either way.")
                    .settingsFootnote()
            }
            if model.telemetry.isAvailable {
                Section {
                    Toggle("Share anonymous usage stats", isOn: Binding(get: { model.settings.shareUsageStats }, set: { model.setShareUsageStats($0) }))
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Counts and timings only, like how many words were read and how quickly the voice started. Never what you read or said, or which app it was in.")
                        .settingsFootnote()
                }
            }
            Section {
                LabeledContent("Welcome guide") {
                    Button("Show…") { WelcomeWindow.show() }
                }
                LabeledContent("Version") {
                    HStack(spacing: 10) {
                        Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                            .foregroundStyle(.secondary)
                        if Updates.shared.isAvailable {
                            Button("Check for Updates…") { Updates.shared.checkNow() }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.refreshPermission() }
    }

    private func confirmClear() {
        let alert = NSAlert()
        alert.messageText = "Clear your history?"
        alert.informativeText = "Recent reads and dictations are removed from this Mac. Your totals stay."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { model.history.clear() }
    }
}

/// A permission's status, with a way to go and allow it.
private struct PermissionRow: View {
    let title: String
    let granted: Bool
    let request: () -> Void

    var body: some View {
        LabeledContent(title) {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                HStack {
                    Label("Not allowed", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Open Settings", action: request)
                }
            }
        }
    }
}
