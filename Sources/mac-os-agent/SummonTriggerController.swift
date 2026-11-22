import AppKit
import Carbon.HIToolbox
import MacOSAgentCore
import Observation

/// Owns the summon trigger: what is stored, what is registered, and changing it while the app
/// runs. Settings and the menu bar menu read it, and the shortcut recorder changes it.
///
/// A change applies at once. The old hotkey is unregistered and the new one registered. When
/// the new one fails, the old one is registered again, so the owner is never left without the
/// shortcut that worked.
@MainActor
@Observable
final class SummonTriggerController {
    /// The trigger in effect, or nil when the owner removed the shortcut.
    private(set) var trigger: SummonTrigger? {
        didSet { if trigger != oldValue { onChange?() } }
    }
    /// Called after the trigger changes, so places outside SwiftUI, such as the icon's
    /// tooltip, can show the new one.
    @ObservationIgnored var onChange: (() -> Void)?
    /// Whether the trigger's hotkey is registered now. False while the recorder suspends it.
    private(set) var isRegistered = false
    /// Why the trigger in effect does not work, such as a failed registration at launch.
    private(set) var problem: String?
    private(set) var isSuspended = false

    @ObservationIgnored private let registrar: any HotKeyRegistrar
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let systemShortcuts: () -> [SystemShortcut]
    @ObservationIgnored let keys: () -> any KeyCharacterSource

    init(
        registrar: any HotKeyRegistrar, defaults: UserDefaults = .standard,
        systemShortcuts: @escaping () -> [SystemShortcut] = { SystemShortcut.current() },
        keys: @escaping () -> any KeyCharacterSource = { CurrentKeyboardLayout() }
    ) {
        self.registrar = registrar
        self.defaults = defaults
        self.systemShortcuts = systemShortcuts
        self.keys = keys
        let stored = SummonTriggerSetting.load(defaults)
        trigger = stored.trigger
        if case .unreadable = stored {
            problem = "The saved shortcut could not be read, so \(Self.name(of: .default, keys: keys())) is in use."
        }
    }

    /// Registers the stored trigger at launch. Returns a problem to record when it fails.
    @discardableResult
    func start() -> String? {
        guard let chord = trigger?.keyChord else { return problem }
        let status = registrar.register(chord)
        isRegistered = status == noErr
        if !isRegistered {
            problem = "\(displayName ?? "The shortcut") did not register (error \(status)). Another app may hold it. Click the menu bar icon to show the panel, or choose another shortcut."
        }
        return problem
    }

    func stop() {
        registrar.unregister()
        isRegistered = false
    }

    /// The shortcut as menus show it, such as `⌥⇧Space`, or nil when there is none.
    var displayName: String? { trigger.map { Self.name(of: $0, keys: keys()) } }

    /// The shortcut in words, such as "Option-Shift-Space".
    var spokenName: String? { trigger?.keyChord?.spokenName(keys: keys()) }

    var isDefault: Bool { trigger == .default }

    /// A warning when one of macOS's own shortcuts that is turned on uses the same chord.
    /// Read fresh each time, since the owner can change it in System Settings at any time.
    var systemConflict: String? {
        guard let chord = trigger?.keyChord else { return nil }
        return SystemShortcut.conflict(for: chord, in: systemShortcuts(), keys: keys())
    }

    static func name(of trigger: SummonTrigger, keys: any KeyCharacterSource) -> String {
        switch trigger {
        case .keyChord(let chord): chord.displayName(keys: keys)
        }
    }

    // MARK: - Changing it

    enum Outcome: Equatable {
        /// The trigger changed. The warning says when macOS's own shortcut uses the chord.
        case applied(warning: String?)
        /// The chord is not allowed, for the reason given. Nothing changed.
        case rejected(String)
        /// The chord did not register. The previous trigger is still in effect.
        case failed(String)
    }

    /// Lets the recorder take every key, the current shortcut included, without the panel
    /// toggling.
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        registrar.unregister()
        isRegistered = false
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        if let chord = trigger?.keyChord {
            isRegistered = registrar.register(chord) == noErr
        }
    }

    func set(_ chord: KeyChord) -> Outcome {
        let keys = keys()
        if let reason = KeyChordRules.rejection(for: chord, keys: keys) {
            return .rejected(reason)
        }
        return apply(.keyChord(chord)) { SummonTriggerSetting.save(.keyChord(chord), self.defaults) }
    }

    func clear() {
        registrar.unregister()
        isRegistered = false
        trigger = nil
        problem = nil
        SummonTriggerSetting.save(nil, defaults)
    }

    func restoreDefault() -> Outcome {
        apply(.default) { SummonTriggerSetting.restoreDefault(self.defaults) }
    }

    private func apply(_ new: SummonTrigger, save: () -> Void) -> Outcome {
        guard let chord = new.keyChord else { return .rejected("This kind of trigger is not supported yet.") }
        let keys = keys()
        if !isSuspended {
            let status = registrar.register(chord)
            if status != noErr {
                // Put the shortcut that worked back.
                if let previous = trigger?.keyChord {
                    isRegistered = registrar.register(previous) == noErr
                } else {
                    isRegistered = false
                }
                let name = chord.displayName(keys: keys)
                let fallback = displayName.map { " \($0) still works." } ?? ""
                return .failed("\(name) did not register (error \(status)). Another app may hold it.\(fallback)")
            }
            isRegistered = true
        }
        trigger = new
        problem = nil
        save()
        return .applied(warning: systemConflict)
    }
}

extension KeyChord {
    /// The chord as a menu item's key equivalent, so the menu shows it the way macOS does.
    func menuKeyEquivalent(keys: any KeyCharacterSource) -> String {
        func function(_ value: Int) -> String { String(UnicodeScalar(UInt16(value)).map(Character.init) ?? " ") }
        switch Int(keyCode) {
        case kVK_Space: return " "
        case kVK_Return: return "\r"
        case kVK_ANSI_KeypadEnter: return "\u{3}"
        case kVK_Tab: return "\t"
        case kVK_Delete: return "\u{8}"
        case kVK_Escape: return "\u{1b}"
        case kVK_ForwardDelete: return function(NSDeleteFunctionKey)
        case kVK_LeftArrow: return function(NSLeftArrowFunctionKey)
        case kVK_RightArrow: return function(NSRightArrowFunctionKey)
        case kVK_UpArrow: return function(NSUpArrowFunctionKey)
        case kVK_DownArrow: return function(NSDownArrowFunctionKey)
        case kVK_Home: return function(NSHomeFunctionKey)
        case kVK_End: return function(NSEndFunctionKey)
        case kVK_PageUp: return function(NSPageUpFunctionKey)
        case kVK_PageDown: return function(NSPageDownFunctionKey)
        case kVK_Help: return function(NSHelpFunctionKey)
        case kVK_ANSI_KeypadClear: return function(NSClearLineFunctionKey)
        default:
            if let number = KeyNames.functionKeys[Int(keyCode)] { return function(NSF1FunctionKey + number - 1) }
            return (keys.character(for: keyCode, shift: false) ?? USKeyboardLayout().character(for: keyCode, shift: false) ?? "").lowercased()
        }
    }

    var eventModifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers.rawValue) }
}
