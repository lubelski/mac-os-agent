import Foundation
import Testing
@testable import MacOSAgentCore

private let pacific = TimeZone(identifier: "America/Los_Angeles")!
private let dates = LocalDates(timeZone: pacific)

/// A moment given as local wall time in the test time zone.
private func local(_ text: String) -> Date {
    guard case .moment(let date, _)? = dates.parse(text) else { fatalError("bad test date \(text)") }
    return date
}

private let now = local("2026-11-21T10:00")

private func short(_ identifier: String) -> String { ShortIdentifierTable.short(identifier) }

@Suite struct LocalDatesTests {
    @Test func readsDatesAndFloatingTimesInTheMacTimeZone() throws {
        #expect(dates.parse("2026-11-21") == .day(CalendarDay(year: 2026, month: 11, day: 21)))
        let floating = try #require(dates.parse("2026-11-21T14:30"))
        guard case .moment(let date, let isFloating) = floating else { Issue.record("not a moment"); return }
        #expect(isFloating)
        #expect(date == Date(timeIntervalSince1970: 1_795_300_200)) // 22:30 UTC
        #expect(dates.parse("2026-11-21 14:30:00") == floating)
        #expect(dates.parse("2026-11-21T14:30:00.250") == floating)
    }

    @Test func honorsAnExplicitOffset() {
        #expect(dates.parse("2026-11-21T22:30:00Z") == .moment(Date(timeIntervalSince1970: 1_795_300_200), floating: false))
        #expect(dates.parse("2026-11-21T17:30-05:00") == .moment(Date(timeIntervalSince1970: 1_795_300_200), floating: false))
        #expect(dates.parse("2026-11-21T23:30+0100") == .moment(Date(timeIntervalSince1970: 1_795_300_200), floating: false))
    }

    @Test func rejectsWhatIsNotAnISODate() {
        for text in ["tomorrow", "11/21/2026", "2026-02-30", "2026-13-01", "2026-11-21T25:00", "2026-11-21T10", "2026-11-21T10:00+99:00", ""] {
            #expect(dates.parse(text) == nil, "\(text)")
        }
    }

    @Test func writesDatesWithTheWeekday() {
        #expect(dates.text(CalendarDay(year: 2026, month: 11, day: 21)) == "Sat 2026-11-21")
        #expect(dates.text(local("2026-11-23T09:05")) == "Mon 2026-11-23 09:05")
        #expect(dates.timeZoneNote == "Times are local to the Mac (America/Los_Angeles, PST).")
    }

    @Test func aDayAsTheEndOfARangeIncludesTheWholeDay() {
        #expect(dates.endOfRange(reaching: .day(CalendarDay(year: 2026, month: 11, day: 21))) == local("2026-11-22T00:00"))
        #expect(dates.start(of: .day(CalendarDay(year: 2026, month: 11, day: 21))) == local("2026-11-21T00:00"))
    }

    @Test func daylightSavingTimeKeepsWallTime() {
        // Clocks go back on 2026-11-01 in California.
        #expect(dates.text(local("2026-10-31T09:00")) == "Sat 2026-10-31 09:00")
        #expect(dates.text(local("2026-11-02T09:00")) == "Mon 2026-11-02 09:00")
    }
}

// MARK: - Reminders

private func reminderStore() -> FakePersonalDataStore {
    FakePersonalDataStore(
        lists: [
            ReminderList(id: "LIST-INBOX", title: "Reminders", account: "iCloud", isDefault: true),
            ReminderList(id: "LIST-GROCERIES", title: "Groceries", account: "iCloud"),
            ReminderList(id: "LIST-SHARED", title: "Office", account: "Exchange", allowsChanges: false),
        ],
        reminders: [
            Reminder(identifier: "R-MILK", title: "Buy milk", listID: "LIST-GROCERIES", due: .day(CalendarDay(year: 2026, month: 11, day: 21))),
            Reminder(identifier: "R-EGGS", title: "Buy eggs", notes: "Free range, a dozen", listID: "LIST-GROCERIES"),
            Reminder(identifier: "R-DENTIST", title: "Call the dentist", listID: "LIST-INBOX", due: .moment(local("2026-11-20T09:00")), priority: 1),
            Reminder(identifier: "R-TAXES", title: "File taxes", listID: "LIST-INBOX", due: .moment(local("2026-12-01T17:00")), priority: 5),
            Reminder(identifier: "R-OLD", title: "Return library book", listID: "LIST-INBOX", isCompleted: true, completionDate: local("2026-11-19T12:00")),
            Reminder(identifier: "R-OLDER", title: "Renew passport", listID: "LIST-INBOX", isCompleted: true, completionDate: local("2026-10-02T08:00")),
        ])
}

private func readTool(_ store: FakePersonalDataStore, _ table: ShortIdentifierTable = ShortIdentifierTable()) -> ReadRemindersTool {
    ReadRemindersTool(store: store, identifiers: table, dates: dates, now: { now })
}

private func readArguments(
    list: String? = nil, status: String = "incomplete", from: String? = nil, to: String? = nil, text: String? = nil, limit: Int? = nil
) -> JSONValue {
    [
        "list": list.map { .string($0) } ?? .null, "status": .string(status),
        "due_from": from.map { .string($0) } ?? .null, "due_to": to.map { .string($0) } ?? .null,
        "text": text.map { .string($0) } ?? .null, "limit": limit.map { .number(Double($0)) } ?? .null,
    ]
}

private func change(
    id: String? = nil, delete: Bool = false, title: String? = nil, notes: String? = nil, list: String? = nil,
    due: String? = nil, priority: String? = nil, completed: Bool? = nil
) -> JSONValue {
    [
        "id": id.map { .string($0) } ?? .null, "delete": .bool(delete), "title": title.map { .string($0) } ?? .null,
        "notes": notes.map { .string($0) } ?? .null, "list": list.map { .string($0) } ?? .null,
        "due": due.map { .string($0) } ?? .null, "priority": priority.map { .string($0) } ?? .null,
        "completed": completed.map { .bool($0) } ?? .null,
    ]
}

@Suite struct ReadRemindersToolTests {
    private let neverAsks = ToolRunContext(callID: "c", confirm: { _ in
        Issue.record("reading never asks")
        return false
    })

    @Test func listsTheListsThenIncompleteRemindersSoonestDueFirst() async {
        let output = await readTool(reminderStore()).run(arguments: readArguments(), context: neverAsks)
        #expect(output == """
            Lists: Reminders (default), Groceries, Office (read only). Times are local to the Mac (America/Los_Angeles, PST).
            4 incomplete reminders, soonest due first, as id | title | list | details:
            \(short("R-DENTIST")) | Call the dentist | Reminders | due Fri 2026-11-20 09:00, overdue | high priority
            \(short("R-MILK")) | Buy milk | Groceries | due Sat 2026-11-21
            \(short("R-TAXES")) | File taxes | Reminders | due Tue 2026-12-01 17:00 | medium priority
            \(short("R-EGGS")) | Buy eggs | Groceries | notes: Free range, a dozen
            """)
    }

    @Test func filtersByListDueRangeAndText() async {
        let tool = readTool(reminderStore())
        let groceries = await tool.run(arguments: readArguments(list: "groceries"), context: neverAsks)
        #expect(groceries.contains("2 incomplete reminders"))
        #expect(!groceries.contains("dentist"))

        let thisWeek = await tool.run(arguments: readArguments(from: "2026-11-21", to: "2026-11-27"), context: neverAsks)
        #expect(thisWeek.contains("1 incomplete reminder,"))
        #expect(thisWeek.contains("Buy milk"))

        let overdue = await tool.run(arguments: readArguments(to: "2026-11-21T10:00"), context: neverAsks)
        #expect(overdue.contains("Call the dentist"))
        #expect(overdue.contains("Buy milk"))
        #expect(!overdue.contains("File taxes"))

        let byNotes = await tool.run(arguments: readArguments(text: "FREE range"), context: neverAsks)
        #expect(byNotes.contains("Buy eggs"))
        #expect(byNotes.contains("1 incomplete reminder,"))
    }

    @Test func completedRemindersComeMostRecentFirst() async {
        let output = await readTool(reminderStore()).run(arguments: readArguments(status: "completed"), context: neverAsks)
        let lines = output.split(separator: "\n")
        #expect(lines[1] == "2 completed reminders, most recently completed first, as id | title | list | details:")
        #expect(lines[2].hasSuffix("Return library book | Reminders | done Thu 2026-11-19 12:00"))
        #expect(lines[3].contains("Renew passport"))
    }

    @Test func saysWhenNothingMatchesAndWhenTheLimitCutsTheList() async {
        let tool = readTool(reminderStore())
        let none = await tool.run(arguments: readArguments(text: "xylophone"), context: neverAsks)
        #expect(none.hasSuffix("No incomplete reminders match."))
        let limited = await tool.run(arguments: readArguments(limit: 2), context: neverAsks)
        #expect(limited.hasSuffix("Showing the first 2 of 4. Narrow by list, due dates, or text to see the others."))
    }

    @Test func rejectsAnUnknownListAndBadDates() async {
        let tool = readTool(reminderStore())
        let list = await tool.run(arguments: readArguments(list: "Chores"), context: neverAsks)
        #expect(list == "Error: there is no list named \"Chores\". The lists are: Reminders, Groceries, Office.")
        let date = await tool.run(arguments: readArguments(from: "next tuesday"), context: neverAsks)
        #expect(date.hasPrefix("Error: due_from \"next tuesday\" is not an ISO 8601 date"))
    }

    @Test func twoListsWithOneNameAreToldApartByAccount() async {
        let store = reminderStore()
        store.lists.append(ReminderList(id: "LIST-WORK-INBOX", title: "Reminders", account: "Exchange"))
        store.storedReminders.append(Reminder(identifier: "R-WORK", title: "Expense report", listID: "LIST-WORK-INBOX"))
        let tool = readTool(store)
        let ambiguous = await tool.run(arguments: readArguments(list: "reminders"), context: neverAsks)
        #expect(ambiguous == "Error: there is more than one list named \"reminders\". Pass \"Reminders (iCloud)\" or \"Reminders (Exchange)\".")
        let exact = await tool.run(arguments: readArguments(list: "Reminders (Exchange)"), context: neverAsks)
        #expect(exact.contains("Expense report | Reminders (Exchange)"))
        #expect(!exact.contains("dentist"))
    }

    @Test func asksForAccessTheFirstTimeAndReadsOnceAllowed() async {
        let store = reminderStore()
        store.access = [.reminders: .notDetermined]
        let output = await readTool(store).run(arguments: readArguments(), context: neverAsks)
        #expect(store.requests == [.reminders])
        #expect(output.hasPrefix("Lists:"))
    }

    @Test func explainsWhereToAllowAccessWhenDenied() async {
        for (status, answer, expected) in [
            (PrivacyAccessStatus.denied, PrivacyAccessStatus.denied, "Error: mac-os-agent is not allowed to use Reminders. Nothing was read or changed. The owner can allow it in System Settings > Privacy & Security > Reminders, then ask again."),
            (.notDetermined, .denied, "Error: mac-os-agent is not allowed to use Reminders. Nothing was read or changed. The owner can allow it in System Settings > Privacy & Security > Reminders, then ask again."),
            (.restricted, .restricted, "Error: access to Reminders is restricted on this Mac, for example by a management profile, so mac-os-agent cannot use it. Nothing was read or changed."),
        ] {
            let store = reminderStore()
            store.access = [.reminders: status]
            store.answer = answer
            #expect(await readTool(store).run(arguments: readArguments(), context: neverAsks) == expected)
            #expect(store.reminderReads == 0)
            #expect(store.requests == (status == .notDetermined ? [.reminders] : []))
        }
    }
}

@Suite struct ChangeRemindersToolTests {
    private func tool(_ store: FakePersonalDataStore, _ table: ShortIdentifierTable = ShortIdentifierTable()) -> ChangeRemindersTool {
        ChangeRemindersTool(store: store, identifiers: table, dates: dates)
    }

    @Test func createsAReminderInTheDefaultListWithoutAsking() async throws {
        let store = reminderStore()
        let goAhead = GoAheadRecorder(answer: false)
        let output = await tool(store).run(
            arguments: ["changes": [change(title: "Water the plants", due: "2026-11-22T08:30", priority: "high")]],
            context: goAhead.context)
        #expect(goAhead.requests.isEmpty)
        let (saved, dueChanged) = try #require(store.savedReminders.first)
        #expect(saved.listID == "LIST-INBOX")
        #expect(saved.due == .moment(local("2026-11-22T08:30")))
        #expect(saved.priority == 1)
        #expect(dueChanged)
        #expect(output == "Created \(short(saved.identifier)) | Water the plants | Reminders | due Sun 2026-11-22 08:30 | high priority")
    }

    @Test func aDateAloneIsDueThatDay() async throws {
        let store = reminderStore()
        _ = await tool(store).run(arguments: ["changes": [change(title: "Pay rent", list: "Groceries", due: "2026-12-01")]], context: GoAheadRecorder(answer: false).context)
        let saved = try #require(store.savedReminders.first?.0)
        #expect(saved.due == .day(CalendarDay(year: 2026, month: 12, day: 1)))
        #expect(saved.listID == "LIST-GROCERIES")
    }

    @Test func completesAndEditsOneReminderWithoutAsking() async throws {
        let store = reminderStore()
        let table = ShortIdentifierTable()
        _ = await readTool(store, table).run(arguments: readArguments(), context: GoAheadRecorder(answer: false).context)
        let goAhead = GoAheadRecorder(answer: false)
        let output = await tool(store, table).run(
            arguments: ["changes": [change(id: short("R-MILK"), notes: "Oat milk", completed: true)]], context: goAhead.context)
        #expect(goAhead.requests.isEmpty)
        let (saved, dueChanged) = try #require(store.savedReminders.first)
        #expect(saved.isCompleted)
        #expect(saved.notes == "Oat milk")
        #expect(saved.due == .day(CalendarDay(year: 2026, month: 11, day: 21)))
        #expect(!dueChanged)
        #expect(output.hasPrefix("Updated \(short("R-MILK")) | Buy milk | Groceries"))
    }

    @Test func clearsTheDueDateAndMovesToAnotherList() async throws {
        let store = reminderStore()
        _ = await tool(store).run(
            arguments: ["changes": [change(id: short("R-DENTIST"), list: "Groceries", due: "none", priority: "none")]],
            context: GoAheadRecorder(answer: false).context)
        let (saved, dueChanged) = try #require(store.savedReminders.first)
        #expect(saved.due == nil)
        #expect(dueChanged)
        #expect(saved.priority == 0)
        #expect(saved.listID == "LIST-GROCERIES")
    }

    @Test func anIdFromAnEarlierRunIsFoundByHashing() async throws {
        let store = reminderStore()
        let output = await tool(store).run(arguments: ["changes": [change(id: short("R-TAXES"), completed: true)]], context: GoAheadRecorder(answer: false).context)
        #expect(output.hasPrefix("Updated \(short("R-TAXES"))"))
        #expect(store.reminderReads == 1)
    }

    @Test func deletingAsksFirstAndDecliningChangesNothing() async {
        let store = reminderStore()
        let goAhead = GoAheadRecorder(answer: false)
        let output = await tool(store).run(arguments: ["changes": [change(id: short("R-EGGS"), delete: true)]], context: goAhead.context)
        #expect(output == "The owner declined. Nothing was changed.")
        #expect(goAhead.requests.map(\.reason) == ["deletes a reminder"])
        #expect(goAhead.requests.first?.command == "Delete \"Buy eggs\" from Groceries")
        #expect(store.deletedReminders.isEmpty)
    }

    @Test func deletingGoesAheadWhenApproved() async {
        let store = reminderStore()
        let output = await tool(store).run(arguments: ["changes": [change(id: short("R-EGGS"), delete: true)]], context: GoAheadRecorder(answer: true).context)
        #expect(output == "Deleted \"Buy eggs\" from Groceries.")
        #expect(store.deletedReminders == ["R-EGGS"])
    }

    @Test func changingSeveralAtOnceAsksOnceWithEveryChangeListed() async {
        let store = reminderStore()
        let goAhead = GoAheadRecorder(answer: true)
        let output = await tool(store).run(arguments: ["changes": [
            change(id: short("R-MILK"), completed: true),
            change(id: short("R-EGGS"), completed: true),
            change(title: "Buy bread", list: "Groceries"),
        ]], context: goAhead.context)
        #expect(goAhead.requests.count == 1)
        #expect(goAhead.requests[0].reason == "changes 3 reminders at once")
        #expect(goAhead.requests[0].command == """
            Change "Buy milk" in Groceries: mark done
            Change "Buy eggs" in Groceries: mark done
            Create "Buy bread" in Groceries
            """)
        #expect(output.split(separator: "\n").count == 3)
        #expect(store.savedReminders.count == 3)
    }

    @Test func aBadChangeStopsTheWholeCallBeforeAsking() async {
        let store = reminderStore()
        let goAhead = GoAheadRecorder(answer: true)
        let output = await tool(store).run(arguments: ["changes": [
            change(id: short("R-MILK"), completed: true),
            change(id: "deadbeef", completed: true),
            change(title: "No list", list: "Chores"),
            change(title: "Bad date", due: "soon"),
            change(due: "2026-11-22"),
            change(id: short("R-EGGS")),
            change(title: "Shared", list: "Office"),
        ]], context: goAhead.context)
        #expect(output == """
            Error: nothing was changed.
            Change 2: no reminder has the id deadbeef. Read the reminders again for current ids.
            Change 3: there is no list named "Chores". The lists are: Reminders, Groceries, Office.
            Change 4: due "soon" is not an ISO 8601 date or date-time such as 2026-11-21 or 2026-11-21T15:00.
            Change 5: a new reminder needs a title.
            Change 6: the change for \(short("R-EGGS")) has nothing to change.
            Change 7: the list Office is read only.
            """)
        #expect(goAhead.requests.isEmpty)
        #expect(store.savedReminders.isEmpty)
    }

    @Test func refusesEmptyOrOversizedCalls() async {
        let changes = ChangeRemindersTool(store: reminderStore(), identifiers: ShortIdentifierTable(), dates: dates)
        let context = GoAheadRecorder(answer: true).context
        #expect(await changes.run(arguments: ["changes": []], context: context) == "Error: the call did not include any changes.")
        let many = JSONValue.array(Array(repeating: change(title: "x"), count: 51))
        #expect(await changes.run(arguments: ["changes": many], context: context).hasPrefix("Error: a call can make at most 50"))
    }
}

// MARK: - Calendar

private func calendarStore() -> FakePersonalDataStore {
    FakePersonalDataStore(
        calendars: [
            CalendarInfo(id: "CAL-HOME", title: "Home", account: "iCloud", isDefault: true),
            CalendarInfo(id: "CAL-WORK", title: "Work", account: "Exchange"),
            CalendarInfo(id: "CAL-HOLIDAYS", title: "US Holidays", allowsChanges: false),
        ],
        events: [
            CalendarEvent(identifier: "E-LUNCH", title: "Lunch with Sam", start: local("2026-11-21T12:00"), end: local("2026-11-21T13:00"), location: "Café Luna", calendarID: "CAL-HOME"),
            CalendarEvent(identifier: "E-STANDUP", occurrenceDate: local("2026-11-23T09:30"), title: "Standup", start: local("2026-11-23T09:30"), end: local("2026-11-23T09:45"), calendarID: "CAL-WORK", isRecurring: true),
            CalendarEvent(identifier: "E-STANDUP", occurrenceDate: local("2026-11-24T09:30"), title: "Standup", start: local("2026-11-24T09:30"), end: local("2026-11-24T09:45"), calendarID: "CAL-WORK", isRecurring: true),
            CalendarEvent(identifier: "E-THANKS", title: "Thanksgiving", start: local("2026-11-26T00:00"), end: local("2026-11-26T23:59:59"), isAllDay: true, calendarID: "CAL-HOLIDAYS"),
            CalendarEvent(identifier: "E-TRIP", title: "Trip to Tahoe", start: local("2026-12-04T00:00"), end: local("2026-12-06T23:59:59"), isAllDay: true, notes: "Bring chains", calendarID: "CAL-HOME"),
        ])
}

private func eventsTool(_ store: FakePersonalDataStore, _ table: ShortIdentifierTable = ShortIdentifierTable()) -> ReadEventsTool {
    ReadEventsTool(store: store, identifiers: table, dates: dates, now: { now })
}

private func eventArguments(from: String? = nil, to: String? = nil, text: String? = nil, calendar: String? = nil, limit: Int? = nil) -> JSONValue {
    [
        "from": from.map { .string($0) } ?? .null, "to": to.map { .string($0) } ?? .null,
        "text": text.map { .string($0) } ?? .null, "calendar": calendar.map { .string($0) } ?? .null,
        "limit": limit.map { .number(Double($0)) } ?? .null,
    ]
}

private func eventChange(
    id: String? = nil, delete: Bool = false, title: String? = nil, start: String? = nil, end: String? = nil,
    allDay: Bool? = nil, location: String? = nil, notes: String? = nil, calendar: String? = nil, includeFuture: Bool? = nil
) -> JSONValue {
    [
        "id": id.map { .string($0) } ?? .null, "delete": .bool(delete), "title": title.map { .string($0) } ?? .null,
        "start": start.map { .string($0) } ?? .null, "end": end.map { .string($0) } ?? .null,
        "all_day": allDay.map { .bool($0) } ?? .null, "location": location.map { .string($0) } ?? .null,
        "notes": notes.map { .string($0) } ?? .null, "calendar": calendar.map { .string($0) } ?? .null,
        "include_future": includeFuture.map { .bool($0) } ?? .null,
    ]
}

private let standupMonday = "\(short("E-STANDUP"))-202611231730"

@Suite struct ReadEventsToolTests {
    private let neverAsks = ToolRunContext(callID: "c", confirm: { _ in
        Issue.record("reading never asks")
        return false
    })

    @Test func readsTheNextSevenDaysByDefault() async {
        let store = calendarStore()
        let output = await eventsTool(store).run(arguments: eventArguments(), context: neverAsks)
        #expect(output == """
            Calendars: Home (default), Work, US Holidays (read only). Times are local to the Mac (America/Los_Angeles, PST).
            Range: Sat 2026-11-21 00:00 to Sat 2026-11-28 00:00.
            4 events, soonest first, as id | title | when | calendar | details:
            \(short("E-LUNCH")) | Lunch with Sam | Sat 2026-11-21 12:00 to 13:00 | Home | at: Café Luna
            \(standupMonday) | Standup | Mon 2026-11-23 09:30 to 09:45 | Work | repeats
            \(short("E-STANDUP"))-202611241730 | Standup | Tue 2026-11-24 09:30 to 09:45 | Work | repeats
            \(short("E-THANKS")) | Thanksgiving | Thu 2026-11-26, all day | US Holidays | read only
            """)
    }

    @Test func aDateAsTheEndIncludesThatDayAndMultiDayEventsShowTheirLastDay() async {
        let store = calendarStore()
        let output = await eventsTool(store).run(arguments: eventArguments(from: "2026-12-01", to: "2026-12-04"), context: neverAsks)
        #expect(output.contains("Trip to Tahoe | Fri 2026-12-04 to Sun 2026-12-06, all day | Home | notes: Bring chains"))
        #expect(store.eventReads.last?.1 == local("2026-12-05T00:00"))
    }

    @Test func textSearchLooksAYearEachWay() async {
        let store = calendarStore()
        let output = await eventsTool(store).run(arguments: eventArguments(text: "tahoe"), context: neverAsks)
        #expect(output.contains("1 event,"))
        #expect(output.contains("Trip to Tahoe"))
        let (start, end) = store.eventReads[0]
        #expect(start == local("2025-11-21T00:00"))
        #expect(end == local("2027-11-21T00:00"))
    }

    @Test func filtersByCalendarAndRejectsBadRanges() async {
        let tool = eventsTool(calendarStore())
        let work = await tool.run(arguments: eventArguments(calendar: "work"), context: neverAsks)
        #expect(work.contains("2 events"))
        #expect(await tool.run(arguments: eventArguments(from: "2026-11-21", to: "2026-11-20"), context: neverAsks) == "Error: the range ends before it starts.")
        #expect(await tool.run(arguments: eventArguments(from: "2026-01-01", to: "2029-01-01"), context: neverAsks) == "Error: a range can be at most 731 days long.")
        #expect(await tool.run(arguments: eventArguments(to: "friday"), context: neverAsks).hasPrefix("Error: to \"friday\""))
    }

    @Test func writeOnlyAccessIsNotEnoughToRead() async {
        let store = calendarStore()
        store.access = [.calendars: .writeOnly]
        let output = await eventsTool(store).run(arguments: eventArguments(), context: neverAsks)
        #expect(output == "Error: mac-os-agent can add to Calendars but not read it. Nothing was read or changed. The owner can give it full access in System Settings > Privacy & Security > Calendars.")
        #expect(store.eventReads.isEmpty)
    }
}

@Suite struct ChangeEventsToolTests {
    private func tool(_ store: FakePersonalDataStore, _ table: ShortIdentifierTable = ShortIdentifierTable()) -> ChangeEventsTool {
        ChangeEventsTool(store: store, identifiers: table, dates: dates, now: { now })
    }

    @Test func createsATimedEventAnHourLongInTheDefaultCalendar() async throws {
        let store = calendarStore()
        let goAhead = GoAheadRecorder(answer: false)
        let output = await tool(store).run(arguments: ["changes": [eventChange(title: "Haircut", start: "2026-11-25T15:00")]], context: goAhead.context)
        #expect(goAhead.requests.isEmpty)
        let saved = try #require(store.savedEvents.first?.0)
        #expect(saved.calendarID == "CAL-HOME")
        #expect(saved.start == local("2026-11-25T15:00"))
        #expect(saved.end == local("2026-11-25T16:00"))
        #expect(!saved.isAllDay)
        #expect(output == "Created \(short(saved.identifier)) | Haircut | Wed 2026-11-25 15:00 to 16:00 | Home")
    }

    @Test func aDateAloneMakesAnAllDayEventThroughItsLastDay() async throws {
        let store = calendarStore()
        let output = await tool(store).run(
            arguments: ["changes": [eventChange(title: "Conference", start: "2026-12-08", end: "2026-12-10", calendar: "Work")]],
            context: GoAheadRecorder(answer: false).context)
        let saved = try #require(store.savedEvents.first?.0)
        #expect(saved.isAllDay)
        #expect(saved.start == local("2026-12-08T00:00"))
        #expect(saved.end == local("2026-12-10T23:59:59"))
        #expect(output.hasSuffix("| Conference | Tue 2026-12-08 to Thu 2026-12-10, all day | Work"))
    }

    @Test func movingTheStartKeepsTheLength() async throws {
        let store = calendarStore()
        _ = await tool(store).run(arguments: ["changes": [eventChange(id: short("E-LUNCH"), start: "2026-11-22T12:30")]], context: GoAheadRecorder(answer: false).context)
        let saved = try #require(store.savedEvents.first)
        #expect(saved.0.start == local("2026-11-22T12:30"))
        #expect(saved.0.end == local("2026-11-22T13:30"))
        #expect(saved.0.location == "Café Luna")
        #expect(!saved.1)
    }

    @Test func movingAnAllDayEventKeepsItsDays() async throws {
        let store = calendarStore()
        _ = await tool(store).run(arguments: ["changes": [eventChange(id: short("E-TRIP"), start: "2026-12-11")]], context: GoAheadRecorder(answer: false).context)
        let saved = try #require(store.savedEvents.first?.0)
        #expect(saved.start == local("2026-12-11T00:00"))
        #expect(saved.end == local("2026-12-13T23:59:59"))
    }

    @Test func oneOccurrenceOfARepeatingEventChangesAlone() async throws {
        let store = calendarStore()
        let table = ShortIdentifierTable()
        _ = await eventsTool(store, table).run(arguments: eventArguments(), context: GoAheadRecorder(answer: false).context)
        let goAhead = GoAheadRecorder(answer: false)
        let output = await tool(store, table).run(arguments: ["changes": [eventChange(id: standupMonday, start: "2026-11-23T10:00")]], context: goAhead.context)
        #expect(goAhead.requests.isEmpty)
        let saved = try #require(store.savedEvents.first)
        #expect(saved.0.occurrenceDate == local("2026-11-23T09:30"))
        #expect(saved.0.start == local("2026-11-23T10:00"))
        #expect(!saved.1)
        #expect(output.contains("Mon 2026-11-23 10:00 to 10:15"))
    }

    @Test func changingLaterOccurrencesAsksFirst() async throws {
        let store = calendarStore()
        let goAhead = GoAheadRecorder(answer: true)
        _ = await tool(store).run(arguments: ["changes": [eventChange(id: standupMonday, title: "Team standup", includeFuture: true)]], context: goAhead.context)
        #expect(goAhead.requests.map(\.reason) == ["changes a repeating event from this occurrence on"])
        #expect(goAhead.requests.first?.command == "Change \"Standup\" (Mon 2026-11-23 09:30 to 09:45) and its later occurrences: title \"Team standup\"")
        #expect(store.savedEvents.first?.1 == true)
    }

    @Test func deletingAsksFirst() async {
        let store = calendarStore()
        let declined = GoAheadRecorder(answer: false)
        #expect(await tool(store).run(arguments: ["changes": [eventChange(id: short("E-LUNCH"), delete: true)]], context: declined.context)
            == "The owner declined. Nothing was changed.")
        #expect(declined.requests.first?.reason == "deletes an event")
        #expect(declined.requests.first?.command == "Delete \"Lunch with Sam\" (Sat 2026-11-21 12:00 to 13:00) from Home")
        #expect(store.deletedEvents.isEmpty)

        let approved = GoAheadRecorder(answer: true)
        let output = await tool(store).run(arguments: ["changes": [eventChange(id: short("E-LUNCH"), delete: true)]], context: approved.context)
        #expect(output == "Deleted \"Lunch with Sam\" (Sat 2026-11-21 12:00 to 13:00).")
        #expect(store.deletedEvents.map(\.0) == ["E-LUNCH"])
    }

    @Test func refusesReadOnlyCalendarsAndImpossibleTimes() async {
        let store = calendarStore()
        let goAhead = GoAheadRecorder(answer: true)
        let output = await tool(store).run(arguments: ["changes": [
            eventChange(id: short("E-THANKS"), title: "Turkey day"),
            eventChange(title: "Backwards", start: "2026-11-25T15:00", end: "2026-11-25T14:00"),
            eventChange(title: "No time", start: "2026-11-25", allDay: false),
            eventChange(title: "No start"),
        ]], context: goAhead.context)
        #expect(output == """
            Error: nothing was changed.
            Change 1: the calendar US Holidays is read only.
            Change 2: the event would end before it starts.
            Change 3: start needs a time, or set all_day to true.
            Change 4: a new event needs a start.
            """)
        #expect(goAhead.requests.isEmpty)
        #expect(store.savedEvents.isEmpty)
    }

    @Test func anOccurrenceIdFromAnEarlierRunIsFoundAroundItsDate() async throws {
        let store = calendarStore()
        let output = await tool(store).run(arguments: ["changes": [eventChange(id: standupMonday, notes: "Demo day")]], context: GoAheadRecorder(answer: false).context)
        #expect(output.hasPrefix("Updated \(standupMonday)"))
        #expect(store.eventReads.first?.0 == local("2026-11-21T09:30"))
    }
}

@Suite struct PersonalDataToolShapeTests {
    /// Strict mode wants every object, nested ones too, closed and with every property required.
    private func checkStrict(_ schema: JSONValue, path: String) {
        if schema["type"] == "object" || schema["type"] == ["object"] {
            #expect(schema["additionalProperties"] == false, "\(path)")
            guard case .object(let properties)? = schema["properties"] else { return }
            let required = Set(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            #expect(required == Set(properties.keys), "\(path)")
            for (name, property) in properties { checkStrict(property, path: "\(path).\(name)") }
        }
        if let items = schema["items"] { checkStrict(items, path: "\(path)[]") }
    }

    @Test func schemasAreStrictAllTheWayDown() {
        let store = FakePersonalDataStore()
        for tool in BuiltInTools.make(applicationWorkspace: FakeApplicationWorkspace(installed: []), reminders: store, calendar: store, system: FakeSystemControl()) {
            checkStrict(tool.definition.parameters, path: tool.definition.name)
        }
    }

    @Test func theNewToolsStayWithinTheirBudget() {
        let store = FakePersonalDataStore()
        let tools = BuiltInTools.make(applicationWorkspace: FakeApplicationWorkspace(installed: []), reminders: store, calendar: store, system: FakeSystemControl())
            .filter { $0.source == .reminders || $0.source == .calendar }
        let characters = tools.map { tool in
            JSONValue.object([
                "type": "function", "name": .string(tool.definition.name), "description": .string(tool.definition.description),
                "parameters": tool.definition.parameters, "strict": true,
            ]).encodedString().count
        }.reduce(0, +)
        #expect(characters < 6_500, "the reminder and calendar tools add \(characters) characters to every request")
    }

    @Test func shortIdentifiersAreStableAndCompact() async {
        #expect(ShortIdentifierTable.short("R-MILK") == ShortIdentifierTable.short("R-MILK"))
        #expect(ShortIdentifierTable.short("R-MILK").count == 8)
        let table = ShortIdentifierTable()
        let short = await table.remember("x-apple-reminder://ABCDEF")
        #expect(await table.long(for: short.uppercased()) == "x-apple-reminder://ABCDEF")
    }
}
