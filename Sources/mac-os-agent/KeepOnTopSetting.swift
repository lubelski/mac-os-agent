import AppKit
import MacOSAgentCore

/// Keep on Top: whether the summoned panels stay above other apps' windows when they do not
/// have focus. Off by default. It is one setting for every layout preset and for both the
/// main panel and the incognito window, and only the main panel's top bar menu changes it.
/// The app's own windows, such as Settings, still come in front of a panel kept on top. See
/// `PanelLayering`.
///
/// The incognito window follows it and never writes it. It says only "keep panels on top", so
/// it is not a trace of an incognito conversation.
@MainActor
final class KeepOnTopSetting {
    static let key = "SummonPanelKeepsOnTop"
    /// Posted when the setting changes, with the setting as the object.
    static let didChange = Notification.Name("KeepOnTopSettingDidChange")

    /// The one the app uses, kept in the standard preferences.
    static let shared = KeepOnTopSetting(defaults: .standard)

    /// Where it is kept. Nil keeps it in memory only, for previews and tests.
    private let defaults: UserDefaults?
    private(set) var isOn: Bool

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        isOn = defaults?.bool(forKey: Self.key) ?? false
    }

    func set(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        defaults?.set(on, forKey: Self.key)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
