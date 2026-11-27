import AppKit

/// A panel that draws as it does with keyboard focus, whether or not it has focus, so it looks
/// the same when the owner clicks another app (MAC-88). The panel and the inspector beside it
/// are these.
///
/// Liquid Glass reads whether its window has the active look from the window, not from
/// SwiftUI's environment. In a window without it, the glass drops the tint to a gray, flattens
/// its highlight and edge, and loses its shadow, so a tinted theme such as Ember changes color
/// all over. AppKit has no public way to hold a window's active look, so this answers AppKit's
/// own question, `_hasActiveAppearanceIgnoringKeyFocus`, with yes. It is the narrowest of the
/// window's answers that the glass follows. It leaves keyboard focus alone: `isKeyWindow`, the
/// text field's caret, and SwiftUI's `appearsActive` still follow real focus, and the panel
/// sets `appearsActive` itself in `themedPanel`.
///
/// The name is AppKit's private one. If a later macOS drops it, nothing breaks: the method is
/// never called and the glass goes back to changing on blur. `ActiveAppearancePanelTests`
/// checks that NSWindow still has it and that the glass still follows it.
class ActiveAppearancePanel: NSPanel {
    static let activeAppearanceSelector = "_hasActiveAppearanceIgnoringKeyFocus"

    @objc(_hasActiveAppearanceIgnoringKeyFocus)
    func hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
}
