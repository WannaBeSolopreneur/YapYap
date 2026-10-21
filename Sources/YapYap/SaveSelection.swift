import AppKit
import SwiftUI
import YapYapCore

/// "Save to YapYap" in the right-click menu (Services) of any app: the selected text goes to the
/// Saved list, under a name you'll say. Declared as NSServices in the Info.plist (build-app.sh).
final class SaveSelectionService: NSObject {
    static let shared = SaveSelectionService()

    @objc func saveToYapYap(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            error.pointee = "Select some text to save." as NSString
            return
        }
        SaveSelectionWindow.show(text)
    }
}

/// Asks for the name, with a guess filled in: "Email address", "Anthropic key".
enum SaveSelectionWindow {
    private static var window: NSWindow?

    static func show(_ text: String) {
        window?.close()
        let guess = SavedTextGuess.guess(text)
        let view = SaveSelectionView(text: text, name: guess.name, secret: guess.secret) { saved in
            window?.close()
            window = nil
            if let saved { Toast.show("Saved. Say \"\(saved)\" to paste it.", for: 3) }
        }
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Save to YapYap"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentView = NSHostingView(rootView: view)
        window.setContentSize(window.contentView!.fittingSize)
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

struct SaveSelectionView: View {
    let text: String
    @State var name: String
    @State var secret: Bool
    /// The name saved under, or nil when cancelled.
    let done: (String?) -> Void
    @FocusState private var naming: Bool

    var body: some View {
        let replacing = SavedText.shared.named(name) != nil
        VStack(alignment: .leading, spacing: 12) {
            Text(secret ? masked : text)
                .font(.callout.monospaced())
                .lineLimit(3)
                .truncationMode(.middle)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            TextField("Name you'll say", text: $name, prompt: Text("Name you'll say, like \"work email\""))
                .textFieldStyle(.roundedBorder)
                .focused($naming)
                .onSubmit(save)
            Toggle("Key or password (kept hidden)", isOn: $secret)
            Text(replacing ? "Replaces what's saved as \"\(name.trimmingCharacters(in: .whitespaces))\"." : "Dictate the name to paste it anywhere.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(replacing ? "Replace" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear { naming = true }
    }

    /// Enough to recognise it, not enough to use it.
    private var masked: String {
        String(text.prefix(6)) + String(repeating: "•", count: min(max(text.count - 6, 4), 24))
    }

    private func save() {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        SavedText.shared.save(name: name, value: text, secret: secret)
        done(name)
    }
}
