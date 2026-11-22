import Carbon.HIToolbox
import Foundation

// MARK: - The trigger

/// What summons the panel. A key chord is the only kind today. Other kinds, such as
/// double-tapping a modifier, would be new cases here with their own stored shape.
public enum SummonTrigger: Hashable, Sendable {
    case keyChord(KeyChord)

    /// Option-Shift-Space, because Option-Space belongs to Alfred and the ChatGPT app on the
    /// owner's Mac, Command-Space to Spotlight, and Control-Space to switching input sources.
    public static let `default` = SummonTrigger.keyChord(KeyChord(keyCode: UInt16(kVK_Space), modifiers: [.option, .shift]))

    public var keyChord: KeyChord? {
        switch self {
        case .keyChord(let chord): chord
        }
    }
}

/// A key and the modifiers held with it, as macOS reports them: a virtual key code, which is a
/// position on the keyboard and not a character, and the device independent modifier flags.
public struct KeyChord: Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: Modifiers

    public init(keyCode: UInt16, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// The four modifiers a chord can hold. The raw values are those of
    /// `NSEvent.ModifierFlags`, so flags from an event convert without a table.
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }

        public static let shift = Modifiers(rawValue: 1 << 17)
        public static let control = Modifiers(rawValue: 1 << 18)
        public static let option = Modifiers(rawValue: 1 << 19)
        public static let command = Modifiers(rawValue: 1 << 20)

        /// Keeps only the four modifiers from a set of event flags, dropping Caps Lock, Fn,
        /// the numeric keypad flag, and the device dependent bits.
        public init(eventFlags: UInt) {
            self.init(rawValue: eventFlags & (Self.shift.rawValue | Self.control.rawValue | Self.option.rawValue | Self.command.rawValue))
        }

        /// The flags `RegisterEventHotKey` takes.
        public var carbonFlags: UInt32 {
            var flags = 0
            if contains(.command) { flags |= cmdKey }
            if contains(.shift) { flags |= shiftKey }
            if contains(.option) { flags |= optionKey }
            if contains(.control) { flags |= controlKey }
            return UInt32(flags)
        }

        public init(carbonFlags: UInt32) {
            let flags = Int(carbonFlags)
            var modifiers: Modifiers = []
            if flags & cmdKey != 0 { modifiers.insert(.command) }
            if flags & shiftKey != 0 { modifiers.insert(.shift) }
            if flags & optionKey != 0 { modifiers.insert(.option) }
            if flags & controlKey != 0 { modifiers.insert(.control) }
            self = modifiers
        }

        /// The symbols in the order macOS menus show them: Control, Option, Shift, Command.
        public var symbols: String {
            var text = ""
            if contains(.control) { text += "⌃" }
            if contains(.option) { text += "⌥" }
            if contains(.shift) { text += "⇧" }
            if contains(.command) { text += "⌘" }
            return text
        }

        /// The names in the same order, as in "Option-Shift".
        public var names: [String] {
            var names: [String] = []
            if contains(.control) { names.append("Control") }
            if contains(.option) { names.append("Option") }
            if contains(.shift) { names.append("Shift") }
            if contains(.command) { names.append("Command") }
            return names
        }
    }

    /// The chord as menus show it, such as `⌥⇧Space` or `⌘K`. The key is named through
    /// `keys`, which should be the current keyboard layout, so it reads right on any layout.
    public func displayName(keys: any KeyCharacterSource) -> String {
        modifiers.symbols + KeyNames.name(for: keyCode, keys: keys)
    }

    /// The chord in words, such as "Option-Shift-Space", for VoiceOver and for text.
    public func spokenName(keys: any KeyCharacterSource) -> String {
        (modifiers.names + [KeyNames.spokenName(for: keyCode, keys: keys)]).joined(separator: "-")
    }
}

// MARK: - Storing it

/// The summon trigger in the app's preferences, as a small JSON string so `defaults read`
/// shows it plainly: `{"kind":"keyChord","keyCode":49,"modifierFlags":1048576}`.
///
/// With nothing stored the trigger is the default. Clearing it stores `{"kind":"none"}`, so a
/// cleared shortcut stays cleared and is not mistaken for a fresh install.
public enum SummonTriggerSetting {
    public static let key = "summonTrigger"

    public enum Stored: Equatable, Sendable {
        /// Nothing stored, so the default applies.
        case unset
        /// The owner removed the shortcut.
        case cleared
        case trigger(SummonTrigger)
        /// Something stored that this build cannot read, such as a kind from a newer build.
        case unreadable(String)

        /// The trigger in effect: the default when unset or unreadable.
        public var trigger: SummonTrigger? {
            switch self {
            case .unset, .unreadable: .default
            case .cleared: nil
            case .trigger(let trigger): trigger
            }
        }
    }

    public static func load(_ defaults: UserDefaults = .standard) -> Stored {
        guard let text = defaults.string(forKey: key) else { return .unset }
        return decode(text)
    }

    public static func save(_ trigger: SummonTrigger?, _ defaults: UserDefaults = .standard) {
        defaults.set(encode(trigger), forKey: key)
    }

    /// Goes back to the default by storing nothing.
    public static func restoreDefault(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }

    private struct Shape: Codable {
        var kind: String
        var keyCode: UInt16?
        var modifierFlags: UInt?
    }

    public static func encode(_ trigger: SummonTrigger?) -> String {
        let shape: Shape
        switch trigger {
        case nil: shape = Shape(kind: "none")
        case .keyChord(let chord)?: shape = Shape(kind: "keyChord", keyCode: chord.keyCode, modifierFlags: chord.modifiers.rawValue)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(shape)).flatMap { String(data: $0, encoding: .utf8) } ?? #"{"kind":"none"}"#
    }

    public static func decode(_ text: String) -> Stored {
        guard let shape = try? JSONDecoder().decode(Shape.self, from: Data(text.utf8)) else {
            return .unreadable(text)
        }
        switch shape.kind {
        case "none":
            return .cleared
        case "keyChord":
            guard let keyCode = shape.keyCode, let flags = shape.modifierFlags else { return .unreadable(text) }
            return .trigger(.keyChord(KeyChord(keyCode: keyCode, modifiers: KeyChord.Modifiers(eventFlags: flags))))
        default:
            return .unreadable(text)
        }
    }
}

// MARK: - Naming keys

/// What a key types on a keyboard layout, without modifiers or with Shift.
public protocol KeyCharacterSource: Sendable {
    func character(for keyCode: UInt16, shift: Bool) -> String?
}

/// Names for keys. Keys that type nothing visible have fixed names and symbols. Every other
/// key is named by what it types on the layout given, so a French layout's A key reads "Q".
public enum KeyNames {
    private static let special: [Int: (symbol: String, spoken: String)] = [
        kVK_Space: ("Space", "Space"),
        kVK_Return: ("↩", "Return"),
        kVK_ANSI_KeypadEnter: ("⌤", "Enter"),
        kVK_Tab: ("⇥", "Tab"),
        kVK_Delete: ("⌫", "Delete"),
        kVK_ForwardDelete: ("⌦", "Forward Delete"),
        kVK_Escape: ("⎋", "Escape"),
        kVK_LeftArrow: ("←", "Left Arrow"),
        kVK_RightArrow: ("→", "Right Arrow"),
        kVK_UpArrow: ("↑", "Up Arrow"),
        kVK_DownArrow: ("↓", "Down Arrow"),
        kVK_Home: ("↖", "Home"),
        kVK_End: ("↘", "End"),
        kVK_PageUp: ("⇞", "Page Up"),
        kVK_PageDown: ("⇟", "Page Down"),
        kVK_Help: ("Help", "Help"),
        kVK_ANSI_KeypadClear: ("⌧", "Clear"),
    ]

    /// F1 to F20, by key code.
    public static let functionKeys: [Int: Int] = [
        kVK_F1: 1, kVK_F2: 2, kVK_F3: 3, kVK_F4: 4, kVK_F5: 5, kVK_F6: 6, kVK_F7: 7, kVK_F8: 8, kVK_F9: 9, kVK_F10: 10,
        kVK_F11: 11, kVK_F12: 12, kVK_F13: 13, kVK_F14: 14, kVK_F15: 15, kVK_F16: 16, kVK_F17: 17, kVK_F18: 18,
        kVK_F19: 19, kVK_F20: 20,
    ]

    private static let keypad: Set<Int> = [
        kVK_ANSI_Keypad0, kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4,
        kVK_ANSI_Keypad5, kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9,
        kVK_ANSI_KeypadDecimal, kVK_ANSI_KeypadMultiply, kVK_ANSI_KeypadPlus, kVK_ANSI_KeypadMinus,
        kVK_ANSI_KeypadDivide, kVK_ANSI_KeypadEquals,
    ]

    /// Keys that are only modifiers. They never make a chord on their own.
    public static let modifierKeys: Set<Int> = [
        kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift, kVK_Option, kVK_RightOption,
        kVK_Control, kVK_RightControl, kVK_CapsLock, kVK_Function,
    ]

    public static func isFunctionKey(_ keyCode: UInt16) -> Bool { functionKeys[Int(keyCode)] != nil }
    public static func isModifierKey(_ keyCode: UInt16) -> Bool { modifierKeys.contains(Int(keyCode)) }

    /// True for a key with a fixed name, such as Space, Return, an arrow, or F5, as against a
    /// key that types a letter, digit, or symbol.
    public static func hasFixedName(_ keyCode: UInt16) -> Bool {
        special[Int(keyCode)] != nil || isFunctionKey(keyCode)
    }

    /// A short name for menus: a symbol for keys that have one, otherwise what the key types,
    /// in capitals.
    public static func name(for keyCode: UInt16, keys: any KeyCharacterSource) -> String {
        if let entry = special[Int(keyCode)] { return entry.symbol }
        if let number = functionKeys[Int(keyCode)] { return "F\(number)" }
        let typed = typedCharacter(for: keyCode, keys: keys)
        return keypad.contains(Int(keyCode)) ? "Keypad \(typed)" : typed
    }

    /// A name in words, for VoiceOver and text.
    public static func spokenName(for keyCode: UInt16, keys: any KeyCharacterSource) -> String {
        if let entry = special[Int(keyCode)] { return entry.spoken }
        return name(for: keyCode, keys: keys)
    }

    /// What the key types, uppercased, from the layout given, then the US layout, then the key
    /// code itself as a last resort.
    static func typedCharacter(for keyCode: UInt16, keys: any KeyCharacterSource) -> String {
        for source in [keys, USKeyboardLayout()] as [any KeyCharacterSource] {
            if let text = source.character(for: keyCode, shift: false), isVisible(text) {
                return text.uppercased()
            }
        }
        return "Key \(keyCode)"
    }

    static func isVisible(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { !$0.properties.isWhitespace && $0.properties.generalCategory != .control }
    }
}

/// The US layout for the keys that type characters, used when the current layout gives nothing.
public struct USKeyboardLayout: KeyCharacterSource {
    public init() {}

    private static let table: [Int: (String, String)] = [
        kVK_ANSI_A: ("a", "A"), kVK_ANSI_B: ("b", "B"), kVK_ANSI_C: ("c", "C"), kVK_ANSI_D: ("d", "D"),
        kVK_ANSI_E: ("e", "E"), kVK_ANSI_F: ("f", "F"), kVK_ANSI_G: ("g", "G"), kVK_ANSI_H: ("h", "H"),
        kVK_ANSI_I: ("i", "I"), kVK_ANSI_J: ("j", "J"), kVK_ANSI_K: ("k", "K"), kVK_ANSI_L: ("l", "L"),
        kVK_ANSI_M: ("m", "M"), kVK_ANSI_N: ("n", "N"), kVK_ANSI_O: ("o", "O"), kVK_ANSI_P: ("p", "P"),
        kVK_ANSI_Q: ("q", "Q"), kVK_ANSI_R: ("r", "R"), kVK_ANSI_S: ("s", "S"), kVK_ANSI_T: ("t", "T"),
        kVK_ANSI_U: ("u", "U"), kVK_ANSI_V: ("v", "V"), kVK_ANSI_W: ("w", "W"), kVK_ANSI_X: ("x", "X"),
        kVK_ANSI_Y: ("y", "Y"), kVK_ANSI_Z: ("z", "Z"),
        kVK_ANSI_0: ("0", ")"), kVK_ANSI_1: ("1", "!"), kVK_ANSI_2: ("2", "@"), kVK_ANSI_3: ("3", "#"),
        kVK_ANSI_4: ("4", "$"), kVK_ANSI_5: ("5", "%"), kVK_ANSI_6: ("6", "^"), kVK_ANSI_7: ("7", "&"),
        kVK_ANSI_8: ("8", "*"), kVK_ANSI_9: ("9", "("),
        kVK_ANSI_Minus: ("-", "_"), kVK_ANSI_Equal: ("=", "+"), kVK_ANSI_LeftBracket: ("[", "{"),
        kVK_ANSI_RightBracket: ("]", "}"), kVK_ANSI_Backslash: ("\\", "|"), kVK_ANSI_Semicolon: (";", ":"),
        kVK_ANSI_Quote: ("'", "\""), kVK_ANSI_Comma: (",", "<"), kVK_ANSI_Period: (".", ">"),
        kVK_ANSI_Slash: ("/", "?"), kVK_ANSI_Grave: ("`", "~"), kVK_ISO_Section: ("§", "±"),
        kVK_ANSI_Keypad0: ("0", "0"), kVK_ANSI_Keypad1: ("1", "1"), kVK_ANSI_Keypad2: ("2", "2"),
        kVK_ANSI_Keypad3: ("3", "3"), kVK_ANSI_Keypad4: ("4", "4"), kVK_ANSI_Keypad5: ("5", "5"),
        kVK_ANSI_Keypad6: ("6", "6"), kVK_ANSI_Keypad7: ("7", "7"), kVK_ANSI_Keypad8: ("8", "8"),
        kVK_ANSI_Keypad9: ("9", "9"), kVK_ANSI_KeypadDecimal: (".", "."), kVK_ANSI_KeypadMultiply: ("*", "*"),
        kVK_ANSI_KeypadPlus: ("+", "+"), kVK_ANSI_KeypadMinus: ("-", "-"), kVK_ANSI_KeypadDivide: ("/", "/"),
        kVK_ANSI_KeypadEquals: ("=", "="),
    ]

    public func character(for keyCode: UInt16, shift: Bool) -> String? {
        guard let entry = Self.table[Int(keyCode)] else { return nil }
        return shift ? entry.1 : entry.0
    }
}

/// The keyboard layout selected now, read through `UCKeyTranslate`. An input method with no
/// layout of its own, such as Japanese, falls back to the ASCII capable layout it types with.
///
/// It copies the layout when made, so make a fresh one to follow a change of input source.
/// Text Input Sources must be asked on the main thread.
public struct CurrentKeyboardLayout: KeyCharacterSource {
    private let layout: Data?
    private let keyboardType: UInt32

    @MainActor
    public init() {
        func data(_ source: TISInputSource?) -> Data? {
            guard let source, let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
            return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        }
        layout = data(TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue())
            ?? data(TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue())
        keyboardType = UInt32(LMGetKbdType())
    }

    public func character(for keyCode: UInt16, shift: Bool) -> String? {
        guard let layout else { return nil }
        return layout.withUnsafeBytes { bytes -> String? in
            guard let base = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 8)
            // The modifier state is the Carbon flags shifted right by eight.
            let modifierState = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
            let status = UCKeyTranslate(
                base, keyCode, UInt16(kUCKeyActionDisplay), modifierState, keyboardType,
                OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, characters.count, &length, &characters)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }
}

// MARK: - Which chords are allowed

/// A shortcut that something else owns, matched the way menus match key equivalents: by the
/// character, so it follows the keyboard layout.
public struct ReservedShortcut: Hashable, Sendable {
    /// A menu's key equivalent, such as "w", or ":" for Command-Shift-Semicolon on a US layout.
    public var keyEquivalent: String
    public var modifiers: KeyChord.Modifiers
    /// What it does, as in "Close".
    public var title: String

    public init(_ keyEquivalent: String, _ modifiers: KeyChord.Modifiers, _ title: String) {
        self.keyEquivalent = keyEquivalent
        self.modifiers = modifiers
        self.title = title
    }

    /// True when pressing the chord would trigger this shortcut. A letter key equivalent with
    /// Shift in its mask matches the unshifted letter, and a shifted symbol such as ":"
    /// matches the key that types it with Shift held.
    public func matches(_ chord: KeyChord, keys: any KeyCharacterSource) -> Bool {
        let equivalent = keyEquivalent.lowercased()
        if let plain = keys.character(for: chord.keyCode, shift: false)?.lowercased(),
           plain == equivalent, chord.modifiers == modifiers
        {
            return true
        }
        if !modifiers.contains(.shift), chord.modifiers == modifiers.union(.shift),
           let shifted = keys.character(for: chord.keyCode, shift: true), shifted == keyEquivalent
        {
            return true
        }
        return false
    }

    /// The app's own menu shortcuts, which a global hotkey would take from the app itself.
    /// `MainMenu` in the app must list nothing that is not here, which a test checks.
    public static let appMenu: [ReservedShortcut] = [
        .init(",", .command, "Settings"),
        .init("w", .command, "Close"),
        .init(".", .command, "Stop"),
        .init("q", .command, "Quit"),
        .init("h", .command, "Hide"),
        .init("h", [.command, .option], "Hide Others"),
        .init("z", .command, "Undo"),
        .init("z", [.command, .shift], "Redo"),
        .init("x", .command, "Cut"),
        .init("c", .command, "Copy"),
        .init("v", .command, "Paste"),
        .init("v", [.command, .option, .shift], "Paste and Match Style"),
        .init("a", .command, "Select All"),
        .init(":", .command, "Show Spelling and Grammar"),
        .init(";", .command, "Check Document Now"),
    ]

    /// Shortcuts nearly every Mac app has. Holding one system wide would break it everywhere.
    public static let everyApp: [ReservedShortcut] = [
        .init("n", .command, "New"),
        .init("o", .command, "Open"),
        .init("s", .command, "Save"),
        .init("p", .command, "Print"),
        .init("t", .command, "New Tab"),
        .init("f", .command, "Find"),
        .init("g", .command, "Find Next"),
        .init("m", .command, "Minimize"),
    ]
}

/// Chords macOS handles itself before any app sees them, which no hotkey can take, and which
/// are not in the symbolic hot keys list. They are matched by key code.
public struct SystemReservedChord: Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: KeyChord.Modifiers
    public var title: String

    public static let all: [SystemReservedChord] = [
        .init(keyCode: UInt16(kVK_Tab), modifiers: .command, title: "switches apps"),
        .init(keyCode: UInt16(kVK_Tab), modifiers: [.command, .shift], title: "switches apps"),
        .init(keyCode: UInt16(kVK_Escape), modifiers: [.command, .option], title: "opens Force Quit"),
        .init(keyCode: UInt16(kVK_ANSI_Q), modifiers: [.command, .control], title: "locks the screen"),
        .init(keyCode: UInt16(kVK_ANSI_Q), modifiers: [.command, .shift], title: "logs out"),
    ]
}

public enum KeyChordRules {
    /// Why a chord cannot be the summon shortcut, in a short sentence for the recorder, or nil
    /// when it can be.
    public static func rejection(
        for chord: KeyChord, keys: any KeyCharacterSource,
        appMenu: [ReservedShortcut] = ReservedShortcut.appMenu,
        everyApp: [ReservedShortcut] = ReservedShortcut.everyApp
    ) -> String? {
        let name = chord.displayName(keys: keys)
        let modifiers = chord.modifiers
        if KeyNames.isModifierKey(chord.keyCode) {
            return "Press a key along with the modifiers."
        }
        if KeyNames.isFunctionKey(chord.keyCode) {
            // A function key works on its own, and with any modifiers.
        } else if modifiers.isEmpty {
            return "\(name) on its own would stop that key working everywhere. Hold ⌘, ⌥, or ⌃ with it."
        } else if modifiers == .shift {
            return "\(name) only types a character. Add ⌘, ⌥, or ⌃."
        } else if modifiers.isSubset(of: [.option, .shift]), !KeyNames.hasFixedName(chord.keyCode) {
            return "\(name) types a character, as ⌥ keys do. Add ⌘ or ⌃."
        }
        if let reserved = SystemReservedChord.all.first(where: { $0.keyCode == chord.keyCode && $0.modifiers == modifiers }) {
            return "\(name) \(reserved.title) in macOS, so it cannot summon the panel."
        }
        if let reserved = appMenu.first(where: { $0.matches(chord, keys: keys) }) {
            return "\(name) is \(reserved.title) in this app's menu. Choose another."
        }
        if let reserved = everyApp.first(where: { $0.matches(chord, keys: keys) }) {
            return "\(name) is \(reserved.title) in most apps, and taking it would break it there. Choose another."
        }
        return nil
    }
}

// MARK: - macOS's own shortcuts

/// One entry from macOS's symbolic hot keys, the shortcuts in System Settings, Keyboard,
/// Keyboard Shortcuts, as `CopySymbolicHotKeys` returns them.
public struct SystemShortcut: Hashable, Sendable {
    public var keyCode: UInt16
    public var carbonModifiers: UInt32
    public var isEnabled: Bool

    public init(keyCode: UInt16, carbonModifiers: UInt32, isEnabled: Bool) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.isEnabled = isEnabled
    }

    /// The four modifiers, ignoring any other bits the entry carries.
    public var modifiers: KeyChord.Modifiers { KeyChord.Modifiers(carbonFlags: carbonModifiers) }

    /// Every symbolic hot key, enabled or not. Reading them changes nothing.
    public static func current() -> [SystemShortcut] {
        var array: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&array) == noErr, let list = array?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let code = entry[kHISymbolicHotKeyCode as String] as? Int,
                  let modifiers = entry[kHISymbolicHotKeyModifiers as String] as? Int,
                  code >= 0, code < 0xFFFF
            else { return nil }
            let enabled = entry[kHISymbolicHotKeyEnabled as String] as? Bool ?? false
            return SystemShortcut(keyCode: UInt16(code), carbonModifiers: UInt32(truncatingIfNeeded: modifiers), isEnabled: enabled)
        }
    }

    /// What macOS uses some chords for by default. The symbolic hot keys list says only that a
    /// chord is taken, not by what, so this names the usual owner.
    private static let usualOwners: [KeyChord: String] = [
        KeyChord(keyCode: UInt16(kVK_Space), modifiers: .command): "Spotlight",
        KeyChord(keyCode: UInt16(kVK_Space), modifiers: [.command, .option]): "the Finder search window",
        KeyChord(keyCode: UInt16(kVK_Space), modifiers: .control): "switching input sources",
        KeyChord(keyCode: UInt16(kVK_Space), modifiers: [.control, .option]): "switching input sources",
        KeyChord(keyCode: UInt16(kVK_ANSI_3), modifiers: [.command, .shift]): "screenshots",
        KeyChord(keyCode: UInt16(kVK_ANSI_4), modifiers: [.command, .shift]): "screenshots",
        KeyChord(keyCode: UInt16(kVK_ANSI_5), modifiers: [.command, .shift]): "screenshots",
        KeyChord(keyCode: UInt16(kVK_UpArrow), modifiers: .control): "Mission Control",
        KeyChord(keyCode: UInt16(kVK_DownArrow), modifiers: .control): "App Exposé",
    ]

    /// A warning when an enabled macOS shortcut uses the same chord, which would win over the
    /// hotkey. Nil when there is none.
    public static func conflict(for chord: KeyChord, in shortcuts: [SystemShortcut], keys: any KeyCharacterSource) -> String? {
        guard shortcuts.contains(where: { $0.isEnabled && $0.keyCode == chord.keyCode && $0.modifiers == chord.modifiers }) else {
            return nil
        }
        let name = chord.displayName(keys: keys)
        let owner = usualOwners[chord].map { ", usually for \($0)," } ?? ""
        return "macOS has \(name) turned on as a system shortcut\(owner) and it will take the key first. Turn it off in System Settings, Keyboard, Keyboard Shortcuts."
    }
}
