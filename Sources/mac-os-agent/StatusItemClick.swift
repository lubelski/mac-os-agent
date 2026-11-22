import AppKit

/// What a press on the menu bar icon does.
///
/// A left click toggles the panel, the same as the hotkey. A right click or a Control-click
/// opens the menu. Anything that is not a mouse click, such as VoiceOver's press or Return
/// after Control-F8 moves the keyboard into the menu bar, opens the menu too, so the menu is
/// always reachable without a mouse. Its first item shows or hides the panel.
enum StatusItemClick: Equatable {
    case togglePanel
    case showMenu

    static func action(for event: NSEvent?) -> StatusItemClick {
        guard let event else { return .showMenu }
        switch event.type {
        case .leftMouseDown, .leftMouseUp:
            return event.modifierFlags.contains(.control) ? .showMenu : .togglePanel
        default:
            return .showMenu
        }
    }
}

@MainActor
extension NSStatusItem {
    /// Opens the menu under the icon, as if the item had it attached. The menu is attached only
    /// while it is open, so a left click on the icon reaches the button's action.
    func showMenu(_ menu: NSMenu) {
        self.menu = menu
        button?.performClick(nil)
        self.menu = nil
    }
}
