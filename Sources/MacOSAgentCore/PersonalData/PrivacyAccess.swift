import Foundation

/// A kind of the owner's personal data that macOS guards with a permission of its own.
public enum PrivacyAccessKind: String, Sendable, CaseIterable, Identifiable {
    case reminders
    case calendars

    public var id: String { rawValue }

    /// The name of the pane in Privacy & Security.
    public var title: String {
        switch self {
        case .reminders: "Reminders"
        case .calendars: "Calendars"
        }
    }

    /// Where the owner turns access on, as a person would follow it.
    public var systemSettingsPath: String { "System Settings > Privacy & Security > \(title)" }

    /// Opens that pane of System Settings.
    public var systemSettingsURL: URL {
        switch self {
        case .reminders: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!
        case .calendars: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
        }
    }
}

/// Whether the app may use one kind of personal data.
public enum PrivacyAccessStatus: Sendable, Equatable {
    /// The owner has not been asked yet.
    case notDetermined
    case denied
    /// Something other than the owner, such as a management profile, does not allow it.
    case restricted
    /// The app may add items but not read them. Only calendars have this.
    case writeOnly
    case fullAccess

    /// A few words for Settings.
    public var label: String {
        switch self {
        case .notDetermined: "Not asked yet"
        case .denied: "Not allowed"
        case .restricted: "Restricted on this Mac"
        case .writeOnly: "Can add events only"
        case .fullAccess: "Allowed"
        }
    }
}

/// Reads and requests the app's access to personal data.
public protocol PrivacyAccessGate: Sendable {
    /// The access the app has now. Never shows a prompt.
    func status(_ kind: PrivacyAccessKind) -> PrivacyAccessStatus
    /// Asks the owner for full access when they have not been asked yet. Returns the access
    /// the app has afterwards.
    func requestAccess(_ kind: PrivacyAccessKind) async -> PrivacyAccessStatus
}

extension PrivacyAccessGate {
    /// Makes sure the app has full access, asking the first time. Returns nil when it does,
    /// or the text a tool returns to the model when it does not.
    func ensureFullAccess(_ kind: PrivacyAccessKind) async -> String? {
        var status = status(kind)
        if status == .notDetermined {
            status = await requestAccess(kind)
        }
        switch status {
        case .fullAccess:
            return nil
        case .notDetermined:
            return "Error: mac-os-agent asked for access to \(kind.title) and got no answer. Nothing was read or changed. Ask the owner to try again, or to allow it in \(kind.systemSettingsPath)."
        case .denied:
            return "Error: mac-os-agent is not allowed to use \(kind.title). Nothing was read or changed. The owner can allow it in \(kind.systemSettingsPath), then ask again."
        case .writeOnly:
            return "Error: mac-os-agent can add to \(kind.title) but not read it. Nothing was read or changed. The owner can give it full access in \(kind.systemSettingsPath)."
        case .restricted:
            return "Error: access to \(kind.title) is restricted on this Mac, for example by a management profile, so mac-os-agent cannot use it. Nothing was read or changed."
        }
    }
}

extension ToolSource {
    public static let reminders = ToolSource(id: "reminders", title: "Reminders")
    public static let calendar = ToolSource(id: "calendar", title: "Calendar")

    /// The personal data this source's tools need access to, if any.
    public var privacyAccess: PrivacyAccessKind? {
        switch id {
        case ToolSource.reminders.id: .reminders
        case ToolSource.calendar.id: .calendars
        default: nil
        }
    }
}
