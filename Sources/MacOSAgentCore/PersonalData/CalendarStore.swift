import Foundation

/// A calendar in Calendar.
public struct CalendarInfo: Sendable, Equatable {
    public var id: String
    public var title: String
    public var account: String?
    public var isDefault: Bool
    /// False for subscribed, birthday, and holiday calendars.
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

/// One occurrence of an event, as the tools see it.
public struct CalendarEvent: Sendable, Equatable {
    /// EventKit's event identifier, shared by every occurrence of a repeating event. Empty for
    /// an event that has not been saved yet.
    public var identifier: String
    /// When this occurrence was scheduled to start, which tells occurrences of a repeating event apart.
    public var occurrenceDate: Date
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var notes: String?
    public var calendarID: String
    public var isRecurring: Bool

    public init(
        identifier: String, occurrenceDate: Date? = nil, title: String, start: Date, end: Date, isAllDay: Bool = false,
        location: String? = nil, notes: String? = nil, calendarID: String, isRecurring: Bool = false
    ) {
        self.identifier = identifier
        self.occurrenceDate = occurrenceDate ?? start
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.calendarID = calendarID
        self.isRecurring = isRecurring
    }
}

/// Everything the calendar tools need from Calendar, so the tools can be tested without
/// touching the owner's real calendars.
public protocol CalendarStore: PrivacyAccessGate {
    func eventCalendars() async throws -> [CalendarInfo]
    /// Occurrences that overlap the range, with repeating events expanded, in the calendars
    /// or in every calendar when `calendarIDs` is nil.
    func events(from start: Date, to end: Date, inCalendars calendarIDs: [String]?) async throws -> [CalendarEvent]
    /// One occurrence. With no occurrence date, the event itself, or its first occurrence.
    func event(identifier: String, occurrenceDate: Date?) async throws -> CalendarEvent?
    /// Saves a new event when its identifier is empty, or changes the occurrence it names.
    /// - Parameter includingFuture: For a repeating event, also change the later occurrences.
    func save(_ event: CalendarEvent, includingFuture: Bool) async throws -> CalendarEvent
    func deleteEvent(identifier: String, occurrenceDate: Date, includingFuture: Bool) async throws
}
