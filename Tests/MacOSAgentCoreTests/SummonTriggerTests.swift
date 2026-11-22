import Carbon.HIToolbox
import Foundation
import Testing
@testable import MacOSAgentCore

/// A stand-in layout: the US layout with some keys typing something else, as on a French or
/// German keyboard.
private struct StandInLayout: KeyCharacterSource {
    var overrides: [Int: (String, String)] = [:]

    func character(for keyCode: UInt16, shift: Bool) -> String? {
        if let entry = overrides[Int(keyCode)] { return shift ? entry.1 : entry.0 }
        return USKeyboardLayout().character(for: keyCode, shift: shift)
    }
}

/// French AZERTY: the A key types "q", the Q key types "a", the Z key types "w", the W key
/// types "z", and the M key types ",".
private let french = StandInLayout(overrides: [
    kVK_ANSI_A: ("q", "Q"), kVK_ANSI_Q: ("a", "A"), kVK_ANSI_Z: ("w", "W"), kVK_ANSI_W: ("z", "Z"),
    kVK_ANSI_M: (",", "?"), kVK_ANSI_Semicolon: ("m", "M"),
])
private let us = USKeyboardLayout()

/// A layout that gives nothing, as an input method without a layout does.
private struct EmptyLayout: KeyCharacterSource {
    func character(for keyCode: UInt16, shift: Bool) -> String? { nil }
}

private func chord(_ key: Int, _ modifiers: KeyChord.Modifiers) -> KeyChord {
    KeyChord(keyCode: UInt16(key), modifiers: modifiers)
}

private func freshDefaults() -> UserDefaults {
    let name = "mac-os-agent-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Suite struct SummonTriggerStorageTests {
    @Test func aFreshInstallUsesOptionShiftSpace() {
        let defaults = freshDefaults()
        #expect(SummonTriggerSetting.load(defaults) == .unset)
        #expect(SummonTriggerSetting.load(defaults).trigger == .keyChord(chord(kVK_Space, [.option, .shift])))
        #expect(SummonTrigger.default.keyChord?.displayName(keys: us) == "⌥⇧Space")
    }

    @Test func aChordIsStoredAsAKeyCodeAndModifierFlags() {
        let defaults = freshDefaults()
        SummonTriggerSetting.save(.keyChord(chord(kVK_Space, .command)), defaults)
        #expect(defaults.string(forKey: SummonTriggerSetting.key) == #"{"keyCode":49,"kind":"keyChord","modifierFlags":1048576}"#)
        #expect(SummonTriggerSetting.load(defaults) == .trigger(.keyChord(chord(kVK_Space, .command))))
    }

    @Test func aClearedShortcutStaysClearedAndRestoringGoesBackToTheDefault() {
        let defaults = freshDefaults()
        SummonTriggerSetting.save(nil, defaults)
        #expect(SummonTriggerSetting.load(defaults) == .cleared)
        #expect(SummonTriggerSetting.load(defaults).trigger == nil)
        SummonTriggerSetting.restoreDefault(defaults)
        #expect(SummonTriggerSetting.load(defaults).trigger == .default)
    }

    @Test(arguments: ["not json", #"{"kind":"doubleTap","modifier":"option"}"#, #"{"kind":"keyChord"}"#])
    func somethingUnreadableFallsBackToTheDefault(_ text: String) {
        #expect(SummonTriggerSetting.decode(text) == .unreadable(text))
        #expect(SummonTriggerSetting.decode(text).trigger == .default)
    }

    @Test func storedFlagsKeepOnlyTheFourModifiers() {
        // Caps Lock (1 << 16) and Fn (1 << 23) are dropped.
        let stored = #"{"kind":"keyChord","keyCode":49,"modifierFlags":\#((1 << 16) | (1 << 20) | (1 << 23))}"#
        #expect(SummonTriggerSetting.decode(stored) == .trigger(.keyChord(chord(kVK_Space, .command))))
    }

    @Test func modifiersConvertToAndFromCarbonFlags() {
        let all: KeyChord.Modifiers = [.command, .option, .shift, .control]
        #expect(all.carbonFlags == UInt32(cmdKey | optionKey | shiftKey | controlKey))
        #expect(KeyChord.Modifiers(carbonFlags: all.carbonFlags) == all)
        #expect(KeyChord.Modifiers.command.carbonFlags == UInt32(cmdKey))
        #expect(KeyChord.Modifiers([.option, .shift]).carbonFlags == UInt32(optionKey | shiftKey))
    }
}

@Suite struct KeyChordNameTests {
    @Test func modifiersComeInTheOrderMenusUse() {
        #expect(chord(kVK_ANSI_K, [.command, .shift, .option, .control]).displayName(keys: us) == "⌃⌥⇧⌘K")
        #expect(chord(kVK_ANSI_K, [.command, .shift, .option, .control]).spokenName(keys: us) == "Control-Option-Shift-Command-K")
        #expect(chord(kVK_Space, .command).displayName(keys: us) == "⌘Space")
        #expect(chord(kVK_Space, [.option, .shift]).spokenName(keys: us) == "Option-Shift-Space")
    }

    @Test func keysThatTypeNothingVisibleHaveFixedNames() {
        #expect(KeyNames.name(for: UInt16(kVK_Return), keys: us) == "↩")
        #expect(KeyNames.name(for: UInt16(kVK_Tab), keys: us) == "⇥")
        #expect(KeyNames.name(for: UInt16(kVK_Delete), keys: us) == "⌫")
        #expect(KeyNames.name(for: UInt16(kVK_ForwardDelete), keys: us) == "⌦")
        #expect(KeyNames.name(for: UInt16(kVK_Escape), keys: us) == "⎋")
        #expect(KeyNames.name(for: UInt16(kVK_LeftArrow), keys: us) == "←")
        #expect(KeyNames.name(for: UInt16(kVK_RightArrow), keys: us) == "→")
        #expect(KeyNames.name(for: UInt16(kVK_UpArrow), keys: us) == "↑")
        #expect(KeyNames.name(for: UInt16(kVK_DownArrow), keys: us) == "↓")
        #expect(KeyNames.name(for: UInt16(kVK_F1), keys: us) == "F1")
        #expect(KeyNames.name(for: UInt16(kVK_F12), keys: us) == "F12")
        #expect(KeyNames.name(for: UInt16(kVK_F20), keys: us) == "F20")
        #expect(KeyNames.spokenName(for: UInt16(kVK_Return), keys: us) == "Return")
        #expect(KeyNames.spokenName(for: UInt16(kVK_UpArrow), keys: us) == "Up Arrow")
    }

    @Test func otherKeysAreNamedByTheLayout() {
        #expect(chord(kVK_ANSI_A, .command).displayName(keys: us) == "⌘A")
        #expect(chord(kVK_ANSI_A, .command).displayName(keys: french) == "⌘Q")
        #expect(chord(kVK_ANSI_Semicolon, .control).displayName(keys: french) == "⌃M")
        #expect(KeyNames.name(for: UInt16(kVK_ANSI_Keypad5), keys: us) == "Keypad 5")
    }

    @Test func aLayoutThatGivesNothingFallsBackToUSAndThenTheKeyCode() {
        #expect(chord(kVK_ANSI_K, .command).displayName(keys: EmptyLayout()) == "⌘K")
        #expect(KeyNames.name(for: 0x7F, keys: EmptyLayout()) == "Key 127")
    }

    @Test @MainActor func theCurrentLayoutNamesTheLetterKeys() {
        // Whatever the Mac's layout is, a letter key types a letter on it.
        let name = KeyNames.name(for: UInt16(kVK_ANSI_K), keys: CurrentKeyboardLayout())
        #expect(name.count == 1)
        #expect(name.first?.isLetter == true)
    }
}

@Suite struct KeyChordRuleTests {
    @Test(arguments: [
        chord(kVK_Space, .command),
        chord(kVK_Space, [.option, .shift]),
        chord(kVK_Space, .option),
        chord(kVK_ANSI_K, [.command, .shift]),
        chord(kVK_ANSI_A, [.control, .option]),
        chord(kVK_F5, []),
        chord(kVK_F13, .shift),
        chord(kVK_UpArrow, [.option, .shift]),
        chord(kVK_Return, [.command, .control]),
    ])
    func chordsThatWork(_ chord: KeyChord) {
        #expect(KeyChordRules.rejection(for: chord, keys: us) == nil)
    }

    @Test func aKeyOnItsOwnNeedsAModifierUnlessItIsAFunctionKey() throws {
        let letter = try #require(KeyChordRules.rejection(for: chord(kVK_ANSI_A, []), keys: us))
        #expect(letter.contains("A on its own"))
        #expect(KeyChordRules.rejection(for: chord(kVK_Space, []), keys: us) != nil)
        #expect(KeyChordRules.rejection(for: chord(kVK_F1, []), keys: us) == nil)
    }

    @Test func shiftOrOptionAloneTypeACharacter() throws {
        let shifted = try #require(KeyChordRules.rejection(for: chord(kVK_ANSI_A, .shift), keys: us))
        #expect(shifted.hasPrefix("⇧A only types a character"))
        let accented = try #require(KeyChordRules.rejection(for: chord(kVK_ANSI_E, .option), keys: us))
        #expect(accented.hasPrefix("⌥E types a character"))
        #expect(KeyChordRules.rejection(for: chord(kVK_ANSI_E, [.option, .shift]), keys: us) != nil)
        #expect(KeyChordRules.rejection(for: chord(kVK_Space, .shift), keys: us) != nil)
    }

    struct MenuCase: Sendable, CustomTestStringConvertible {
        let key: Int
        let modifiers: KeyChord.Modifiers
        let title: String
        var testDescription: String { title }
    }

    @Test(arguments: [
        MenuCase(key: kVK_ANSI_Comma, modifiers: .command, title: "Settings"),
        MenuCase(key: kVK_ANSI_W, modifiers: .command, title: "Close"),
        MenuCase(key: kVK_ANSI_Q, modifiers: .command, title: "Quit"),
        MenuCase(key: kVK_ANSI_Z, modifiers: .command, title: "Undo"),
        MenuCase(key: kVK_ANSI_Z, modifiers: [.command, .shift], title: "Redo"),
        MenuCase(key: kVK_ANSI_C, modifiers: .command, title: "Copy"),
        MenuCase(key: kVK_ANSI_V, modifiers: [.command, .option, .shift], title: "Paste and Match Style"),
        MenuCase(key: kVK_ANSI_A, modifiers: .command, title: "Select All"),
        MenuCase(key: kVK_ANSI_Semicolon, modifiers: [.command, .shift], title: "Show Spelling and Grammar"),
        MenuCase(key: kVK_ANSI_Semicolon, modifiers: .command, title: "Check Document Now"),
    ])
    func theAppsOwnMenuShortcutsAreTaken(_ menu: MenuCase) throws {
        let reason = try #require(KeyChordRules.rejection(for: chord(menu.key, menu.modifiers), keys: us))
        #expect(reason.contains("is \(menu.title) in this app's menu"))
    }

    @Test func menuShortcutsFollowTheLayout() throws {
        // On AZERTY, Command-W is the key US calls Z, and the US W key is Command-Z, Undo.
        let close = try #require(KeyChordRules.rejection(for: chord(kVK_ANSI_Z, .command), keys: french))
        #expect(close == "⌘W is Close in this app's menu. Choose another.")
        let undo = try #require(KeyChordRules.rejection(for: chord(kVK_ANSI_W, .command), keys: french))
        #expect(undo.contains("Undo"))
        // The M key types a comma there, so Command-M is Settings.
        #expect(KeyChordRules.rejection(for: chord(kVK_ANSI_M, .command), keys: french)?.contains("Settings") == true)
    }

    @Test func shortcutsEveryAppUsesAndMacOSKeepsAreTaken() throws {
        #expect(try #require(KeyChordRules.rejection(for: chord(kVK_ANSI_S, .command), keys: us)).contains("Save in most apps"))
        #expect(try #require(KeyChordRules.rejection(for: chord(kVK_Tab, .command), keys: us)).contains("switches apps"))
        #expect(try #require(KeyChordRules.rejection(for: chord(kVK_Escape, [.command, .option]), keys: us)).contains("Force Quit"))
        #expect(try #require(KeyChordRules.rejection(for: chord(kVK_ANSI_Q, [.command, .control]), keys: us)).contains("locks the screen"))
    }

    @Test func aModifierKeyAloneIsNotAChord() {
        #expect(KeyChordRules.rejection(for: chord(kVK_Command, .command), keys: us) != nil)
    }
}

@Suite struct SystemShortcutConflictTests {
    private let spotlightOn = SystemShortcut(keyCode: UInt16(kVK_Space), carbonModifiers: UInt32(cmdKey), isEnabled: true)
    private let spotlightOff = SystemShortcut(keyCode: UInt16(kVK_Space), carbonModifiers: UInt32(cmdKey), isEnabled: false)

    @Test func anEnabledSystemShortcutWarns() throws {
        let warning = try #require(SystemShortcut.conflict(for: chord(kVK_Space, .command), in: [spotlightOn], keys: us))
        #expect(warning.contains("⌘Space"))
        #expect(warning.contains("Spotlight"))
        #expect(warning.contains("System Settings, Keyboard, Keyboard Shortcuts"))
    }

    @Test func aDisabledOneOrADifferentChordDoesNot() {
        #expect(SystemShortcut.conflict(for: chord(kVK_Space, .command), in: [spotlightOff], keys: us) == nil)
        #expect(SystemShortcut.conflict(for: chord(kVK_Space, [.command, .shift]), in: [spotlightOn], keys: us) == nil)
    }

    @Test func extraBitsInTheEntryAreIgnoredAndUnknownOwnersAreNotNamed() throws {
        // Bit 0x800000 marks a function key in some entries. It is not a modifier.
        let entry = SystemShortcut(keyCode: UInt16(kVK_ANSI_J), carbonModifiers: UInt32(controlKey | 0x0080_0000), isEnabled: true)
        let warning = try #require(SystemShortcut.conflict(for: chord(kVK_ANSI_J, .control), in: [entry], keys: us))
        #expect(warning.hasPrefix("macOS has ⌃J turned on as a system shortcut and"))
    }

    @Test func theSystemListReadsWithoutChangingAnything() {
        // Every Mac has some symbolic hot keys, such as the screenshot ones.
        #expect(!SystemShortcut.current().isEmpty)
    }
}
