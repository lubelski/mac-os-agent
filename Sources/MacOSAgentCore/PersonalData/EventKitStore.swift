import EventKit
import Foundation

/// Reminders and Calendar through EventKit. One event store serves both, as Apple recommends,
/// and the actor keeps every use of it on one queue at a time.
///
/// Creating the store asks for nothing. The owner is asked for access the first time a tool
/// needs it, through `requestAccess`.
public actor EventKitStore: ReminderStore, CalendarStore {
    public static let shared = EventKitStore()

    private var storage: EKEventStore?

    public init() {}

    private var store: EKEventStore {
        if let storage { return storage }
        let store = EKEventStore()
        storage = store
        return store
    }

    // MARK: Access

    public nonisolated func status(_ kind: PrivacyAccessKind) -> PrivacyAccessStatus {
        Self.status(EKEventStore.authorizationStatus(for: kind.entityType))
    }

    public func requestAccess(_ kind: PrivacyAccessKind) async -> PrivacyAccessStatus {
        guard status(kind) == .notDetermined else { return status(kind) }
        do {
            switch kind {
            case .reminders: _ = try await store.requestFullAccessToReminders()
            case .calendars: _ = try await store.requestFullAccessToEvents()
            }
        } catch {
            // The status below says what happened.
        }
        // A store made before access was granted does not see the calendars until it is reset.
        store.reset()
        return status(kind)
    }

    static func status(_ status: EKAuthorizationStatus) -> PrivacyAccessStatus {
        switch status {
        case .fullAccess: .fullAccess
        case .writeOnly: .writeOnly
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    // MARK: Reminders

    public func reminderLists() async throws -> [ReminderList] {
        let defaultID = store.defaultCalendarForNewReminders()?.calendarIdentifier
        return store.calendars(for: .reminder).map { list in
            ReminderList(
                id: list.calendarIdentifier, title: list.title, account: list.source?.title,
                isDefault: list.calendarIdentifier == defaultID, allowsChanges: list.allowsContentModifications)
        }
    }

    public func reminders(inLists listIDs: [String]?, status: ReminderStatusFilter) async throws -> [Reminder] {
        let lists = try calendars(listIDs, for: .reminder)
        let predicate: NSPredicate = switch status {
        case .incomplete: store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: lists)
        case .completed: store.predicateForCompletedReminders(withCompletionDateStarting: nil, ending: nil, calendars: lists)
        case .all: store.predicateForReminders(in: lists)
        }
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).map(Self.value))
            }
        }
    }

    public func reminder(identifier: String) async throws -> Reminder? {
        (store.calendarItem(withIdentifier: identifier) as? EKReminder).map(Self.value)
    }

    public func save(_ reminder: Reminder, dueChanged: Bool) async throws -> Reminder {
        let item: EKReminder
        if reminder.identifier.isEmpty {
            item = EKReminder(eventStore: store)
        } else {
            guard let found = store.calendarItem(withIdentifier: reminder.identifier) as? EKReminder else {
                throw EventKitStoreError.missing("the reminder")
            }
            item = found
        }
        guard let list = store.calendar(withIdentifier: reminder.listID) else { throw EventKitStoreError.missing("the list") }
        item.calendar = list
        item.title = reminder.title
        item.notes = reminder.notes
        item.priority = reminder.priority
        if item.isCompleted != reminder.isCompleted { item.isCompleted = reminder.isCompleted }
        if dueChanged || reminder.identifier.isEmpty {
            item.dueDateComponents = Self.components(reminder.due)
            // Reminders alerts the owner from an alarm, not from the due date, so a due time
            // gets an alarm at that time, as the Reminders app sets one.
            for alarm in item.alarms ?? [] where alarm.absoluteDate != nil {
                item.removeAlarm(alarm)
            }
            if case .moment(let date)? = reminder.due {
                item.addAlarm(EKAlarm(absoluteDate: date))
            }
        }
        try store.save(item, commit: true)
        return Self.value(item)
    }

    public func deleteReminder(identifier: String) async throws {
        guard let item = store.calendarItem(withIdentifier: identifier) as? EKReminder else {
            throw EventKitStoreError.missing("the reminder")
        }
        try store.remove(item, commit: true)
    }

    static func value(_ reminder: EKReminder) -> Reminder {
        Reminder(
            identifier: reminder.calendarItemIdentifier, title: reminder.title ?? "",
            notes: reminder.notes, listID: reminder.calendar?.calendarIdentifier ?? "",
            due: due(reminder.dueDateComponents), priority: reminder.priority,
            isCompleted: reminder.isCompleted, completionDate: reminder.completionDate)
    }

    static func due(_ components: DateComponents?) -> ReminderDue? {
        guard let components, let year = components.year, let month = components.month, let day = components.day else { return nil }
        guard components.hour != nil else { return .day(CalendarDay(year: year, month: month, day: day)) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = components.timeZone ?? .current
        var parts = components
        parts.calendar = nil
        return calendar.date(from: parts).map { .moment($0) } ?? .day(CalendarDay(year: year, month: month, day: day))
    }

    static func components(_ due: ReminderDue?) -> DateComponents? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        switch due {
        case nil:
            return nil
        case .day(let day)?:
            var parts = DateComponents(year: day.year, month: day.month, day: day.day)
            parts.calendar = calendar
            return parts
        case .moment(let date)?:
            var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            parts.calendar = calendar
            parts.timeZone = .current
            return parts
        }
    }

    // MARK: Calendar

    public func eventCalendars() async throws -> [CalendarInfo] {
        let defaultID = store.defaultCalendarForNewEvents?.calendarIdentifier
        return store.calendars(for: .event).map { calendar in
            CalendarInfo(
                id: calendar.calendarIdentifier, title: calendar.title, account: calendar.source?.title,
                isDefault: calendar.calendarIdentifier == defaultID, allowsChanges: calendar.allowsContentModifications)
        }
    }

    public func events(from start: Date, to end: Date, inCalendars calendarIDs: [String]?) async throws -> [CalendarEvent] {
        let calendars = try calendars(calendarIDs, for: .event)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return store.events(matching: predicate).map(Self.value)
    }

    public func event(identifier: String, occurrenceDate: Date?) async throws -> CalendarEvent? {
        try ekEvent(identifier: identifier, occurrenceDate: occurrenceDate).map(Self.value)
    }

    public func save(_ event: CalendarEvent, includingFuture: Bool) async throws -> CalendarEvent {
        let item: EKEvent
        if event.identifier.isEmpty {
            item = EKEvent(eventStore: store)
        } else {
            guard let found = try ekEvent(identifier: event.identifier, occurrenceDate: event.occurrenceDate) else {
                throw EventKitStoreError.missing("the event")
            }
            item = found
        }
        guard let calendar = store.calendar(withIdentifier: event.calendarID) else { throw EventKitStoreError.missing("the calendar") }
        item.calendar = calendar
        item.title = event.title
        item.isAllDay = event.isAllDay
        item.startDate = event.start
        item.endDate = event.end
        item.location = event.location
        item.notes = event.notes
        try store.save(item, span: includingFuture ? .futureEvents : .thisEvent, commit: true)
        return Self.value(item)
    }

    public func deleteEvent(identifier: String, occurrenceDate: Date, includingFuture: Bool) async throws {
        guard let item = try ekEvent(identifier: identifier, occurrenceDate: occurrenceDate) else {
            throw EventKitStoreError.missing("the event")
        }
        try store.remove(item, span: includingFuture ? .futureEvents : .thisEvent, commit: true)
    }

    private func ekEvent(identifier: String, occurrenceDate: Date?) throws -> EKEvent? {
        guard let event = store.event(withIdentifier: identifier) else { return nil }
        guard let occurrenceDate, event.hasRecurrenceRules, abs(event.occurrenceDate.timeIntervalSince(occurrenceDate)) > 1 else {
            return event
        }
        // `event(withIdentifier:)` gives the first occurrence of a repeating event. Find the
        // one scheduled at the occurrence date among the events around it.
        let predicate = store.predicateForEvents(
            withStart: occurrenceDate.addingTimeInterval(-86_400), end: occurrenceDate.addingTimeInterval(86_400),
            calendars: [event.calendar])
        return store.events(matching: predicate).first {
            $0.eventIdentifier == identifier && abs($0.occurrenceDate.timeIntervalSince(occurrenceDate)) <= 1
        }
    }

    static func value(_ event: EKEvent) -> CalendarEvent {
        CalendarEvent(
            identifier: event.eventIdentifier ?? "", occurrenceDate: event.occurrenceDate ?? event.startDate,
            title: event.title ?? "", start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
            location: event.location, notes: event.notes, calendarID: event.calendar?.calendarIdentifier ?? "",
            isRecurring: event.hasRecurrenceRules)
    }

    private func calendars(_ ids: [String]?, for type: EKEntityType) throws -> [EKCalendar]? {
        guard let ids else { return nil }
        let found = ids.compactMap { store.calendar(withIdentifier: $0) }
        guard !found.isEmpty else { throw EventKitStoreError.missing(type == .reminder ? "the list" : "the calendar") }
        return found
    }
}

enum EventKitStoreError: LocalizedError {
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .missing(let what): "\(what) is no longer there. It may have been deleted or moved."
        }
    }
}

extension PrivacyAccessKind {
    var entityType: EKEntityType {
        switch self {
        case .reminders: .reminder
        case .calendars: .event
        }
    }
}
