import AppKit
import Carbon

/// Global hotkeys via Carbon's RegisterEventHotKey: no Accessibility permission needed.
final class HotKey {
    private static var handlers: [UInt32: (pressed: () -> Void, released: (() -> Void)?)] = [:]
    private static var nextID: UInt32 = 1
    private static var installed = false

    private var ref: EventHotKeyRef?
    private let id: UInt32

    /// `onRelease`, when given, is called when the key comes back up (push-to-talk).
    init?(keyCode: Int, modifiers: Int, onRelease: (() -> Void)? = nil, handler: @escaping () -> Void) {
        HotKey.installHandler()
        id = HotKey.nextID
        HotKey.nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x5244_4C47), id: id) // 'RDLG'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr else { return nil }
        HotKey.handlers[id] = (handler, onRelease)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.handlers[id] = nil
    }

    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
            DispatchQueue.main.async {
                guard let handler = HotKey.handlers[id] else { return }
                if released { handler.released?() } else { handler.pressed() }
            }
            return noErr
        }, specs.count, &specs, nil, nil)
    }
}

enum Keys {
    static let optCmd = optionKey | cmdKey
    static let r = kVK_ANSI_R
    static let e = kVK_ANSI_E
    static let p = kVK_ANSI_P
    static let a = kVK_ANSI_A
    static let s = kVK_ANSI_S
    static let equal = kVK_ANSI_Equal
    static let minus = kVK_ANSI_Minus
    static let escape = kVK_Escape
}

/// A user-chosen global shortcut: a key plus Carbon modifier flags, with how to draw it.
struct KeyCombo: Codable, Equatable {
    var keyCode: Int
    var modifiers: Int
    /// The key's label as typed, e.g. "E" or "F5".
    var keyName: String

    static let defaultRegion = KeyCombo(keyCode: Keys.a, modifiers: optionKey, keyName: "A")
    static let defaultDictation = KeyCombo(keyCode: Keys.s, modifiers: optionKey, keyName: "S")

    /// Modifier glyphs in Apple's order, then the key: ["⌃", "⌥", "⌘", "E"].
    var displayKeys: [String] {
        var keys: [String] = []
        if modifiers & controlKey != 0 { keys.append("⌃") }
        if modifiers & optionKey != 0 { keys.append("⌥") }
        if modifiers & shiftKey != 0 { keys.append("⇧") }
        if modifiers & cmdKey != 0 { keys.append("⌘") }
        return keys + [keyName]
    }

    /// Builds a combo from a key press, or nil if it isn't usable as a global shortcut.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods = 0
        if flags.contains(.command) { mods |= cmdKey }
        if flags.contains(.option) { mods |= optionKey }
        if flags.contains(.control) { mods |= controlKey }
        if flags.contains(.shift) { mods |= shiftKey }
        let code = Int(event.keyCode)
        let name = Self.specialNames[code] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        let isFunctionKey = Self.functionKeys.contains(code)
        // Plain letters would stop you typing them; require ⌘, ⌥ or ⌃ unless it's an F-key.
        guard !name.isEmpty, isFunctionKey || mods & (cmdKey | optionKey | controlKey) != 0 else { return nil }
        self.init(keyCode: code, modifiers: mods, keyName: name)
    }

    init(keyCode: Int, modifiers: Int, keyName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyName = keyName
    }

    private static let functionKeys: Set<Int> = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
                                                 kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
                                                 kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
    private static let specialNames: [Int: String] = {
        var names: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
                                    kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→",
                                    kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
                                    kVK_PageUp: "⇞", kVK_PageDown: "⇟"]
        let fKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (i, code) in fKeys.enumerated() { names[code] = "F\(i + 1)" }
        return names
    }()
}
