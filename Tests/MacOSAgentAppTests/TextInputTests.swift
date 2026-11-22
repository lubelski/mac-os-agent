import AppKit
import MacOSAgentCore
import SwiftUI
import Testing
@testable import mac_os_agent

/// Drives the real panel's text field and history through AppKit's own machinery: the main
/// menu, the responder chain, the key bindings, and the text editor.
///
/// The panel is never put on screen, so these tests never take keyboard focus from the owner.
/// That also means it is never the key window, so a menu item cannot find its target the way
/// it does in the running app. Each test sends the menu item's action up the responder chain
/// from the panel's focused view instead, which is the route AppKit takes in the app.
/// Nothing here touches the general pasteboard.
@MainActor
@Suite(.serialized) struct TextInputTests {
    init() { _ = NSApplication.shared }

    // MARK: - The main menu

    struct Shortcut: Sendable, CustomTestStringConvertible {
        let key: String
        let modifiers: NSEvent.ModifierFlags
        let action: String
        var testDescription: String { action }
    }

    @Test(arguments: [
        Shortcut(key: "a", modifiers: .command, action: "selectAll:"),
        Shortcut(key: "c", modifiers: .command, action: "copy:"),
        Shortcut(key: "x", modifiers: .command, action: "cut:"),
        Shortcut(key: "v", modifiers: .command, action: "paste:"),
        Shortcut(key: "z", modifiers: .command, action: "undo:"),
        Shortcut(key: "z", modifiers: [.command, .shift], action: "redo:"),
        Shortcut(key: "v", modifiers: [.command, .shift, .option], action: "pasteAsPlainText:"),
        Shortcut(key: ":", modifiers: .command, action: "showGuessPanel:"),
        Shortcut(key: ";", modifiers: .command, action: "checkSpelling:"),
        Shortcut(key: ",", modifiers: .command, action: "openSettings:"),
        Shortcut(key: "w", modifiers: .command, action: "performClose:"),
        Shortcut(key: "h", modifiers: .command, action: "hide:"),
        Shortcut(key: "q", modifiers: .command, action: "terminate:"),
    ])
    func theMainMenuHasTheStandardShortcut(_ shortcut: Shortcut) throws {
        let item = try #require(Self.item(in: MainMenu.make(), key: shortcut.key, modifiers: shortcut.modifiers))
        #expect(item.action == Selector((shortcut.action)))
        // No target, so the action goes to whatever has focus.
        #expect(item.target == nil)
    }

    @Test func theEditMenuHasTheTextSystemsSubmenus() throws {
        let titles = MainMenu.editMenu().items.compactMap { $0.submenu?.title }
        #expect(titles == ["Spelling and Grammar", "Substitutions", "Transformations", "Speech"])
    }

    /// AppKit hands every Command key press to the main menu, even while the app is not active,
    /// which it never is while the panel has focus. This is the step that had nothing to reach.
    @Test func theApplicationSendsCommandKeysToTheMainMenuWhileInactive() {
        let target = ActionRecorder()
        let menu = NSMenu()
        let item = NSMenuItem(title: "Probe", action: #selector(ActionRecorder.record(_:)), keyEquivalent: "a")
        item.target = target
        let top = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        top.submenu = NSMenu(title: "Edit")
        top.submenu?.addItem(item)
        menu.addItem(top)

        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous }
        NSApp.mainMenu = menu
        #expect(!NSApp.isActive)
        NSApp.sendEvent(Self.key("a", code: 0, [.command]))
        #expect(target.count == 1)
    }

    /// Without the menu, a text view does nothing with Command-A on its own.
    @Test func aTextViewHasNoBindingOfItsOwnForCommandA() throws {
        let harness = try PanelHarness(draft: "hello world")
        harness.editor.setSelectedRange(NSRange(location: 5, length: 0))
        harness.editor.interpretKeyEvents([Self.key("a", code: 0, [.command])])
        #expect(harness.editor.selectedRange() == NSRange(location: 5, length: 0))
    }

    // MARK: - The text field

    @Test func theFieldIsAPlainTextViewWithFocusWhenThePanelOpens() throws {
        let harness = try PanelHarness(draft: "")
        #expect(harness.focusedOnItsOwn)
        #expect(!harness.editor.isFieldEditor)
        #expect(!harness.editor.isRichText)
        #expect(harness.editor.allowsUndo)
        #expect(harness.editor.isEditable)
        #expect(harness.editor.isContinuousSpellCheckingEnabled)
        // Substitutions start from the owner's settings in System Settings > Keyboard.
        #expect(harness.editor.isAutomaticTextReplacementEnabled == NSSpellChecker.isAutomaticTextReplacementEnabled)
        #expect(harness.editor.isAutomaticSpellingCorrectionEnabled == NSSpellChecker.isAutomaticSpellingCorrectionEnabled)
        #expect(harness.editor.isAutomaticQuoteSubstitutionEnabled == NSSpellChecker.isAutomaticQuoteSubstitutionEnabled)
        #expect(harness.editor.isAutomaticDashSubstitutionEnabled == NSSpellChecker.isAutomaticDashSubstitutionEnabled)
    }

    @Test func selectAllFromTheMenuSelectsTheWholeDraft() throws {
        let harness = try PanelHarness(draft: "change the wallpaper\nto a sunset")
        harness.editor.setSelectedRange(NSRange(location: 3, length: 0))
        try harness.perform(menuShortcut: "a", [.command])
        #expect(harness.editor.selectedRange() == NSRange(location: 0, length: harness.editor.string.utf16.count))
    }

    @Test func theEditCommandsGoToTheTextFieldAndAreEnabled() throws {
        let harness = try PanelHarness(draft: "some text")
        harness.editor.selectAll(nil)
        // Paste is left out: whether it is enabled depends on what is on the owner's clipboard.
        let shortcuts: [(String, NSEvent.ModifierFlags)] = [("c", .command), ("x", .command), ("a", .command), (":", .command), (";", .command)]
        for (key, modifiers) in shortcuts {
            let item = try #require(Self.item(in: MainMenu.make(), key: key, modifiers: modifiers))
            let responder = try #require(harness.responder(for: item.action!))
            #expect(responder === harness.editor, "\(item.title) goes to the text field")
            #expect(harness.editor.validateUserInterfaceItem(item), "\(item.title) is enabled")
        }
        for title in ["Paste", "Paste and Match Style", "Delete", "Check Spelling While Typing", "Smart Quotes", "Text Replacement", "Make Upper Case", "Start Speaking"] {
            let item = try #require(Self.item(in: MainMenu.make(), title: title))
            #expect(harness.responder(for: item.action!) === harness.editor, "\(title) goes to the text field")
        }
    }

    @Test func undoAndRedoReachTheTextAndTheDraft() async throws {
        let harness = try PanelHarness(draft: "")
        harness.type("delete zoom")
        await harness.settle()
        #expect(harness.session.draft == "delete zoom")

        try harness.perform(menuShortcut: "z", [.command])
        await harness.settle()
        #expect(harness.editor.string == "")
        #expect(harness.session.draft == "", "the text sent on Return is the text on screen")

        try harness.perform(menuShortcut: "z", [.command, .shift])
        await harness.settle()
        #expect(harness.editor.string == "delete zoom")
        #expect(harness.session.draft == "delete zoom")
    }

    @Test func clearingTheDraftClearsTheFieldAndItsUndo() async throws {
        let harness = try PanelHarness(draft: "")
        harness.type("delete zoom")
        await harness.settle()
        harness.session.draft = ""
        await harness.settle()
        #expect(harness.editor.string == "")
        #expect(harness.editor.undoManager?.canUndo == false)
    }

    @Test func pastingSeveralLinesKeepsTheLineBreaks() async throws {
        let harness = try PanelHarness(draft: "")
        // A private pasteboard, through the same reading path Paste uses.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("mac-os-agent-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("first line\nsecond line\n\nfourth line", forType: .string)
        #expect(harness.editor.readSelection(from: pasteboard))
        await harness.settle()
        #expect(harness.session.draft == "first line\nsecond line\n\nfourth line")
    }

    @Test func theKeyBindingsMoveAndEditAsInAnyTextView() async throws {
        let harness = try PanelHarness(draft: "")
        harness.type("one two three")

        harness.press("a", code: 0, [.control]) // beginning of the line
        #expect(harness.editor.selectedRange() == NSRange(location: 0, length: 0))
        harness.press("e", code: 14, [.control]) // end of the line
        #expect(harness.editor.selectedRange() == NSRange(location: 13, length: 0))
        harness.press("\u{F702}", code: 123, [.option, .function, .numericPad]) // one word left
        #expect(harness.editor.selectedRange() == NSRange(location: 8, length: 0))
        harness.press("\u{F702}", code: 123, [.option, .shift, .function, .numericPad]) // select a word left
        #expect(harness.editor.selectedRange() == NSRange(location: 4, length: 4))
        harness.press("\u{F702}", code: 123, [.command, .function, .numericPad]) // start of the line
        #expect(harness.editor.selectedRange() == NSRange(location: 0, length: 0))
        harness.press("\u{F703}", code: 124, [.shift, .function, .numericPad]) // extend the selection
        #expect(harness.editor.selectedRange() == NSRange(location: 0, length: 1))
        harness.press("a", code: 0, [.control])
        harness.press("k", code: 40, [.control]) // delete to the end of the line
        await harness.settle()
        #expect(harness.session.draft == "")
    }

    // MARK: - Return, Shift-Return, and Option-Return

    @Test func returnSendsAndAddsNoLine() async throws {
        let harness = try PanelHarness(draft: "", fieldOnly: true)
        harness.type("first")
        harness.press("\r", code: 36, [])
        await harness.settle()
        #expect(harness.submits == 1)
        #expect(harness.session.draft == "first")
    }

    @Test(arguments: [NSEvent.ModifierFlags.shift, .option, .control])
    func aModifiedReturnAddsALineAndDoesNotSend(_ modifier: NSEvent.ModifierFlags) async throws {
        let harness = try PanelHarness(draft: "", fieldOnly: true)
        harness.type("first")
        harness.press("\r", code: 36, [modifier])
        harness.type("second")
        await harness.settle()
        #expect(harness.session.draft == "first\nsecond")
        #expect(harness.submits == 0)
    }

    @Test func escapeHidesThePanel() async throws {
        let harness = try PanelHarness(draft: "", fieldOnly: true)
        harness.type("half a thought")
        harness.press("\u{1B}", code: 53, [])
        #expect(harness.cancels == 1)
        #expect(harness.session.draft == "half a thought", "hiding keeps the draft")
    }

    @Test func aComposingInputMethodGetsReturnAndEscape() {
        for selector in [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.insertLineBreak(_:))] {
            #expect(InputCommand(selector, modifiers: [], composing: true) == .standard)
            #expect(InputCommand(selector, modifiers: .shift, composing: true) == .standard)
        }
    }

    @Test func returnWhileComposingIsNotASend() async throws {
        let harness = try PanelHarness(draft: "", fieldOnly: true)
        harness.editor.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(harness.editor.hasMarkedText())
        // What the text view asks its delegate when a Return reaches it during composition.
        _ = harness.editor.delegate?.textView?(harness.editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(harness.submits == 0)
    }

    @Test func theCommandsMapAsDocumented() {
        #expect(InputCommand(#selector(NSResponder.insertNewline(_:)), modifiers: [], composing: false) == .send)
        #expect(InputCommand(#selector(NSResponder.insertNewline(_:)), modifiers: .shift, composing: false) == .newLine)
        #expect(InputCommand(#selector(NSResponder.insertLineBreak(_:)), modifiers: .control, composing: false) == .newLine)
        #expect(InputCommand(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), modifiers: .option, composing: false) == .standard)
        #expect(InputCommand(#selector(NSResponder.cancelOperation(_:)), modifiers: [], composing: false) == .cancel)
        #expect(InputCommand(#selector(NSResponder.moveLeft(_:)), modifiers: [], composing: false) == .standard)
    }

    // MARK: - Growing with the text

    @Test func theFieldGrowsWithItsLinesUpToTheLimitAndShrinksWhenCleared() async throws {
        let harness = try PanelHarness(draft: "one line")
        let oneLine = await harness.fieldHeight()
        #expect(oneLine == InputField.rowHeight)

        harness.session.draft = "one\ntwo\nthree"
        let threeLines = await harness.fieldHeight()
        #expect(abs(threeLines - (InputField.lineHeight * 3 + InputField.verticalInset * 2)) <= 1)

        harness.session.draft = "a trailing new line\n"
        let withTrailingLine = await harness.fieldHeight()
        #expect(withTrailingLine > oneLine, "the empty line the caret sits on counts")

        let limit = InputField.maximumLines
        harness.session.draft = (1...limit).map(String.init).joined(separator: "\n")
        let atTheLimit = await harness.fieldHeight()
        harness.session.draft = (1...(limit * 3)).map(String.init).joined(separator: "\n")
        let pastTheLimit = await harness.fieldHeight()
        #expect(atTheLimit > threeLines)
        #expect(abs(pastTheLimit - atTheLimit) < 1, "past the limit the field scrolls instead of growing")

        harness.session.draft = String(repeating: "a long line that wraps ", count: 12)
        let wrapped = await harness.fieldHeight()
        #expect(wrapped > oneLine, "a long line wraps instead of scrolling sideways")

        harness.session.draft = ""
        let cleared = await harness.fieldHeight()
        #expect(cleared == oneLine)
    }

    @Test func theHistoryGivesUpTheSpaceTheFieldTakes() async throws {
        let harness = try PanelHarness(draft: "one line")
        let historyBefore = await harness.historyHeight()
        let fieldBefore = await harness.fieldHeight()
        harness.session.draft = "one\ntwo\nthree\nfour"
        let fieldAfter = await harness.fieldHeight()
        let historyAfter = await harness.historyHeight()
        #expect(fieldAfter > fieldBefore)
        #expect(abs((historyBefore - historyAfter) - (fieldAfter - fieldBefore)) < 1)
    }

    // MARK: - Selectable text in the history

    @Test func selectedTextInTheHistoryTakesCopyAndSelectAll() async throws {
        let harness = try PanelHarness(draft: "", preview: "finished")
        let texts = harness.views(named: "AppKitTextInteractionView")
        #expect(texts.count >= 2, "the owner's message and the reply are selectable")
        for text in texts {
            #expect(text.acceptsFirstResponder)
            #expect(text.responds(to: #selector(NSText.copy(_:))))
            #expect(text.responds(to: #selector(NSText.selectAll(_:))))
        }
        let first = try #require(texts.first)
        #expect(harness.panel.makeFirstResponder(first))
        for (key, modifiers) in [("c", NSEvent.ModifierFlags.command), ("a", [.command])] {
            let item = try #require(Self.item(in: MainMenu.make(), key: key, modifiers: modifiers))
            #expect(harness.responder(for: item.action!) === first, "\(item.title) goes to the selected text")
        }
    }

    // MARK: - Helpers

    static func item(in menu: NSMenu, key: String, modifiers: NSEvent.ModifierFlags) -> NSMenuItem? {
        for item in menu.items {
            if let submenu = item.submenu, let found = Self.item(in: submenu, key: key, modifiers: modifiers) {
                return found
            }
            // AppKit reads an uppercase key equivalent as needing Shift.
            var itemModifiers = item.keyEquivalentModifierMask
            var itemKey = item.keyEquivalent
            if itemKey != itemKey.lowercased() {
                itemModifiers.insert(.shift)
                itemKey = itemKey.lowercased()
            }
            if itemKey == key, itemModifiers == modifiers { return item }
        }
        return nil
    }

    static func item(in menu: NSMenu, title: String) -> NSMenuItem? {
        for item in menu.items {
            if item.title == title, item.action != nil { return item }
            if let submenu = item.submenu, let found = Self.item(in: submenu, title: title) { return found }
        }
        return nil
    }

    static func key(_ characters: String, code: UInt16, _ modifiers: NSEvent.ModifierFlags, window: NSWindow? = nil) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }
}

/// The real panel and its SwiftUI content, laid out but never shown, with the text field's
/// editor as the first responder.
@MainActor
struct PanelHarness {
    let session: AgentSession
    let panel: NSWindow
    let editor: InputTextView
    /// Whether the field had keyboard focus before the harness gave it focus.
    let focusedOnItsOwn: Bool
    private let recorder = ActionRecorder()
    private let cancelRecorder = ActionRecorder()
    var submits: Int { recorder.count }
    var cancels: Int { cancelRecorder.count }

    /// - Parameter fieldOnly: hosts the text field on its own, with its send and hide actions
    ///   counted, instead of the whole panel.
    init(draft: String, preview: String = "empty", fieldOnly: Bool = false) throws {
        try self.init(session: try #require(PanelPreview.session(named: preview)), draft: draft, fieldOnly: fieldOnly)
    }

    /// The panel over a session of the test's own.
    init(session: AgentSession, draft: String = "", fieldOnly: Bool = false) throws {
        self.session = session
        // The previews' preferences are the owner's to change from a preview. A test reads a
        // suite nothing has written, so the switches are at their defaults, unless it set its own.
        if session.preferences === SummonPanel.previewPreferences || session.preferences === UserDefaults.standard {
            session.preferences = UserDefaults(suiteName: "mac-os-agent-panel-harness-unwritten")!
        }
        session.draft = draft
        if fieldOnly {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            let recorder = recorder, cancelRecorder = cancelRecorder
            window.contentView = NSHostingView(rootView: InputField(
                text: Bindable(session).draft, placeholder: "Tell your Mac what to do", isEnabled: true, focusRequest: 1,
                onSubmit: { recorder.record(nil) }, onCancel: { cancelRecorder.record(nil) }))
            panel = window
        } else {
            panel = SummonPanel(session: session, remembersFrame: false)
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        Self.turnTheRunLoop()
        editor = try #require(Self.first(InputTextView.self, in: panel.contentView!) { _ in true })
        focusedOnItsOwn = panel.firstResponder === editor
        if !focusedOnItsOwn { panel.makeFirstResponder(editor) }
    }

    func type(_ text: String) {
        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// Sends the action of the main menu item with this shortcut the way AppKit does: to the
    /// first responder that takes it, walking up from the focused view.
    func perform(menuShortcut key: String, _ modifiers: NSEvent.ModifierFlags) throws {
        let item = try #require(TextInputTests.item(in: MainMenu.make(), key: key, modifiers: modifiers))
        let responder = try #require(responder(for: item.action!), "something in the panel takes \(item.title)")
        #expect(responder.tryToPerform(item.action!, with: item))
    }

    /// The first object in the panel's responder chain that implements the action.
    func responder(for action: Selector) -> NSResponder? {
        var responder = panel.firstResponder
        while let current = responder {
            if current.responds(to: action) { return current }
            responder = current.nextResponder
        }
        return panel.responds(to: action) ? panel : nil
    }

    /// A key press delivered to the panel, which hands it to the focused view as AppKit does.
    func press(_ characters: String, code: UInt16, _ modifiers: NSEvent.ModifierFlags) {
        panel.sendEvent(TextInputTests.key(characters, code: code, modifiers, window: panel))
    }

    /// Lets SwiftUI catch up with the editor and the session, then lays the panel out.
    func settle() async {
        for _ in 0..<3 {
            // Text views finish some edits, such as an undo, on a later turn of the run loop.
            Self.turnTheRunLoop()
            try? await Task.sleep(for: .milliseconds(10))
            panel.contentView?.layoutSubtreeIfNeeded()
        }
    }

    static func turnTheRunLoop() {
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.03))
    }

    func fieldHeight() async -> CGFloat {
        await settle()
        return editor.enclosingScrollView?.frame.height ?? 0
    }

    func historyHeight() async -> CGFloat {
        await settle()
        return Self.first(NSScrollView.self, in: panel.contentView!) { $0.documentView !== editor }?.frame.height ?? 0
    }

    func views(named className: String) -> [NSView] {
        var found: [NSView] = []
        func visit(_ view: NSView) {
            if String(describing: Swift.type(of: view)) == className { found.append(view) }
            view.subviews.forEach(visit)
        }
        visit(panel.contentView!)
        return found
    }

    static func first<T: NSView>(_ type: T.Type, in view: NSView, where matches: (T) -> Bool) -> T? {
        if let view = view as? T, matches(view) { return view }
        for subview in view.subviews {
            if let found = first(type, in: subview, where: matches) { return found }
        }
        return nil
    }
}

final class ActionRecorder: NSObject {
    private(set) var count = 0
    @objc func record(_ sender: Any?) { count += 1 }
}
