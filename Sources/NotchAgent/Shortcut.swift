import AppKit
import Carbon.HIToolbox

/// The system-wide "ask an agent" key: ⌥ Space unless the user records
/// another in Settings. Stored as the Carbon key code and modifiers the hot
/// key API takes, plus the key's name for showing it.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon flags: `cmdKey`, `optionKey`, `controlKey`, `shiftKey`.
    var modifiers: UInt32
    /// As shown on its key cap: "Space", "K", "F5", "↩"…
    var key: String

    static let standard = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), key: "Space")
    static let changed = Notification.Name("NotchAgentShortcutChanged")
    /// Views showing the shortcut watch this key (`@AppStorage`) so they
    /// redraw the moment it changes.
    static let defaultsKey = "askShortcut"

    static var current: Shortcut {
        get {
            UserDefaults.standard.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? standard
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: defaultsKey)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// Key caps in the order macOS menus show them: ⌃ ⌥ ⇧ ⌘, then the key.
    var symbols: [String] {
        var caps: [String] = []
        if modifiers & UInt32(controlKey) != 0 { caps.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { caps.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { caps.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { caps.append("⌘") }
        return caps + [key]
    }

    var display: String { symbols.joined(separator: " ") }

    /// A key press while recording. Needs ⌘, ⌥ or ⌃ (or is an F-key), so
    /// plain typing never becomes a system-wide shortcut.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        let code = Int(event.keyCode)
        let functionKey = Self.functionKeys[code]
        guard carbon & UInt32(cmdKey | optionKey | controlKey) != 0 || functionKey != nil else { return nil }
        guard let name = functionKey ?? Self.names[code] ?? event.charactersIgnoringModifiers?.uppercased(), !name.isEmpty else { return nil }
        self.init(keyCode: UInt32(code), modifiers: carbon, key: name)
    }

    private init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    private static let names: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13",
        kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
    ]
}
