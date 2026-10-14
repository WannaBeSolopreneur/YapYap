import SwiftUI

/// Controls used on more than one screen.

/// ⏮ ⏯ ⏭ ⏹, for the floating reading bar.
struct TransportButtons: View {
    @Environment(AppModel.self) private var model
    var size: ControlSize = .regular
    var showsStop = true

    var body: some View {
        let ready = model.phase == .reading || model.phase == .paused
        HStack(spacing: 2) {
            button("Previous Sentence", "backward.fill") { model.skip(by: -1) }
                .disabled(!ready)
            button(model.phase == .paused ? "Resume" : "Pause", model.phase == .paused ? "play.fill" : "pause.fill") { model.togglePause() }
                .disabled(!ready)
                .font(size == .large ? .title2 : .body)
            button("Next Sentence", "forward.fill") { model.skip(by: 1) }
                .disabled(!ready)
            if showsStop {
                button("Stop", "stop.fill") { model.stop() }
            }
        }
        .controlSize(size)
    }

    private func button(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: size == .large ? 34 : 24, height: size == .large ? 34 : 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// Voice picker: Kokoro natural voices first, then the system voices.
struct VoiceMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            if model.kokoroInstalled {
                Section("Natural (Kokoro)") {
                    ForEach(KokoroSpeaker.voiceNames(), id: \.self) { name in
                        voiceButton(KokoroSpeaker.shortName(for: name), detail: KokoroSpeaker.detail(for: name), id: KokoroSpeaker.id(for: name))
                    }
                }
            }
            Section("System") {
                ForEach(Speaker.voices(), id: \.identifier) { v in
                    voiceButton(v.name, detail: Speaker.qualityName(for: v), id: v.identifier)
                }
            }
            if !model.kokoroInstalled {
                Divider()
                Button("Get Natural Voices…") { model.download.start() }
            }
        } label: {
            Text(model.voiceName)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func voiceButton(_ title: String, detail: String, id: String) -> some View {
        Button {
            model.setVoice(id)
        } label: {
            if id == model.currentVoiceID {
                Label("\(title)  \(detail)", systemImage: "checkmark")
            } else {
                Text("\(title)  \(detail)")
            }
        }
    }
}

/// Kokoro status with download, progress, cancel and retry.
struct KokoroDownloadRow: View {
    @Environment(AppModel.self) private var model
    var title = "Natural voices (Kokoro)"
    var allowsRemove = false

    var body: some View {
        let download = model.download
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                switch download.state {
                case .downloading:
                    ProgressView(value: download.fraction)
                    Text("\(Int(download.fraction * 100))% of 340 MB")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                case let .failed(error):
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                case .idle:
                    Text(model.kokoroInstalled ? "Installed · \(KokoroSpeaker.voiceNames().count) voices" : "Optional · 340 MB download")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            switch download.state {
            case .downloading:
                Button("Cancel") { download.cancel() }
            case .failed:
                Button("Retry") { download.start() }
            case .idle:
                if model.kokoroInstalled && allowsRemove {
                    Button("Remove…") { model.removeKokoro() }
                } else if model.kokoroInstalled {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        .accessibilityLabel("Installed")
                } else {
                    Button("Download") { download.start() }
                }
            }
        }
    }
}
