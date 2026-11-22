import AppKit
import Carbon.HIToolbox
import MacOSAgentCore
import Testing
@testable import mac_os_agent

/// Drives the summon shortcut recorder with synthesized key events. Every test uses a stand-in
/// hotkey that never registers anything system wide, and preferences of its own, so nothing
/// here touches the installed app's hotkey or the owner's settings.
@MainActor
@Suite(.serialized) struct ShortcutRecorderTests {
    init() { _ = NSApplication.shared }

    @MainActor private struct Harness {
        let hotKey = StandInHotKey()
        let defaults: UserDefaults
        let controller: SummonTriggerController
        let recorder: ShortcutRecorderModel

        init(stored: SummonTrigger?? = .none, systemShortcuts: [SystemShortcut] = [], taken: Set<KeyChord> = []) {
            let name = "mac-os-agent-tests-\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
            if case .some(let trigger) = stored { SummonTriggerSetting.save(trigger, defaults) }
            hotKey.taken = taken
            controller = SummonTriggerController(
                registrar: hotKey, defaults: defaults, systemShortcuts: { systemShortcuts }, keys: { USKeyboardLayout() })
            controller.start()
            recorder = ShortcutRecorderModel(controller: controller)
        }
    }

    private static let optionShiftSpace = KeyChord(keyCode: UInt16(kVK_Space), modifiers: [.option, .shift])
    private static let commandSpace = KeyChord(keyCode: UInt16(kVK_Space), modifiers: .command)

    static func key(_ code: Int, _ characters: String, _ modifiers: NSEvent.ModifierFlags, type: NSEvent.EventType = .keyDown, repeating: Bool = false) -> NSEvent {
        NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: repeating, keyCode: UInt16(code))!
    }

    static func flags(_ modifiers: NSEvent.ModifierFlags, code: Int = kVK_Command) -> NSEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true)!
        event.type = .flagsChanged
        event.flags = CGEventFlags(rawValue: UInt64(modifiers.rawValue))
        return NSEvent(cgEvent: event)!
    }

    // MARK: - Launch

    @Test func aFreshInstallRegistersOptionShiftSpace() {
        let harness = Harness()
        #expect(harness.hotKey.registered == Self.optionShiftSpace)
        #expect(harness.controller.displayName == "⌥⇧Space")
        #expect(harness.controller.spokenName == "Option-Shift-Space")
        #expect(harness.recorder.label == "⌥⇧Space")
        #expect(harness.recorder.status == nil)
    }

    @Test func aStoredShortcutThatFailsAtLaunchSaysSoAndLeavesTheIcon() throws {
        let harness = Harness(stored: .keyChord(Self.commandSpace), taken: [Self.commandSpace])
        #expect(!harness.controller.isRegistered)
        let problem = try #require(harness.controller.problem)
        #expect(problem.contains("⌘Space did not register"))
        #expect(problem.contains("menu bar icon"))
        #expect(harness.recorder.status?.kind == .problem)
    }

    @Test func aClearedShortcutRegistersNothing() {
        let harness = Harness(stored: .some(nil))
        #expect(harness.hotKey.registered == nil)
        #expect(harness.recorder.label == "None")
    }

    // MARK: - Recording

    @Test func recordingSuspendsTheHotkeyAndEscapeCancels() {
        let harness = Harness()
        harness.recorder.startRecording()
        #expect(harness.recorder.isRecording)
        #expect(harness.hotKey.registered == nil)
        #expect(harness.recorder.label == "Type a shortcut")
        #expect(harness.recorder.handle(Self.key(kVK_Escape, "\u{1b}", [])) == nil)
        #expect(!harness.recorder.isRecording)
        #expect(harness.hotKey.registered == Self.optionShiftSpace)
        #expect(harness.controller.trigger == .default)
    }

    @Test func pressingTheCurrentShortcutWhileRecordingRecordsItInsteadOfTogglingThePanel() {
        let harness = Harness()
        harness.recorder.startRecording()
        // The hotkey is unregistered, so the press arrives as an ordinary key event.
        #expect(harness.hotKey.registered == nil)
        #expect(harness.recorder.handle(Self.key(kVK_Space, " ", [.option, .shift])) == nil)
        #expect(!harness.recorder.isRecording)
        #expect(harness.hotKey.registered == Self.optionShiftSpace)
    }

    @Test func commandSpaceBecomesTheShortcutAtOnce() {
        let harness = Harness()
        harness.recorder.startRecording()
        #expect(harness.recorder.handle(Self.key(kVK_Space, " ", [.command])) == nil)
        #expect(!harness.recorder.isRecording)
        #expect(harness.hotKey.registered == Self.commandSpace)
        #expect(harness.controller.trigger == .keyChord(Self.commandSpace))
        #expect(harness.recorder.label == "⌘Space")
        #expect(harness.recorder.message == nil)
        #expect(SummonTriggerSetting.load(harness.defaults) == .trigger(.keyChord(Self.commandSpace)))
    }

    @Test func heldModifiersShowWhileRecording() {
        let harness = Harness()
        harness.recorder.startRecording()
        #expect(harness.recorder.handle(Self.flags([.command, .option])) == nil)
        #expect(harness.recorder.label == "⌥⌘…")
        #expect(harness.recorder.isRecording)
        // Key up and repeats are swallowed and change nothing.
        #expect(harness.recorder.handle(Self.key(kVK_ANSI_K, "k", [.command], type: .keyUp)) == nil)
        #expect(harness.recorder.handle(Self.key(kVK_ANSI_K, "k", [.command, .option], repeating: true)) == nil)
        #expect(harness.recorder.isRecording)
    }

    @Test func aRejectedChordSaysWhyAndKeepsRecording() throws {
        let harness = Harness()
        harness.recorder.startRecording()
        #expect(harness.recorder.handle(Self.key(kVK_ANSI_A, "a", [])) == nil)
        let message = try #require(harness.recorder.message)
        #expect(message.kind == .problem)
        #expect(message.text.contains("A on its own"))
        #expect(harness.recorder.isRecording)
        #expect(harness.controller.trigger == .default)

        #expect(harness.recorder.handle(Self.key(kVK_ANSI_W, "w", [.command])) == nil)
        #expect(harness.recorder.message?.text == "⌘W is Close in this app's menu. Choose another.")
        #expect(harness.recorder.isRecording)

        // A good chord after a rejected one is taken, and the message goes.
        #expect(harness.recorder.handle(Self.key(kVK_ANSI_K, "k", [.control, .option])) == nil)
        #expect(!harness.recorder.isRecording)
        #expect(harness.recorder.message == nil)
        #expect(harness.recorder.label == "⌃⌥K")
    }

    @Test func aChordAnotherAppHoldsKeepsThePreviousShortcutWorking() throws {
        let taken = KeyChord(keyCode: UInt16(kVK_ANSI_K), modifiers: [.control, .option])
        let harness = Harness(taken: [taken])
        harness.recorder.startRecording()
        _ = harness.recorder.handle(Self.key(kVK_ANSI_K, "k", [.control, .option]))
        #expect(!harness.recorder.isRecording)
        #expect(harness.hotKey.registered == Self.optionShiftSpace)
        #expect(harness.controller.trigger == .default)
        let message = try #require(harness.recorder.message)
        #expect(message.kind == .problem)
        #expect(message.text == "⌃⌥K did not register (error \(eventHotKeyExistsErr)). Another app may hold it. ⌥⇧Space still works.")
        #expect(SummonTriggerSetting.load(harness.defaults) == .unset)
    }

    @Test func spotlightStillOnGivesAWarningButTheShortcutIsSet() throws {
        let spotlight = SystemShortcut(keyCode: UInt16(kVK_Space), carbonModifiers: UInt32(cmdKey), isEnabled: true)
        let harness = Harness(systemShortcuts: [spotlight])
        harness.recorder.startRecording()
        _ = harness.recorder.handle(Self.key(kVK_Space, " ", [.command]))
        #expect(harness.controller.trigger == .keyChord(Self.commandSpace))
        let message = try #require(harness.recorder.message)
        #expect(message.kind == .warning)
        #expect(message.text.contains("Spotlight"))
        // The warning stays after the recorder's own message is gone, until Spotlight lets go.
        harness.recorder.message = nil
        #expect(harness.recorder.status?.kind == .warning)
    }

    @Test func deleteRemovesTheShortcutAndRestoreDefaultBringsItBack() {
        let harness = Harness(stored: .keyChord(Self.commandSpace))
        harness.recorder.startRecording()
        _ = harness.recorder.handle(Self.key(kVK_Delete, "\u{7f}", []))
        #expect(!harness.recorder.isRecording)
        #expect(harness.controller.trigger == nil)
        #expect(harness.hotKey.registered == nil)
        #expect(SummonTriggerSetting.load(harness.defaults) == .cleared)

        harness.recorder.restoreDefault()
        #expect(harness.controller.trigger == .default)
        #expect(harness.hotKey.registered == Self.optionShiftSpace)
        #expect(SummonTriggerSetting.load(harness.defaults) == .unset)
    }

    @Test func theClearControlRemovesTheShortcut() {
        let harness = Harness()
        harness.recorder.clear()
        #expect(harness.controller.trigger == nil)
        #expect(harness.hotKey.registered == nil)
    }

    // MARK: - Keys do not leak

    /// The recorder's monitor takes key events before AppKit dispatches them, so a chord that
    /// is a menu shortcut records instead of running the menu item.
    @Test func keysPressedWhileRecordingNeverReachTheMenus() {
        let target = ActionRecorder()
        let menu = NSMenu()
        let item = NSMenuItem(title: "Probe", action: #selector(ActionRecorder.record(_:)), keyEquivalent: "k")
        item.keyEquivalentModifierMask = [.command, .shift]
        item.target = target
        let top = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        top.submenu = NSMenu(title: "Edit")
        top.submenu?.addItem(item)
        menu.addItem(top)
        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous }
        NSApp.mainMenu = menu

        let harness = Harness()
        harness.recorder.startRecording()
        NSApp.sendEvent(Self.key(kVK_ANSI_K, "k", [.command, .shift]))
        #expect(target.count == 0)
        #expect(harness.controller.trigger == .keyChord(KeyChord(keyCode: UInt16(kVK_ANSI_K), modifiers: [.command, .shift])))
        #expect(!harness.recorder.isRecording)

        // Once recording ends, the monitor is gone and the menu gets the key again.
        NSApp.sendEvent(Self.key(kVK_ANSI_K, "k", [.command, .shift]))
        #expect(target.count == 1)
    }

    // MARK: - The menus

    /// Every shortcut in the app's own menus is one the recorder refuses.
    @Test func everyMainMenuShortcutIsReserved() {
        func items(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) }
        }
        let reserved = ReservedShortcut.appMenu
        for item in items(MainMenu.make()) where !item.keyEquivalent.isEmpty {
            let modifiers = KeyChord.Modifiers(eventFlags: item.keyEquivalentModifierMask.rawValue)
            #expect(
                reserved.contains { $0.keyEquivalent == item.keyEquivalent && $0.modifiers == modifiers },
                "\(item.title) is missing from ReservedShortcut.appMenu")
        }
    }

    @Test func theMenuItemShowsTheChord() {
        let us = USKeyboardLayout()
        #expect(Self.commandSpace.menuKeyEquivalent(keys: us) == " ")
        #expect(Self.commandSpace.eventModifierFlags == .command)
        #expect(KeyChord(keyCode: UInt16(kVK_ANSI_K), modifiers: .control).menuKeyEquivalent(keys: us) == "k")
        let f5 = KeyChord(keyCode: UInt16(kVK_F5), modifiers: []).menuKeyEquivalent(keys: us)
        #expect(f5 == String(UnicodeScalar(UInt16(NSF5FunctionKey))!))
        let up = KeyChord(keyCode: UInt16(kVK_UpArrow), modifiers: .option).menuKeyEquivalent(keys: us)
        #expect(up == String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!))
    }
}
