import Foundation

/// A list in Reminders.
public struct ReminderList: Sendable, Equatable {
    public var id: String
    public var title: String
    /// The account it belongs to, such as iCloud.
    public var account: String?
    public var isDefault: Bool
    public var allowsChanges: Bool

    public init(id: String, title: String, account: String? = nil, isDefault: Bool = false, allowsChanges: Bool = true) {
        self.id = id
        self.title = title
        self.account = account
        self.isDefault = isDefault
        self.allowsChanges = allowsChanges
    }

    var named: NamedCollection {
        NamedCollection(id: id, title: title, account: account, isDefault: isDefault, allowsChanges: allowsChanges)
    }
}

/// When a reminder is due: on a day, or at a moment.
public enum ReminderDue: Sendable, Equatable {
    case day(CalendarDay)
    case moment(Date)
}

/// A reminder as the tools see it.
public struct Reminder: Sendable, Equatable {
    /// EventKit's identifier. Empty for a reminder that has not been saved yet.
    public var identifier: String
    public var title: String
    public var notes: String?
    public var listID: String
    public var due: ReminderDue?
    /// 0 for none, 1 to 4 for high, 5 for medium, 6 to 9 for low, as in RFC 5545.
    public var priority: Int
    public var isCompleted: Bool
    public var completionDate: Date?

    public init(
        identifier: String, title: String, notes: String? = nil, listID: String, due: ReminderDue? = nil,
        priority: Int = 0, isCompleted: Bool = false, completionDate: Date? = nil
    ) {
        self.identifier = identifier
        self.title = title
        self.notes = notes
        self.listID = listID
        self.due = due
        self.priority = priority
        self.isCompleted = isCompleted
        self.completionDate = completionDate
    }
}

/// Which reminders to read.
public enum ReminderStatusFilter: String, Sendable, CaseIterable {
    case incomplete
    case completed
    case all
}

/// Everything the reminder tools need from Reminders, so the tools can be tested without
/// touching the owner's real reminders.
public protocol ReminderStore: PrivacyAccessGate {
    func reminderLists() async throws -> [ReminderList]
    /// Reminders in the lists, or in every list when `listIDs` is nil.
    func reminders(inLists listIDs: [String]?, status: ReminderStatusFilter) async throws -> [Reminder]
    func reminder(identifier: String) async throws -> Reminder?
    /// Saves a new reminder when its identifier is empty, or changes the one it names.
    /// - Parameter dueChanged: True when the due date was set or changed, so the alert that
    ///   goes with a due time is set again.
    func save(_ reminder: Reminder, dueChanged: Bool) async throws -> Reminder
    func deleteReminder(identifier: String) async throws
}
