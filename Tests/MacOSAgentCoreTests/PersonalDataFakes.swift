import Foundation
@testable import MacOSAgentCore

/// Reminders and Calendar held in memory, so the tools are tested without the owner's data.
final class FakePersonalDataStore: ReminderStore, CalendarStore, @unchecked Sendable {
    private let lock = NSLock()
    var access: [PrivacyAccessKind: PrivacyAccessStatus]
    /// What a request for access turns into.
    var answer: PrivacyAccessStatus = .fullAccess
    var lists: [ReminderList]
    var storedReminders: [Reminder]
    var calendars: [CalendarInfo]
    var storedEvents: [CalendarEvent]
    private(set) var requests: [PrivacyAccessKind] = []
    private(set) var savedReminders: [(Reminder, Bool)] = []
    private(set) var deletedReminders: [String] = []
    private(set) var savedEvents: [(CalendarEvent, Bool)] = []
    private(set) var deletedEvents: [(String, Date, Bool)] = []
    private(set) var reminderReads = 0
    private(set) var eventReads: [(Date, Date)] = []
    private var nextID = 1

    init(
        access: [PrivacyAccessKind: PrivacyAccessStatus] = [.reminders: .fullAccess, .calendars: .fullAccess],
        lists: [ReminderList] = [], reminders: [Reminder] = [],
        calendars: [CalendarInfo] = [], events: [CalendarEvent] = []
    ) {
        self.access = access
        self.lists = lists
        self.storedReminders = reminders
        self.calendars = calendars
        self.storedEvents = events
    }

    func status(_ kind: PrivacyAccessKind) -> PrivacyAccessStatus {
        lock.withLock { access[kind] ?? .notDetermined }
    }

    func requestAccess(_ kind: PrivacyAccessKind) async -> PrivacyAccessStatus {
        lock.withLock {
            requests.append(kind)
            if access[kind] == .notDetermined || access[kind] == nil { access[kind] = answer }
            return access[kind]!
        }
    }

    func reminderLists() async throws -> [ReminderList] { lock.withLock { lists } }

    func reminders(inLists listIDs: [String]?, status: ReminderStatusFilter) async throws -> [Reminder] {
        lock.withLock {
            reminderReads += 1
            return storedReminders.filter { reminder in
                let wanted = switch status {
                case .incomplete: !reminder.isCompleted
                case .completed: reminder.isCompleted
                case .all: true
                }
                return wanted && (listIDs?.contains(reminder.listID) ?? true)
            }
        }
    }

    func reminder(identifier: String) async throws -> Reminder? {
        lock.withLock { storedReminders.first { $0.identifier == identifier } }
    }

    func save(_ reminder: Reminder, dueChanged: Bool) async throws -> Reminder {
        lock.withLock {
            var saved = reminder
            if saved.identifier.isEmpty {
                saved.identifier = "REMINDER-NEW-\(nextID)"
                nextID += 1
                storedReminders.append(saved)
            } else if let index = storedReminders.firstIndex(where: { $0.identifier == reminder.identifier }) {
                storedReminders[index] = saved
            }
            savedReminders.append((saved, dueChanged))
            return saved
        }
    }

    func deleteReminder(identifier: String) async throws {
        lock.withLock {
            deletedReminders.append(identifier)
            storedReminders.removeAll { $0.identifier == identifier }
        }
    }

    func eventCalendars() async throws -> [CalendarInfo] { lock.withLock { calendars } }

    func events(from start: Date, to end: Date, inCalendars calendarIDs: [String]?) async throws -> [CalendarEvent] {
        lock.withLock {
            eventReads.append((start, end))
            return storedEvents.filter { event in
                (calendarIDs?.contains(event.calendarID) ?? true) && event.start < end && event.end > start
            }
        }
    }

    func event(identifier: String, occurrenceDate: Date?) async throws -> CalendarEvent? {
        lock.withLock {
            storedEvents.first { $0.identifier == identifier && (occurrenceDate == nil || $0.occurrenceDate == occurrenceDate) }
        }
    }

    func save(_ event: CalendarEvent, includingFuture: Bool) async throws -> CalendarEvent {
        lock.withLock {
            var saved = event
            if saved.identifier.isEmpty {
                saved.identifier = "EVENT-NEW-\(nextID)"
                saved.occurrenceDate = saved.start
                nextID += 1
                storedEvents.append(saved)
            } else if let index = storedEvents.firstIndex(where: {
                $0.identifier == event.identifier && $0.occurrenceDate == event.occurrenceDate
            }) {
                storedEvents[index] = saved
            }
            savedEvents.append((saved, includingFuture))
            return saved
        }
    }

    func deleteEvent(identifier: String, occurrenceDate: Date, includingFuture: Bool) async throws {
        lock.withLock {
            deletedEvents.append((identifier, occurrenceDate, includingFuture))
            storedEvents.removeAll { $0.identifier == identifier && $0.occurrenceDate == occurrenceDate }
        }
    }
}

/// Records go-ahead requests and answers them with a fixed choice.
final class GoAheadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [ConfirmationRequest] = []
    let answer: Bool

    init(answer: Bool) { self.answer = answer }

    var requests: [ConfirmationRequest] { lock.withLock { asked } }

    var context: ToolRunContext {
        ToolRunContext(callID: "call", confirm: { request in
            self.lock.withLock { self.asked.append(request) }
            return self.answer
        })
    }
}
