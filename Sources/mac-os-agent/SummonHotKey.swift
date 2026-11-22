import AppKit
import Carbon.HIToolbox
import MacOSAgentCore

/// Holds one system-wide hotkey. A protocol, so tests and previews use one that never
/// registers anything and cannot collide with the installed app's hotkey.
@MainActor
protocol HotKeyRegistrar: AnyObject {
    /// Registers the chord in place of any held now. Returns `noErr` or the Carbon error.
    func register(_ chord: KeyChord) -> OSStatus
    func unregister()
}

/// A system-wide hotkey through Carbon's `RegisterEventHotKey`. Unlike an event tap or a
/// global event monitor, it needs no Accessibility or Input Monitoring permission.
///
/// It registers with `kEventHotKeyExclusive`, so a chord another app holds exclusively fails
/// with `eventHotKeyExistsErr` instead of going to both apps. Carbon does not report a chord
/// that one of macOS's own shortcuts uses. `SummonTriggerController` checks for that.
@MainActor
final class CarbonHotKey: HotKeyRegistrar {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    func register(_ chord: KeyChord) -> OSStatus {
        unregister()
        installHandlerIfNeeded()
        let id = EventHotKeyID(signature: OSType(0x6D_6F_61_67), id: 1) // "moag"
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(chord.keyCode), chord.modifiers.carbonFlags, id, GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &reference)
        if status == noErr { hotKey = reference }
        return status
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let hotKey = Unmanaged<CarbonHotKey>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &eventType, context, &handler)
    }
}

/// A registrar that only remembers what it was asked, for tests and previews.
@MainActor
final class StandInHotKey: HotKeyRegistrar {
    private(set) var registered: KeyChord?
    /// Chords that fail as if another app held them.
    var taken: Set<KeyChord> = []

    func register(_ chord: KeyChord) -> OSStatus {
        unregister()
        if taken.contains(chord) { return OSStatus(eventHotKeyExistsErr) }
        registered = chord
        return noErr
    }

    func unregister() { registered = nil }
}
