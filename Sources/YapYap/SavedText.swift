import AppKit
import LocalAuthentication
import Security
import YapYapCore

/// Something saved to type by voice: say its name ("email address", "paste my ElevenLabs key")
/// as a whole dictation and it's pasted.
struct SavedItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var value: String
    /// Keys and passwords: hidden in Settings, never kept in history or shown in the Copy card,
    /// and marked so clipboard managers skip them.
    var secret = false
}

/// The saved items, kept in the macOS Keychain on this Mac (not synced, readable only while the
/// Mac is unlocked).
@Observable
final class SavedText {
    static let shared = SavedText()

    var items: [SavedItem] {
        didSet { storage.save(items) }
    }

    @ObservationIgnored private let storage: SavedTextStorage

    /// `shared` is made the first time it's used, so the Keychain is only read then.
    init(storage: SavedTextStorage = KeychainStorage()) {
        self.storage = storage
        items = storage.load()
    }

    /// The saved item with this name, ignoring case and spaces at the ends.
    func named(_ name: String) -> SavedItem? {
        let name = name.trimmingCharacters(in: .whitespaces)
        return items.first { $0.name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Adds an item, or replaces the value of the one with the same name.
    func save(name: String, value: String, secret: Bool) {
        let name = name.trimmingCharacters(in: .whitespaces)
        if let existing = named(name), let index = items.firstIndex(where: { $0.id == existing.id }) {
            items[index].value = value
            items[index].secret = secret
        } else {
            items.append(SavedItem(name: name, value: value, secret: secret))
        }
    }

    /// The item a whole dictation asks for, if any.
    func match(_ said: String) -> SavedItem? {
        let items = self.items.filter { !$0.name.isEmpty && !$0.value.isEmpty }
        return SavedTextCommand.match(said, names: items.map(\.name)).map { items[$0] }
    }
}

protocol SavedTextStorage {
    func load() -> [SavedItem]
    func save(_ items: [SavedItem])
}

/// Saved items in memory only: tests and screenshots.
struct MemoryStorage: SavedTextStorage {
    var items: [SavedItem] = []
    func load() -> [SavedItem] { items }
    func save(_ items: [SavedItem]) {}
}

/// One Keychain item holding the list as JSON.
struct KeychainStorage: SavedTextStorage {
    private let query: [CFString: Any]

    /// Another `service` keeps `--keychain-test` away from the real list.
    init(service: String = "cc.yapyap.app.saved-text") {
        query = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "items"]
    }

    func delete() { SecItemDelete(query as CFDictionary) }

    func load() -> [SavedItem] {
        var result: CFTypeRef?
        var search = query
        search[kSecReturnData] = true
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return [] }
        return (try? JSONDecoder().decode([SavedItem].self, from: data)) ?? []
    }

    func save(_ items: [SavedItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        let update: [CFString: Any] = [kSecValueData: data]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData] = data
            add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            add[kSecAttrLabel] = "YapYap saved text"
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

/// Touch ID (or the Mac's password) before pasting a secret, when Settings asks for it.
enum OwnerCheck {
    static func confirm(_ reason: String, _ done: @escaping (Bool) -> Void) {
        LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async { done(ok) }
        }
    }
}
