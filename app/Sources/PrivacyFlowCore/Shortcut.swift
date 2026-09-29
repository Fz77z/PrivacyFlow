import Foundation

/// One modifier key, with its side distinguished.
public enum SideModifier: String, CaseIterable, Codable, Sendable {
    case leftControl = "left_control"
    case rightControl = "right_control"
    case leftOption = "left_option"
    case rightOption = "right_option"
    case leftShift = "left_shift"
    case rightShift = "right_shift"
    case leftCommand = "left_command"
    case rightCommand = "right_command"
    case function = "fn"

    /// The key code of the modifier key itself, as flagsChanged events carry it.
    public var keyCode: UInt16 {
        switch self {
        case .leftControl: 59
        case .rightControl: 62
        case .leftOption: 58
        case .rightOption: 61
        case .leftShift: 56
        case .rightShift: 60
        case .leftCommand: 55
        case .rightCommand: 54
        case .function: 63
        }
    }

    /// The bit in an event's flags that says this key is down. The sided keys
    /// use IOKit's device-dependent bits (NX_DEVICE*KEYMASK), because the
    /// generic flags are set for either side and cannot tell them apart. Fn
    /// has only the generic secondary-function bit.
    public var flagMask: UInt64 {
        switch self {
        case .leftControl: 0x0000_0001
        case .rightControl: 0x0000_2000
        case .leftShift: 0x0000_0002
        case .rightShift: 0x0000_0004
        case .leftCommand: 0x0000_0008
        case .rightCommand: 0x0000_0010
        case .leftOption: 0x0000_0020
        case .rightOption: 0x0000_0040
        case .function: 0x0080_0000
        }
    }

    public var name: String {
        switch self {
        case .leftControl: "Left Control"
        case .rightControl: "Right Control"
        case .leftOption: "Left Option"
        case .rightOption: "Right Option"
        case .leftShift: "Left Shift"
        case .rightShift: "Right Shift"
        case .leftCommand: "Left Command"
        case .rightCommand: "Right Command"
        case .function: "Fn"
        }
    }

    /// The modifier whose own key has this code, if it is one.
    public init?(keyCode: UInt16) {
        guard let match = Self.allCases.first(where: { $0.keyCode == keyCode }) else { return nil }
        self = match
    }

    /// The modifiers an event's flags say are down.
    public static func pressed(in flags: UInt64) -> Set<SideModifier> {
        Set(allCases.filter { flags & $0.flagMask != 0 })
    }

    var isShift: Bool { self == .leftShift || self == .rightShift }
    var isOption: Bool { self == .leftOption || self == .rightOption }
    var isCommand: Bool { self == .leftCommand || self == .rightCommand }
    var isControl: Bool { self == .leftControl || self == .rightControl }
}

/// The shortcut held to dictate: one modifier on its own, or a key with or
/// without modifiers. Recording starts when all of it is down and ends when
/// any part of it comes up.
public struct Shortcut: Equatable, Sendable {
    /// The key that completes the shortcut. For a modifier on its own, that
    /// modifier's own key.
    public var keyCode: UInt16
    /// Modifiers that must be held with `keyCode`, sides distinguished. Empty
    /// for a modifier on its own.
    public var modifiers: Set<SideModifier>
    /// How the shortcut is named to the user.
    public var label: String

    public static let rightOption = Shortcut(modifier: .rightOption)

    public init(keyCode: UInt16, modifiers: Set<SideModifier>) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        label = Self.describe(keyCode: keyCode, modifiers: modifiers)
    }

    public init(modifier: SideModifier) {
        self.init(keyCode: modifier.keyCode, modifiers: [])
    }

    /// The modifier this shortcut is, when it is a modifier on its own.
    public var soleModifier: SideModifier? {
        modifiers.isEmpty ? SideModifier(keyCode: keyCode) : nil
    }

    /// Whether this shortcut's key would reach other apps, so the key has to
    /// be kept from them. A modifier on its own types nothing.
    public var needsKeySwallowed: Bool {
        soleModifier == nil
    }

    /// Modifiers in the order macOS writes them, then the key.
    static func describe(keyCode: UInt16, modifiers: Set<SideModifier>) -> String {
        let order: [SideModifier] = [.leftControl, .rightControl, .leftOption, .rightOption, .leftShift, .rightShift, .leftCommand, .rightCommand, .function]
        if modifiers.isEmpty, let sole = SideModifier(keyCode: keyCode) {
            return sole.name
        }
        let names = order.filter(modifiers.contains).map(\.name) + [KeyNames.name(of: keyCode)]
        return names.joined(separator: " + ")
    }
}

// MARK: Whether a shortcut is safe to use

extension Shortcut {
    /// What PrivacyFlow thinks of a shortcut before using it.
    public enum Assessment: Equatable, Sendable {
        case allowed
        /// Usable, but something else on the Mac may want it too.
        case warned(String)
        /// Would break ordinary typing or navigation.
        case refused(String)
    }

    public var assessment: Assessment {
        if let sole = soleModifier {
            return Self.assessModifier(sole)
        }
        guard SideModifier(keyCode: keyCode) == nil else {
            return .refused("\(label) holds more than one modifier and no key. Use one modifier on its own, or a key with modifiers.")
        }
        let name = KeyNames.name(of: keyCode)
        let typing = modifiers.subtracting([.function])
        if typing.isEmpty {
            if KeyNames.functionKeys.contains(keyCode) {
                return reservedWarning ?? .allowed
            }
            if KeyNames.typesCharacter(keyCode) {
                return .refused("“\(name)” on its own types a character, so you could no longer type it. Hold it with Control and Option, or use a function key such as F13.")
            }
            return .refused("\(name) on its own is needed for editing and moving around. Hold it with Control and Option, or use a function key such as F13.")
        }
        // Shift and Option on their own still type and edit: Shift+A is a
        // capital A, Option+E starts an accent, Shift+Left selects and
        // Option+Delete deletes a word, so taking any of them stops that.
        if typing.allSatisfy({ $0.isShift || $0.isOption }) {
            if KeyNames.typesCharacter(keyCode) {
                return .refused("\(label) types a character, so you could no longer type it. Hold it with Control and Option, or use a function key.")
            }
            if KeyNames.editingKeys.contains(keyCode) {
                return .refused("\(label) selects or edits text in every app, so it would stop doing that. Hold it with Control and Option, or use a function key.")
            }
        }
        // Command with a single character is a standard shortcut in every app:
        // a swallowed Command+V would stop pasting everywhere.
        if typing.allSatisfy(\.isCommand) && KeyNames.characterKeys.contains(keyCode) {
            return .refused("\(label) is a standard shortcut in every app, such as copy, paste, undo or save, so it would stop working. Add another modifier, or use a function key.")
        }
        // Command with an editing key moves, selects and deletes by line and
        // document in every app, as Command+Left goes to the start of the
        // line, and Command+Tab switches apps.
        if typing.allSatisfy(\.isCommand) && KeyNames.editingKeys.contains(keyCode) {
            return .refused("\(label) moves, deletes or switches in every app, such as Command+Left for the start of the line, so it would stop doing that. Add another modifier, or use a function key.")
        }
        // Control+Tab switches tabs in browsers and most apps with tabs.
        if typing.allSatisfy(\.isControl) && keyCode == 48 {
            return .refused("\(label) switches tabs in browsers and most apps with tabs, so it would stop doing that. Add another modifier, or use a function key.")
        }
        // Control with a letter moves and edits in every text field, the way
        // Emacs does: Control+A is the start of the line, Control+K deletes.
        if typing.allSatisfy(\.isControl) && KeyNames.letterKeys.contains(keyCode) {
            return .refused("\(label) moves or edits in every text field, such as Control+A for the start of the line, so it would stop doing that. Add another modifier, or use a function key.")
        }
        return reservedWarning ?? .allowed
    }

    private var reservedWarning: Assessment? {
        Self.reserved[Self.ReservedKey(keyCode: keyCode, modifiers: modifiers)].map(Assessment.warned)
    }

    /// A modifier held on its own. The right-hand Option, Command and Control
    /// are rarely used for anything else. The left-hand ones and Shift are held
    /// for everyday shortcuts, clicks and capital letters: every Command-click
    /// or capital would open the microphone and play the press cue before
    /// PrivacyFlow saw the other key or the click and cancelled.
    private static func assessModifier(_ modifier: SideModifier) -> Assessment {
        switch modifier {
        case .rightOption, .rightCommand, .rightControl:
            return .allowed
        case .function:
            return .warned("macOS uses Fn (Globe) for the emoji picker, dictation and input switching, depending on System Settings, Keyboard. Holding it to dictate may also trigger one of those.")
        case .leftShift, .rightShift:
            return .warned("Shift is held for every capital letter, so each one would open the microphone and play the press cue for a moment before PrivacyFlow sees the letter and cancels. A right-hand Option, Command or Control avoids that.")
        case .leftCommand, .leftOption, .leftControl:
            return .warned("\(modifier.name) is held for everyday shortcuts and clicks, so each one would open the microphone and play the press cue for a moment before PrivacyFlow sees the other key or the click and cancels. A right-hand Option, Command or Control avoids that.")
        }
    }

    /// Shortcuts macOS commonly uses by default, matched without regard to
    /// side, because macOS does not distinguish sides for them.
    struct ReservedKey: Hashable {
        var keyCode: UInt16
        var sidelessModifiers: Set<String>

        init(keyCode: UInt16, modifiers: Set<SideModifier>) {
            self.keyCode = keyCode
            sidelessModifiers = Set(modifiers.map { modifier in
                switch modifier {
                case .leftControl, .rightControl: "control"
                case .leftOption, .rightOption: "option"
                case .leftShift, .rightShift: "shift"
                case .leftCommand, .rightCommand: "command"
                case .function: "fn"
                }
            })
        }

        init(keyCode: UInt16, _ modifiers: String...) {
            self.keyCode = keyCode
            sidelessModifiers = Set(modifiers)
        }
    }

    static let reserved: [ReservedKey: String] = [
        ReservedKey(keyCode: 49, "command"): "Command + Space opens Spotlight by default, so it would do both.",
        ReservedKey(keyCode: 49, "command", "option"): "Command + Option + Space opens a Finder search by default, so it would do both.",
        ReservedKey(keyCode: 49, "control"): "Control + Space switches input source by default, so it would do both.",
        ReservedKey(keyCode: 126, "control"): "Control + Up opens Mission Control by default, so it would do both.",
        ReservedKey(keyCode: 125, "control"): "Control + Down shows the app's windows by default, so it would do both.",
        ReservedKey(keyCode: 123, "control"): "Control + Left moves one space left by default, so it would do both.",
        ReservedKey(keyCode: 124, "control"): "Control + Right moves one space right by default, so it would do both.",
        ReservedKey(keyCode: 103): "F11 shows the desktop by default, so it would do both.",
        ReservedKey(keyCode: 111): "F12 opens Notification Centre or the dashboard on some setups, so it may do both.",
    ]
}

/// Names and classes of keys by key code, independent of keyboard layout.
public enum KeyNames {
    /// F1 to F20, the only keys usable with no modifier at all.
    public static let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    private static let names: [UInt16: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L", 46: "M",
        45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 50: "`", 10: "§",
        49: "Space", 36: "Return", 76: "Enter", 48: "Tab", 53: "Escape", 51: "Delete", 117: "Forward Delete",
        123: "Left Arrow", 124: "Right Arrow", 125: "Down Arrow", 126: "Up Arrow",
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down", 114: "Help",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        65: "Keypad .", 67: "Keypad *", 69: "Keypad +", 71: "Keypad Clear", 75: "Keypad /", 78: "Keypad -", 81: "Keypad =",
        82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4", 87: "Keypad 5", 88: "Keypad 6",
        89: "Keypad 7", 91: "Keypad 8", 92: "Keypad 9",
    ]

    public static func name(of keyCode: UInt16) -> String {
        if let modifier = SideModifier(keyCode: keyCode) { return modifier.name }
        return names[keyCode] ?? "Key \(keyCode)"
    }

    /// The letter keys, by position.
    public static let letterKeys: Set<UInt16> = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]
    /// Letters, digits and punctuation, including the extra keys on ISO and
    /// JIS keyboards. Space is not among them.
    public static let characterKeys: Set<UInt16> = letterKeys.union([
        29, 18, 19, 20, 21, 23, 22, 26, 28, 25, // 0 to 9
        27, 24, 33, 30, 42, 41, 39, 43, 47, 44, 50, // - = [ ] \ ; ' , . / `
        10, 93, 94, 95, // ISO §, JIS ¥, JIS _, JIS keypad comma
    ])
    /// The numeric keypad, listed key by key: F17 to F20 have codes among
    /// these, so a range would wrongly catch them.
    public static let keypadKeys: Set<UInt16> = [65, 67, 69, 71, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92]
    /// Keys that move the cursor or edit rather than type.
    public static let editingKeys: Set<UInt16> = [123, 124, 125, 126, 51, 117, 48, 36, 76, 115, 119, 116, 121]

    /// Whether a key types a character: letters, digits, punctuation, Space
    /// and the keypad's characters. Checked by key position, so it holds for
    /// any layout.
    public static func typesCharacter(_ keyCode: UInt16) -> Bool {
        characterKeys.contains(keyCode) || keyCode == 49 || keypadKeys.subtracting([71, 76]).contains(keyCode)
    }

}

// MARK: Persistence

extension Shortcut: Codable {
    /// The version of the stored form. A stored shortcut of any other version
    /// is reported as unreadable rather than guessed at.
    public static let storedVersion = 1

    private enum CodingKeys: String, CodingKey {
        case version
        case keyCode = "key_code"
        case modifiers
        case label
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.storedVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "version \(version), and this PrivacyFlow reads version \(Self.storedVersion)")
        }
        keyCode = try container.decode(UInt16.self, forKey: .keyCode)
        modifiers = Set(try container.decode([SideModifier].self, forKey: .modifiers))
        // The label is written for people reading the file; the one shown is
        // always rebuilt from the key, so a hand-edited label cannot lie.
        _ = try container.decode(String.self, forKey: .label)
        label = Self.describe(keyCode: keyCode, modifiers: modifiers)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.storedVersion, forKey: .version)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(SideModifier.allCases.filter(modifiers.contains), forKey: .modifiers)
        try container.encode(label, forKey: .label)
    }
}
