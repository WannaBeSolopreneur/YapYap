import SwiftUI

/// Home: a greeting, the two shortcuts shown the way the website shows them, and what you've
/// done with them (recent reads and dictations, and totals).
struct HomePage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .firstTextBaseline) {
                    Text(greeting)
                        .font(.system(size: 26, weight: .semibold))
                        .tracking(-0.4)
                    Spacer()
                    StatusPill()
                }

                HStack(alignment: .top, spacing: 16) {
                    ReadPanel()
                    DictatePanel()
                }

                HStack(alignment: .top, spacing: 20) {
                    RecentList()
                        .frame(maxWidth: .infinity)
                    TotalsCard()
                        .frame(width: 230)
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 40)
            .padding(.bottom, 30)
        }
        .scrollContentBackground(.hidden)
    }

    private var greeting: String {
        let first = model.fullUserName.split(separator: " ").first.map(String.init) ?? ""
        let welcome = model.settings.hasOnboarded ? "Welcome back" : "Welcome"
        return first.isEmpty ? welcome : "\(welcome), \(first)"
    }
}

/// Ready, reading, listening or "finish setup", with the control that matters right then.
private struct StatusPill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
            content
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Theme.hairline.opacity(0.6), in: Capsule())
    }

    private var color: Color {
        if !model.allPermissionsGranted { return Theme.attention }
        if model.dictationPhase != .idle { return .red }
        if model.isReading { return .accentColor }
        return Theme.ready
    }

    @ViewBuilder
    private var content: some View {
        if !model.allPermissionsGranted {
            Button("Finish setup") { WelcomeWindow.show(at: WelcomeWindow.permissionsStep) }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.attention)
        } else if model.dictationPhase == .polishing {
            Text("Tidying up…")
        } else if model.dictationPhase != .idle {
            Text("Listening…")
        } else if model.phase == .preparing {
            Text("Getting ready…")
        } else if model.isReading {
            Text(model.phase == .paused ? "Paused" : "Reading \(Int(model.progress * 100))%").monospacedDigit()
            Button(model.phase == .paused ? "Resume" : "Pause", systemImage: model.phase == .paused ? "play.fill" : "pause.fill") { model.togglePause() }
                .labelStyle(.iconOnly).buttonStyle(.plain)
            Button("Stop", systemImage: "stop.fill") { model.stop() }
                .labelStyle(.iconOnly).buttonStyle(.plain)
        } else {
            Text("Ready")
            Text("· \(model.voiceName), \(String(format: "%g×", model.settings.speed))").foregroundStyle(.secondary)
        }
    }
}

/// A dark panel like the website's: a headline, a small drawn window showing the shortcut in
/// action, and its three steps.
private struct Panel<Scene: View>: View {
    let title: String
    let steps: [String]
    @ViewBuilder var scene: Scene

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 21, weight: .bold))
                .tracking(-0.3)
            scene
                .frame(maxWidth: .infinity)
                .frame(height: 112)
                .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topLeading) { TrafficLights().padding(9) }
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.1)))
            StepRow(steps: steps)
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}

private struct TrafficLights: View {
    var body: some View {
        HStack(spacing: 5) {
            ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.78, blue: 0.25)], id: \.self) {
                Circle().fill($0.opacity(0.85)).frame(width: 7, height: 7)
            }
        }
    }
}

/// "Press ⌥A. Listen." A line of an article with one word lit up. Click to try it.
private struct ReadPanel: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        Button {
            model.controller.lastApp?.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { model.readRegion() }
        } label: {
            Panel(title: "Press \(model.settings.regionShortcut.displayKeys.joined()). Listen.",
                  steps: ["Press", "Drag", "Listen"]) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("The quiet return of the library")
                        .font(.system(size: 13, weight: .semibold, design: .serif))
                        .foregroundStyle(.white.opacity(0.55))
                    (Text("Visits are up for the ") + Text(Self.lit) + Text(" year in a row. People come for"))
                        .font(.system(size: 12, design: .serif))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    Text("the free rooms and the fast internet.")
                        .font(.system(size: 12, design: .serif))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 22)
            }
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(hovering ? 0.7 : 0), lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Click to try it: drag over any text on screen")
    }

    private static let lit: AttributedString = {
        // Mid-line, so a narrow window cuts the end of the line, never the lit word.
        var word = AttributedString("third")
        word.backgroundColor = Theme.highlight
        word.foregroundColor = .black
        return word
    }()
}

/// "Hold ⌥S. Talk." A reply being written, with the dictation capsule at the bottom.
private struct DictatePanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Panel(title: "Hold \(model.settings.dictationShortcut.displayKeys.joined()). Talk.",
              steps: ["Hold", "Talk", "Let go"]) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text("To:").foregroundStyle(.white.opacity(0.45))
                    Text("Priya Shah")
                        .foregroundStyle(Color(red: 0.4, green: 0.65, blue: 1))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color(red: 0.4, green: 0.65, blue: 1).opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                    Spacer()
                }
                .font(.system(size: 11))
                .padding(.horizontal, 14)
                .padding(.top, 24)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.red)
                        .frame(width: 18, height: 18)
                        .background(.red.opacity(0.18), in: Circle())
                    Text("…I'll bring my laptop and the numbers")
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    KeyCaps(keys: model.settings.dictationShortcut.displayKeys)
                        .scaleEffect(0.85)
                }
                .padding(.leading, 6)
                .padding(.trailing, 4)
                .frame(height: 28)
                .background(Color(white: 0.2), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
        }
        .help("Hold \(model.settings.dictationShortcut.displayKeys.joined()) in any app where you can type")
    }
}

/// Totals in big serif numbers, like a reading log.
private struct TotalsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let totals = model.history.totals
        VStack(alignment: .leading, spacing: 14) {
            stat(Self.compact(totals.wordsRead), "words read aloud")
            stat(Self.compact(totals.wordsDictated), "words dictated")
            stat(Self.compact(Int((totals.secondsListened / 60).rounded())), "minutes listening")
        }
        .card(padding: 20)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value).font(Theme.display(28))
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
    }

    /// 950 → "950", 55 700 → "55.7K".
    static func compact(_ n: Int) -> String {
        switch n {
        case ..<1000: return "\(n)"
        case ..<1_000_000: return String(format: "%.1fK", Double(n) / 1000).replacingOccurrences(of: ".0K", with: "K")
        default: return String(format: "%.1fM", Double(n) / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
        }
    }
}

/// Recent reads and dictations, grouped by day, newest first.
private struct RecentList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let entries = model.history.entries
        if entries.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Nothing here yet").font(.headline)
                Text("What you read and dictate shows up here, so you can copy it or hear it again. It stays on this Mac.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .card(padding: 20)
        } else {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(Self.days(entries), id: \.day) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Self.title(for: group.day).uppercased())
                            .font(.caption.weight(.semibold))
                            .tracking(0.8)
                            .foregroundStyle(.secondary)
                        VStack(spacing: 0) {
                            ForEach(group.entries) { entry in
                                RecentRow(entry: entry)
                                if entry.id != group.entries.last?.id { Divider().padding(.leading, 96) }
                            }
                        }
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                    }
                }
            }
        }
    }

    private static func days(_ entries: [History.Entry]) -> [(day: Date, entries: [History.Entry])] {
        let calendar = Calendar.current
        var groups: [(day: Date, entries: [History.Entry])] = []
        for entry in entries.prefix(60) {
            let day = calendar.startOfDay(for: entry.date)
            if groups.last?.day == day { groups[groups.count - 1].entries.append(entry) } else { groups.append((day, [entry])) }
        }
        return groups
    }

    private static func title(for day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.month(.wide).day().year())
    }
}

private struct RecentRow: View {
    @Environment(AppModel.self) private var model
    let entry: History.Entry
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(entry.date.formatted(date: .omitted, time: .shortened).lowercased())
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 64, alignment: .leading)
            Image(systemName: entry.kind == .read ? "speaker.wave.2" : "mic")
                .font(.callout)
                .foregroundStyle(entry.kind == .read ? Theme.navy : .red.opacity(0.8))
                .frame(width: 16)
                .accessibilityLabel(entry.kind == .read ? "Read aloud" : "Dictated")
            Text(entry.text)
                .font(.callout)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        // Actions float over the text on hover, so the text gets the whole row the rest of the time.
        .overlay(alignment: .topTrailing) {
            if hovering {
                HStack(spacing: 12) {
                    Button(entry.kind == .read ? "Read again" : "Read aloud", systemImage: "play") { model.controller.preview(entry.text) }
                    Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") { copy() }
                    Button("Delete", systemImage: "trash") { model.history.remove(entry.id) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Theme.canvas, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.hairline))
                .padding(8)
            }
        }
        .contentShape(Rectangle())
        .background(hovering ? Color.primary.opacity(0.03) : .clear)
        .onHover { hovering = $0 }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}
