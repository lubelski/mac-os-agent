import Foundation

/// Reads the owner's calendar events in a date range or by text, with the calendars they are in.
public struct ReadEventsTool: AgentTool {
    public static let name = "read_events"
    public static let defaultLimit = 50
    public static let maximumLimit = 200
    /// The longest range one call reads.
    public static let maximumDays = 731

    public let store: any CalendarStore
    public let identifiers: ShortIdentifierTable
    public let dates: LocalDates
    public let now: @Sendable () -> Date

    public init(
        store: any CalendarStore, identifiers: ShortIdentifierTable, dates: LocalDates = LocalDates(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.identifiers = identifiers
        self.dates = dates
        self.now = now
    }

    public var source: ToolSource { .calendar }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: Self.name,
            description: """
                Read the owner's events in the Calendar app. Returns the calendars, then the events in \
                the range, soonest first, each with an id for \(ChangeEventsTool.name). Repeating events \
                come as one line per occurrence.
                """,
            parameters: Schema.object([
                "from": Schema.nullableString("Start of the range, as an ISO 8601 date or date-time such as 2026-11-21 or 2026-11-21T09:00. Null for the start of today, or a year ago when text is given."),
                "to": Schema.nullableString("End of the range. A date alone includes that whole day. Null for 7 days after from, or a year from now when text is given."),
                "text": Schema.nullableString("Words that must all appear in the title, location, or notes. Null for any."),
                "calendar": Schema.nullableString("A calendar's name as this tool shows it. Null for every calendar."),
                "limit": Schema.nullableInteger("The most events to return, up to \(Self.maximumLimit). Null for \(Self.defaultLimit)."),
            ]))
    }

    public func summary(arguments: JSONValue) -> String {
        var parts = ["Read events"]
        if let text = arguments["text"]?.trimmedString, !text.isEmpty { parts.append("matching \"\(text)\"") }
        if let from = arguments["from"]?.trimmedString, !from.isEmpty { parts.append("from \(from)") }
        if let to = arguments["to"]?.trimmedString, !to.isEmpty { parts.append("to \(to)") }
        return parts.joined(separator: " ")
    }

    public func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        let text = arguments["text"]?.trimmedString.flatMap { $0.isEmpty ? nil : $0 }
        var inputs: [String: DateInput] = [:]
        for key in ["from", "to"] {
            guard let value = arguments[key]?.trimmedString, !value.isEmpty else { continue }
            guard let input = dates.parse(value) else {
                return "Error: \(key) \"\(value)\" is not an ISO 8601 date or date-time such as 2026-11-21 or 2026-11-21T09:00."
            }
            inputs[key] = input
        }
        let calendar = dates.calendar
        let today = dates.day(of: now()).start(in: calendar)
        let defaultSpan = text == nil ? 7 : 365
        let from = inputs["from"].map(dates.start(of:))
            ?? (text == nil ? today : calendar.date(byAdding: .day, value: -365, to: today)!)
        let to = inputs["to"].map(dates.endOfRange(reaching:))
            ?? calendar.date(byAdding: .day, value: defaultSpan, to: inputs["from"] == nil && text != nil ? today : from)!
        guard to > from else { return "Error: the range ends before it starts." }
        guard to.timeIntervalSince(from) <= Double(Self.maximumDays) * 86_400 else {
            return "Error: a range can be at most \(Self.maximumDays) days long."
        }
        let limit = min(max(arguments["limit"]?.numberValue.map { Int($0) } ?? Self.defaultLimit, 1), Self.maximumLimit)

        if let error = await store.ensureFullAccess(.calendars) { return error }
        do {
            let calendars = try await store.eventCalendars()
            var calendarIDs: [String]?
            if let name = arguments["calendar"]?.trimmedString, !name.isEmpty {
                switch PersonalDataText.resolve(name, in: calendars.map(\.named), noun: "calendar") {
                case .success(let found): calendarIDs = [found.id]
                case .failure(let error): return "Error: \(error.message)"
                }
            }
            var events = try await store.events(from: from, to: to, inCalendars: calendarIDs)
            if let text {
                events = events.filter { PersonalDataText.matches(text, fields: [$0.title, $0.location, $0.notes]) }
            }
            events.sort { ($0.start, $0.end, $0.title) < ($1.start, $1.end, $1.title) }
            let total = events.count
            let shown = Array(events.prefix(limit))
            await identifiers.rememberAll(shown.map(\.identifier))

            let formatter = EventText(dates: dates, calendars: calendars)
            var lines = [
                "Calendars: \(PersonalDataText.summary(calendars.map(\.named))). \(dates.timeZoneNote)",
                "Range: \(dates.text(from)) to \(dates.text(to)).",
            ]
            if shown.isEmpty {
                lines.append(text.map { "No events match \"\($0)\" in the range." } ?? "No events in the range.")
            } else {
                lines.append("\(total) event\(total == 1 ? "" : "s"), soonest first, as id | title | when | calendar | details:")
                lines += shown.map(formatter.line)
                if total > shown.count {
                    lines.append("Showing the first \(shown.count) of \(total). Narrow the range, calendar, or text to see the others.")
                }
            }
            return lines.joined(separator: "\n")
        } catch {
            return "Error: Calendar could not be read: \(error.localizedDescription)"
        }
    }
}

/// Creates, changes, and deletes calendar events, one or several in a call.
public struct ChangeEventsTool: AgentTool {
    public static let name = "change_events"
    public static let maximumChanges = 50
    static let fields = ["title", "start", "end", "all_day", "location", "notes", "calendar"]

    public let store: any CalendarStore
    public let identifiers: ShortIdentifierTable
    public let dates: LocalDates
    public let now: @Sendable () -> Date

    public init(
        store: any CalendarStore, identifiers: ShortIdentifierTable, dates: LocalDates = LocalDates(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.identifiers = identifiers
        self.dates = dates
        self.now = now
    }

    public var source: ToolSource { .calendar }

    public var goAhead: ToolGoAhead {
        .sometimes("Asks before deleting an event, before changing a repeating event from one occurrence on, and before any call that changes more than one event.")
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: Self.name,
            description: """
                Create, edit, or delete calendar events. A change with a null id creates an event. A \
                change with an id from \(ReadEventsTool.name) edits that event, and its null fields stay \
                as they are. Moving the start keeps the length. A date-time without an offset is local \
                time. Deleting, changing later occurrences, or changing more than one event in a call \
                asks the owner first.
                """,
            parameters: Schema.object([
                "changes": [
                    "type": "array",
                    "description": "The changes, carried out in order.",
                    "items": Schema.object([
                        "id": Schema.nullableString("The event's id, or null to create one."),
                        "delete": ["type": "boolean", "description": "True to delete the event with this id. False otherwise."],
                        "title": Schema.nullableString("The title. Required to create."),
                        "start": Schema.nullableString("ISO 8601 date-time such as 2026-11-21T14:00, or a date for an all-day event. Required to create."),
                        "end": Schema.nullableString("When it ends. For an all-day event, the last day. Null for an hour after the start, or the same day."),
                        "all_day": Schema.nullableBoolean("True for an all-day event. Null follows the start: a date alone is all day."),
                        "location": Schema.nullableString("Where. An empty string removes it."),
                        "notes": Schema.nullableString("Notes. An empty string removes them."),
                        "calendar": Schema.nullableString("The calendar's name. On create, null uses the default calendar."),
                        "include_future": Schema.nullableBoolean("For a repeating event, true also changes or deletes the later occurrences. Null for this one only."),
                    ]),
                ],
            ]))
    }

    public func summary(arguments: JSONValue) -> String {
        let changes = arguments["changes"]?.arrayValue ?? []
        if changes.count == 1, let change = changes.first {
            let title = change["title"]?.trimmedString.map { " \"\($0)\"" } ?? ""
            if change["delete"]?.boolValue == true { return "Delete an event" }
            if change["id"]?.trimmedString == nil { return "Create event\(title)" }
            return "Change event\(title)"
        }
        return "Change \(changes.count) events"
    }

    enum Kind: Equatable { case create, update, delete }

    struct Plan {
        var kind: Kind
        var event: CalendarEvent
        var includingFuture: Bool
        var description: String
    }

    public func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        guard let changes = arguments["changes"]?.arrayValue, !changes.isEmpty else {
            return "Error: the call did not include any changes."
        }
        guard changes.count <= Self.maximumChanges else {
            return "Error: a call can make at most \(Self.maximumChanges) changes. Split them up."
        }
        if let error = await store.ensureFullAccess(.calendars) { return error }

        let calendars: [CalendarInfo]
        do {
            calendars = try await store.eventCalendars()
        } catch {
            return "Error: Calendar could not be read: \(error.localizedDescription)"
        }
        let formatter = EventText(dates: dates, calendars: calendars)
        var plans: [Plan] = []
        var problems: [String] = []
        for (index, change) in changes.enumerated() {
            do {
                plans.append(try await plan(change, calendars: calendars, formatter: formatter))
            } catch let error as ToolInputError {
                problems.append("Change \(index + 1): \(error.message)")
            } catch {
                problems.append("Change \(index + 1): \(error.localizedDescription)")
            }
        }
        guard problems.isEmpty else {
            return "Error: nothing was changed.\n" + problems.joined(separator: "\n")
        }

        let deletions = plans.filter { $0.kind == .delete }.count
        var reason = ChangeRemindersTool.reasonToConfirm(count: plans.count, deletions: deletions, noun: "event")
        if reason == nil, plans.contains(where: \.includingFuture) {
            reason = "changes a repeating event from this occurrence on"
        }
        if let reason {
            let approved = await context.confirm(ConfirmationRequest(
                callID: context.callID, command: plans.map(\.description).joined(separator: "\n"), reason: reason))
            if !approved { return "The owner declined. Nothing was changed." }
        }
        if Task.isCancelled { return "The task was stopped before anything was changed." }

        var results: [String] = []
        for (index, plan) in plans.enumerated() {
            do {
                switch plan.kind {
                case .delete:
                    try await store.deleteEvent(
                        identifier: plan.event.identifier, occurrenceDate: plan.event.occurrenceDate,
                        includingFuture: plan.includingFuture)
                    results.append("Deleted \"\(plan.event.title)\" (\(formatter.when(plan.event)))\(plan.includingFuture ? " and its later occurrences" : "").")
                case .create, .update:
                    let saved = try await store.save(plan.event, includingFuture: plan.includingFuture)
                    await identifiers.remember(saved.identifier)
                    results.append((plan.kind == .create ? "Created " : "Updated ") + formatter.line(saved))
                }
            } catch {
                results.append("Error on change \(index + 1) (\(plan.description)): \(error.localizedDescription)")
            }
        }
        return results.joined(separator: "\n")
    }

    private func plan(_ change: JSONValue, calendars: [CalendarInfo], formatter: EventText) async throws -> Plan {
        let short = change["id"]?.trimmedString.flatMap { $0.isEmpty ? nil : $0 }
        let delete = change["delete"]?.boolValue ?? false
        let includeFuture = change["include_future"]?.boolValue ?? false
        let given = Self.fields.filter { key in
            guard let value = change[key], value != .null else { return false }
            return true
        }
        let calendar = dates.calendar

        var existing: CalendarEvent?
        if let short {
            guard let found = try await find(short) else {
                throw ToolInputError("no event has the id \(short). Read the events again for current ids.")
            }
            existing = found
            let future = includeFuture && found.isRecurring
            if delete {
                return Plan(kind: .delete, event: found, includingFuture: future,
                            description: "Delete \"\(found.title)\" (\(formatter.when(found)))\(future ? " and its later occurrences" : "") from \(formatter.calendarName(found.calendarID))")
            }
            guard !given.isEmpty else { throw ToolInputError("the change for \(short) has nothing to change.") }
        } else if delete {
            throw ToolInputError("deleting needs the event's id.")
        }

        func parse(_ key: String) throws -> DateInput? {
            guard let text = change[key]?.trimmedString, !text.isEmpty else { return nil }
            guard let input = dates.parse(text) else {
                throw ToolInputError("\(key) \"\(text)\" is not an ISO 8601 date or date-time such as 2026-11-21 or 2026-11-21T14:00.")
            }
            return input
        }
        func day(of input: DateInput) -> CalendarDay {
            switch input {
            case .day(let day): day
            case .moment(let date, _): dates.day(of: date)
            }
        }
        let startInput = try parse("start")
        let endInput = try parse("end")

        var event: CalendarEvent
        if let existing {
            event = existing
        } else {
            guard let title = change["title"]?.trimmedString, !title.isEmpty else { throw ToolInputError("a new event needs a title.") }
            guard startInput != nil else { throw ToolInputError("a new event needs a start.") }
            guard let target = calendars.first(where: { $0.isDefault && $0.allowsChanges }) ?? calendars.first(where: \.allowsChanges) else {
                throw ToolInputError("there is no calendar to add an event to.")
            }
            event = CalendarEvent(identifier: "", title: title, start: .distantPast, end: .distantPast, calendarID: target.id)
        }

        var edits: [String] = []
        let startIsDay = if case .day? = startInput { true } else { false }
        let allDay = change["all_day"]?.boolValue ?? (startInput != nil ? startIsDay : (existing?.isAllDay ?? false))
        if allDay {
            let startDay = startInput.map(day(of:)) ?? dates.day(of: event.start)
            let endDay: CalendarDay
            if let endInput {
                endDay = day(of: endInput)
            } else if let existing, existing.isAllDay {
                let lastDay = max(dates.day(of: existing.end.addingTimeInterval(-1)), dates.day(of: existing.start))
                let length = calendar.dateComponents([.day], from: dates.day(of: existing.start).start(in: calendar), to: lastDay.start(in: calendar)).day ?? 0
                endDay = startInput == nil ? lastDay : startDay.adding(days: length, in: calendar)
            } else {
                endDay = startDay
            }
            guard endDay >= startDay else { throw ToolInputError("the event would end before it starts.") }
            event.start = startDay.start(in: calendar)
            event.end = endDay.adding(days: 1, in: calendar).start(in: calendar).addingTimeInterval(-1)
        } else {
            let start: Date
            switch startInput {
            case .moment(let date, _)?: start = date
            case .day?: throw ToolInputError("start needs a time, or set all_day to true.")
            case nil:
                if let existing, existing.isAllDay { throw ToolInputError("give a start time to make it a timed event.") }
                start = event.start
            }
            let end: Date
            switch endInput {
            case .moment(let date, _)?: end = date
            case .day?: throw ToolInputError("end needs a time for an event that is not all day.")
            case nil:
                if let existing, !existing.isAllDay { end = start.addingTimeInterval(existing.end.timeIntervalSince(existing.start)) }
                else { end = start.addingTimeInterval(3600) }
            }
            guard end > start else { throw ToolInputError("the event would end before it starts.") }
            event.start = start
            event.end = end
        }
        event.isAllDay = allDay
        if let existing, event.start != existing.start || event.end != existing.end || allDay != existing.isAllDay {
            edits.append("to \(formatter.when(event))")
        }

        if let title = change["title"]?.trimmedString {
            guard !title.isEmpty else { throw ToolInputError("the title cannot be empty.") }
            if existing != nil, title != event.title { edits.append("title \"\(title)\"") }
            event.title = title
        }
        for key in ["location", "notes"] {
            guard let value = change[key]?.stringValue else { continue }
            let cleared = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if key == "location" { event.location = cleared ? nil : value } else { event.notes = cleared ? nil : value }
            if existing != nil { edits.append(cleared ? "remove the \(key)" : "new \(key)") }
        }
        if let name = change["calendar"]?.trimmedString, !name.isEmpty {
            switch PersonalDataText.resolve(name, in: calendars.map(\.named), noun: "calendar") {
            case .success(let found):
                if existing != nil, found.id != event.calendarID { edits.append("move to \(formatter.calendarName(found.id))") }
                event.calendarID = found.id
            case .failure(let error): throw error
            }
        }
        for id in Set([event.calendarID, existing?.calendarID].compactMap { $0 }) {
            if let info = calendars.first(where: { $0.id == id }), !info.allowsChanges {
                throw ToolInputError("the calendar \(formatter.calendarName(id)) is read only.")
            }
        }

        let future = includeFuture && (existing?.isRecurring ?? false)
        let description: String
        if let existing {
            description = "Change \"\(existing.title)\" (\(formatter.when(existing)))\(future ? " and its later occurrences" : ""): "
                + (edits.isEmpty ? "no visible change" : edits.joined(separator: ", "))
        } else {
            description = "Create \"\(event.title)\" in \(formatter.calendarName(event.calendarID)), \(formatter.when(event))"
        }
        return Plan(kind: existing == nil ? .create : .update, event: event, includingFuture: future, description: description)
    }

    /// Finds the occurrence a short id names. The id is the hash of the event's identifier,
    /// followed for a repeating event by when the occurrence was scheduled, in UTC.
    private func find(_ short: String) async throws -> CalendarEvent? {
        let parts = short.lowercased().split(separator: "-", maxSplits: 1).map(String.init)
        let base = parts[0]
        let occurrence = parts.count > 1 ? EventText.occurrenceDate(from: parts[1]) : nil
        if parts.count > 1, occurrence == nil { return nil }
        if let long = await identifiers.long(for: base) {
            return try await store.event(identifier: long, occurrenceDate: occurrence)
        }
        // An id from an earlier run of the app. Look through the events around it.
        let around = occurrence ?? now()
        let window: TimeInterval = occurrence == nil ? 366 * 86_400 : 2 * 86_400
        let candidates = try await store.events(from: around.addingTimeInterval(-window), to: around.addingTimeInterval(window), inCalendars: nil)
        guard let found = candidates.first(where: { EventText.shortIdentifier($0) == short.lowercased() })
            ?? candidates.first(where: { ShortIdentifierTable.short($0.identifier) == base && occurrence == nil })
        else { return nil }
        await identifiers.remember(found.identifier)
        return found
    }
}

/// How the calendar tools write an event for the model.
struct EventText {
    let dates: LocalDates
    let names: [String: String]
    let readOnly: Set<String>

    init(dates: LocalDates, calendars: [CalendarInfo]) {
        self.dates = dates
        self.names = PersonalDataText.displayNames(calendars.map(\.named))
        self.readOnly = Set(calendars.filter { !$0.allowsChanges }.map(\.id))
    }

    func calendarName(_ id: String) -> String { names[id] ?? "(unknown calendar)" }

    /// The hash of the identifier, and for a repeating event when this occurrence was
    /// scheduled in UTC, such as `3f9a2c1b-202611211700`.
    static func shortIdentifier(_ event: CalendarEvent) -> String {
        let base = ShortIdentifierTable.short(event.identifier)
        guard event.isRecurring else { return base }
        return "\(base)-\(occurrenceFormatter.string(from: event.occurrenceDate))"
    }

    static func occurrenceDate(from text: String) -> Date? {
        occurrenceFormatter.date(from: text)
    }

    private static let occurrenceFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmm"
        return formatter
    }()

    /// `Sat 2026-11-21 14:00 to 15:00`, `Sat 2026-11-21, all day`, or `Sat 2026-11-21 to Mon 2026-11-23, all day`.
    func when(_ event: CalendarEvent) -> String {
        if event.isAllDay {
            let first = dates.day(of: event.start)
            let last = max(first, dates.day(of: event.end.addingTimeInterval(-1)))
            return first == last ? "\(dates.text(first)), all day" : "\(dates.text(first)) to \(dates.text(last)), all day"
        }
        if dates.day(of: event.start) == dates.day(of: event.end) {
            return "\(dates.text(event.start)) to \(dates.timeText(event.end))"
        }
        return "\(dates.text(event.start)) to \(dates.text(event.end))"
    }

    /// `3f9a2c1b | Lunch with Sam | Sat 2026-11-21 12:00 to 13:00 | Home | at: Café | repeats | notes: …`.
    func line(_ event: CalendarEvent) -> String {
        var parts = [Self.shortIdentifier(event), event.title, when(event), calendarName(event.calendarID)]
        if let location = event.location, !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("at: \(PersonalDataText.clipped(location, to: 100))")
        }
        if event.isRecurring { parts.append("repeats") }
        if readOnly.contains(event.calendarID) { parts.append("read only") }
        if let notes = event.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("notes: \(PersonalDataText.clipped(notes))")
        }
        return parts.joined(separator: " | ")
    }
}
