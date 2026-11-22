import AppKit
import Carbon.HIToolbox

/// The key chord that summons the panel. Change it here.
///
/// Option-Shift-Space, because Option-Space already belongs to Alfred and the ChatGPT app on
/// this Mac, Command-Space to Spotlight, and Control-Space to switching input sources.
enum SummonShortcut {
    static let keyCode = UInt32(kVK_Space)
    static let carbonModifiers = UInt32(optionKey | shiftKey)
    /// The same chord for menu items.
    static let keyEquivalent = " "
    static let modifierFlags: NSEvent.ModifierFlags = [.option, .shift]
    static let displayName = "⌥⇧Space"
}

/// A system-wide hotkey through Carbon's `RegisterEventHotKey`. Unlike an event tap or a
/// global event monitor, it needs no Accessibility or Input Monitoring permission.
@MainActor
final class SummonHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    /// Registers the chord. Returns false when another app already holds it.
    @discardableResult
    func register() -> Bool {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let hotKey = Unmanaged<SummonHotKey>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &eventType, context, &handler)

        let id = EventHotKeyID(signature: OSType(0x6D_6F_61_67), id: 1) // "moag"
        let status = RegisterEventHotKey(
            SummonShortcut.keyCode, SummonShortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &hotKey)
        return status == noErr
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }
}
