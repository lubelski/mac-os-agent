import AppKit

/// The app's main menu. The app has no Dock icon, so the menu bar never shows it, but its key
/// equivalents still work while one of the app's windows has keyboard focus, the summon panel
/// included: AppKit sends every Command key press through the main menu even while the app is
/// not the active app, which it never is while the panel is in front.
///
/// Text views have no key bindings of their own for Command-A, Command-C, Command-Z, and the
/// like. Those reach them only as menu items with no target, whose action travels the
/// responder chain to whatever has focus: the text field, selectable text in the history, or a
/// field in Settings. So the Edit menu here is the standard one, with the standard actions.
@MainActor
enum MainMenu {
    static func install() {
        NSApp.mainMenu = make()
    }

    static func make() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu: appMenu())
        main.addItem(submenu: editMenu())
        main.addItem(submenu: taskMenu())
        main.addItem(submenu: windowMenu())
        return main
    }

    static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "mac-os-agent")
        menu.addItem(withTitle: "Settings…", action: Selector(("openSettings:")), keyEquivalent: ",")
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        NSApplication.shared.servicesMenu = services
        menu.addItem(submenu: services)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide mac-os-agent", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        menu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit mac-os-agent", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    /// The Edit menu of a new AppKit app, without Find, which a short text field has no use
    /// for. AppKit adds AutoFill, Writing Tools, Start Dictation, and Emoji & Symbols to a menu
    /// titled Edit on its own.
    static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
            .keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
            .keyEquivalentModifierMask = [.command, .option, .shift]
        menu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        menu.addItem(submenu: spellingMenu())
        menu.addItem(submenu: substitutionsMenu())
        menu.addItem(submenu: transformationsMenu())
        menu.addItem(submenu: speechMenu())
        return menu
    }

    /// Stops the task of the window in front: the main panel's, or the incognito window's own.
    /// Each window answers it through the responder chain, and the item is enabled only while
    /// that window's task runs, so with no task, or with Settings in front, it does nothing.
    static let stopTaskAction = Selector(("stopTask:"))

    /// Command-Period, the standard Mac shortcut for cancelling what is under way. While no task
    /// runs the item is disabled, and a disabled item still takes its key equivalent, so the
    /// press never reaches the window as Escape, which would hide the panel.
    static func taskMenu() -> NSMenu {
        let menu = NSMenu(title: "Task")
        menu.addItem(withTitle: "Stop", action: stopTaskAction, keyEquivalent: ".")
        return menu
    }

    /// Whether a key press is Command-Period, with no other modifier.
    static func isStopShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        return event.type == .keyDown && flags == .command && event.charactersIgnoringModifiers == "."
    }

    static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        return menu
    }

    private static func spellingMenu() -> NSMenu {
        let menu = NSMenu(title: "Spelling and Grammar")
        menu.addItem(withTitle: "Show Spelling and Grammar", action: #selector(NSText.showGuessPanel(_:)), keyEquivalent: ":")
        menu.addItem(withTitle: "Check Document Now", action: #selector(NSText.checkSpelling(_:)), keyEquivalent: ";")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Check Spelling While Typing", action: #selector(NSTextView.toggleContinuousSpellChecking(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Check Grammar With Spelling", action: #selector(NSTextView.toggleGrammarChecking(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Correct Spelling Automatically", action: #selector(NSTextView.toggleAutomaticSpellingCorrection(_:)), keyEquivalent: "")
        return menu
    }

    private static func substitutionsMenu() -> NSMenu {
        let menu = NSMenu(title: "Substitutions")
        menu.addItem(withTitle: "Show Substitutions", action: #selector(NSTextView.orderFrontSubstitutionsPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Smart Copy/Paste", action: #selector(NSTextView.toggleSmartInsertDelete(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Smart Quotes", action: #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Smart Dashes", action: #selector(NSTextView.toggleAutomaticDashSubstitution(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Smart Links", action: #selector(NSTextView.toggleAutomaticLinkDetection(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Data Detectors", action: #selector(NSTextView.toggleAutomaticDataDetection(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Text Replacement", action: #selector(NSTextView.toggleAutomaticTextReplacement(_:)), keyEquivalent: "")
        return menu
    }

    private static func transformationsMenu() -> NSMenu {
        let menu = NSMenu(title: "Transformations")
        menu.addItem(withTitle: "Make Upper Case", action: #selector(NSResponder.uppercaseWord(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Make Lower Case", action: #selector(NSResponder.lowercaseWord(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Capitalize", action: #selector(NSResponder.capitalizeWord(_:)), keyEquivalent: "")
        return menu
    }

    private static func speechMenu() -> NSMenu {
        let menu = NSMenu(title: "Speech")
        menu.addItem(withTitle: "Start Speaking", action: #selector(NSTextView.startSpeaking(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Stop Speaking", action: #selector(NSTextView.stopSpeaking(_:)), keyEquivalent: "")
        return menu
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
