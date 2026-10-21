import SwiftUI

/// The Saved page: things to paste by voice, like an email address or an API key.
struct SavedTextSettings: View {
    @Environment(AppModel.self) private var model
    @Bindable var store = SavedText.shared
    /// Secrets shown in plain text for now, by their eye button.
    @State private var revealed: Set<UUID> = []
    /// A new item starts with its name to type.
    @FocusState private var focusedName: UUID?

    var body: some View {
        @Bindable var settings = model.settings

        Form {
            Section {
                if store.items.isEmpty {
                    Text("Nothing saved yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach($store.items) { $item in
                    row($item)
                }
                HStack {
                    Button("Add text", systemImage: "plus") { add(secret: false) }
                    Button("Add key or password", systemImage: "key") { add(secret: true) }
                }
                .buttonStyle(.borderless)
            } footer: {
                footnote("Dictate just the name, like \"email address\", or ask: \"paste my ElevenLabs key\". YapYap pastes it where you're typing, after a moment to press Esc. Saved in your Mac's keychain, on this Mac only. Keys and passwords stay hidden here, are never kept in your history, and clipboard apps are told not to keep them.")
            }

            Section {
                Toggle("Ask for Touch ID before pasting keys and passwords", isOn: $settings.requireTouchIDForSecrets)
            } footer: {
                footnote("The microphone only listens after you press the dictation shortcut, so this is for Macs other people use too.")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ item: Binding<SavedItem>) -> some View {
        let secret = item.wrappedValue.secret
        let hidden = secret && !revealed.contains(item.wrappedValue.id)
        return HStack(spacing: 8) {
            // Saved but nothing to say: it can't be pasted until it has a name.
            let unnamed = item.wrappedValue.name.trimmingCharacters(in: .whitespaces).isEmpty && !item.wrappedValue.value.isEmpty
            Image(systemName: unnamed ? "exclamationmark.triangle.fill" : secret ? "key" : "text.quote")
                .foregroundStyle(unnamed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .frame(width: 16)
                .help(unnamed ? "Give it a name to say" : secret ? "Key or password" : "Text")
            // Plain prompts: an example here looked like a name already filled in.
            TextField("Name", text: item.name, prompt: Text("Name you'll say"))
                .labelsHidden()
                .frame(width: 150)
                .focused($focusedName, equals: item.wrappedValue.id)
            Group {
                if hidden {
                    SecureField("Value", text: item.value, prompt: Text("Key or password"))
                } else {
                    TextField("Value", text: item.value, prompt: Text(secret ? "Key or password" : "Text to paste"))
                }
            }
            .labelsHidden()
            if secret {
                Button(hidden ? "Show" : "Hide", systemImage: hidden ? "eye" : "eye.slash") {
                    if hidden { revealed.insert(item.wrappedValue.id) } else { revealed.remove(item.wrappedValue.id) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
            Button("Remove", systemImage: "minus.circle") {
                let id = item.wrappedValue.id
                store.items.removeAll { $0.id == id }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Remove")
        }
    }

    private func add(secret: Bool) {
        let item = SavedItem(name: "", value: "", secret: secret)
        store.items.append(item)
        focusedName = item.id
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
