import Foundation

/// Reads the owner's reminders, with the lists they are in.
public struct ReadRemindersTool: AgentTool {
    public static let name = "read_reminders"
    public static let defaultLimit = 50
    public static let maximumLimit = 200

    public let store: any ReminderStore
    public let identifiers: ShortIdentifierTable
    public let dates: LocalDates
    public let now: @Sendable () -> Date

    public init(
        store: any ReminderStore, identifiers: ShortIdentifierTable, dates: LocalDates = LocalDates(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.identifiers = identifiers
        self.dates = dates
        self.now = now
    }

    public var source: ToolSource { .reminders }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: Self.name,
            description: """
                Read the owner's reminders in the Reminders app. Returns the lists, then the reminders \
                that match, each with an id for \(ChangeRemindersTool.name). Incomplete reminders come \
                soonest due first, completed ones most recently completed first.
                """,
            parameters: Schema.object([
                "list": Schema.nullableString("A list's name as this tool shows it. Null for every list."),
                "status": ["type": "string", "enum": ["incomplete", "completed", "all"], "description": "Which reminders to read."],
                "due_from": Schema.nullableString("Only reminders due at or after this ISO 8601 date or date-time, such as 2026-11-21 or 2026-11-21T09:00. Null for no lower bound."),
                "due_to": Schema.nullableString("Only reminders due by the end of this date, or before this date-time. Null for no upper bound."),
                "text": Schema.nullableString("Words that must all appear in the title or notes. Null for any."),
                "limit": Schema.nullableInteger("The most reminders to return, up to \(Self.maximumLimit). Null for \(Self.defaultLimit)."),
            ]))
    }

    public func summary(arguments: JSONValue) -> String {
        var parts = ["Read \(arguments["status"]?.stringValue ?? "incomplete") reminders"]
        if let list = arguments["list"]?.trimmedString, !list.isEmpty { parts.append("in \(list)") }
        if let text = arguments["text"]?.trimmedString, !text.isEmpty { parts.append("matching \"\(text)\"") }
        return parts.joined(separator: " ")
    }

    public func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        let status = arguments["status"]?.stringValue.flatMap(ReminderStatusFilter.init(rawValue:)) ?? .incomplete
        var from: Date?
        var to: Date?
        for (key, isEnd) in [("due_from", false), ("due_to", true)] {
            guard let text = arguments[key]?.trimmedString, !text.isEmpty else { continue }
            guard let input = dates.parse(text) else {
                return "Error: \(key) \"\(text)\" is not an ISO 8601 date or date-time such as 2026-11-21 or 2026-11-21T09:00."
            }
            if isEnd { to = dates.endOfRange(reaching: input) } else { from = dates.start(of: input) }
        }
        let text = arguments["text"]?.trimmedString.flatMap { $0.isEmpty ? nil : $0 }
        let limit = min(max(arguments["limit"]?.numberValue.map { Int($0) } ?? Self.defaultLimit, 1), Self.maximumLimit)

        if let error = await store.ensureFullAccess(.reminders) { return error }
        do {
            let lists = try await store.reminderLists()
            var listIDs: [String]?
            if let name = arguments["list"]?.trimmedString, !name.isEmpty {
                switch PersonalDataText.resolve(name, in: lists.map(\.named), noun: "list") {
                case .success(let list): listIDs = [list.id]
                case .failure(let error): return "Error: \(error.message)"
                }
            }
            var reminders = try await store.reminders(inLists: listIDs, status: status)
            if from != nil || to != nil {
                reminders = reminders.filter { reminder in
                    guard let due = reminder.due else { return false }
                    let date = ReminderText.sortDate(due, dates: dates)
                    return (from.map { date >= $0 } ?? true) && (to.map { date < $0 } ?? true)
                }
            }
            if let text {
                reminders = reminders.filter { PersonalDataText.matches(text, fields: [$0.title, $0.notes]) }
            }
            reminders.sort { ReminderText.ordered($0, $1, dates: dates) }
            let total = reminders.count
            let shown = Array(reminders.prefix(limit))
            await identifiers.rememberAll(shown.map(\.identifier))

            let formatter = ReminderText(dates: dates, lists: lists, now: now())
            var lines = ["Lists: \(PersonalDataText.summary(lists.map(\.named))). \(dates.timeZoneNote)"]
            let noun = status == .all ? "reminder" : "\(status.rawValue) reminder"
            if shown.isEmpty {
                lines.append("No \(noun)s match.")
            } else {
                let order = status == .completed ? "most recently completed first" : "soonest due first"
                lines.append("\(total) \(noun)\(total == 1 ? "" : "s"), \(order), as id | title | list | details:")
                lines += shown.map(formatter.line)
                if total > shown.count {
                    lines.append("Showing the first \(shown.count) of \(total). Narrow by list, due dates, or text to see the others.")
                }
            }
            return lines.joined(separator: "\n")
        } catch {
            return "Error: Reminders could not be read: \(error.localizedDescription)"
        }
    }
}

/// Creates, changes, completes, and deletes reminders, one or several in a call.
public struct ChangeRemindersTool: AgentTool {
    public static let name = "change_reminders"
    public static let maximumChanges = 50
    static let fields = ["title", "notes", "list", "due", "priority", "completed"]

    public let store: any ReminderStore
    public let identifiers: ShortIdentifierTable
    public let dates: LocalDates

    public init(store: any ReminderStore, identifiers: ShortIdentifierTable, dates: LocalDates = LocalDates()) {
        self.store = store
        self.identifiers = identifiers
        self.dates = dates
    }

    public var source: ToolSource { .reminders }

    public var goAhead: ToolGoAhead {
        .sometimes("Asks before deleting a reminder, and before any call that changes more than one reminder.")
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: Self.name,
            description: """
                Create, edit, complete, or delete reminders. A change with a null id creates a reminder. \
                A change with an id from \(ReadRemindersTool.name) edits that reminder, and its null \
                fields stay as they are. A date alone is due that day. A date-time without an offset is \
                local time and also sets an alert then. Deleting, or changing more than one reminder in \
                a call, asks the owner first.
                """,
            parameters: Schema.object([
                "changes": [
                    "type": "array",
                    "description": "The changes, carried out in order.",
                    "items": Schema.object([
                        "id": Schema.nullableString("The reminder's id, or null to create one."),
                        "delete": ["type": "boolean", "description": "True to delete the reminder with this id. False otherwise."],
                        "title": Schema.nullableString("The title. Required to create."),
                        "notes": Schema.nullableString("Notes. An empty string removes them."),
                        "list": Schema.nullableString("The list's name. On create, null uses the default list."),
                        "due": Schema.nullableString("ISO 8601 date or date-time, such as 2026-11-21 or 2026-11-21T15:00. \"none\" removes it."),
                        "priority": Schema.nullableChoice(["none", "low", "medium", "high"], "The priority."),
                        "completed": Schema.nullableBoolean("True marks it done, false marks it not done."),
                    ]),
                ],
            ]))
    }

    public func summary(arguments: JSONValue) -> String {
        let changes = arguments["changes"]?.arrayValue ?? []
        if changes.count == 1, let change = changes.first {
            let title = change["title"]?.trimmedString.map { " \"\($0)\"" } ?? ""
            if change["delete"]?.boolValue == true { return "Delete a reminder" }
            if change["id"]?.trimmedString == nil { return "Create reminder\(title)" }
            if change["completed"]?.boolValue == true { return "Complete a reminder" }
            return "Change reminder\(title)"
        }
        return "Change \(changes.count) reminders"
    }

    enum Kind: Equatable { case create, update, delete }

    struct Plan {
        var kind: Kind
        var reminder: Reminder
        var dueChanged: Bool
        var description: String
    }

    public func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        guard let changes = arguments["changes"]?.arrayValue, !changes.isEmpty else {
            return "Error: the call did not include any changes."
        }
        guard changes.count <= Self.maximumChanges else {
            return "Error: a call can make at most \(Self.maximumChanges) changes. Split them up."
        }
        if let error = await store.ensureFullAccess(.reminders) { return error }

        let lists: [ReminderList]
        do {
            lists = try await store.reminderLists()
        } catch {
            return "Error: Reminders could not be read: \(error.localizedDescription)"
        }
        let names = PersonalDataText.displayNames(lists.map(\.named))
        var plans: [Plan] = []
        var problems: [String] = []
        var everyReminder: [Reminder]?
        for (index, change) in changes.enumerated() {
            do {
                plans.append(try await plan(change, lists: lists, names: names, everyReminder: &everyReminder))
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
        if let reason = Self.reasonToConfirm(count: plans.count, deletions: deletions, noun: "reminder") {
            let approved = await context.confirm(ConfirmationRequest(
                callID: context.callID, command: plans.map(\.description).joined(separator: "\n"), reason: reason))
            if !approved { return "The owner declined. Nothing was changed." }
        }
        if Task.isCancelled { return "The task was stopped before anything was changed." }

        let formatter = ReminderText(dates: dates, lists: lists, now: Date())
        var results: [String] = []
        for (index, plan) in plans.enumerated() {
            do {
                switch plan.kind {
                case .delete:
                    try await store.deleteReminder(identifier: plan.reminder.identifier)
                    results.append("Deleted \"\(plan.reminder.title)\" from \(names[plan.reminder.listID] ?? "its list").")
                case .create, .update:
                    let saved = try await store.save(plan.reminder, dueChanged: plan.dueChanged)
                    await identifiers.remember(saved.identifier)
                    results.append((plan.kind == .create ? "Created " : "Updated ") + formatter.line(saved))
                }
            } catch {
                results.append("Error on change \(index + 1) (\(plan.description)): \(error.localizedDescription)")
            }
        }
        return results.joined(separator: "\n")
    }

    /// The reason for a go-ahead, worded to follow "It", or nil when the call needs none.
    static func reasonToConfirm(count: Int, deletions: Int, noun: String) -> String? {
        if count > 1 {
            let deleting = deletions == 0 ? "" : deletions == count ? ", deleting all of them" : ", deleting \(deletions)"
            return "changes \(count) \(noun)s at once\(deleting)"
        }
        let article = "aeiou".contains(noun.first ?? "x") ? "an" : "a"
        return deletions > 0 ? "deletes \(article) \(noun)" : nil
    }

    private func plan(_ change: JSONValue, lists: [ReminderList], names: [String: String], everyReminder: inout [Reminder]?) async throws -> Plan {
        let short = change["id"]?.trimmedString.flatMap { $0.isEmpty ? nil : $0 }
        let delete = change["delete"]?.boolValue ?? false
        let given = Self.fields.filter { key in
            guard let value = change[key], value != .null else { return false }
            return true
        }

        var reminder: Reminder
        let kind: Kind
        if let short {
            guard let existing = try await find(short, everyReminder: &everyReminder) else {
                throw ToolInputError("no reminder has the id \(short). Read the reminders again for current ids.")
            }
            reminder = existing
            if delete {
                return Plan(kind: .delete, reminder: existing, dueChanged: false,
                            description: "Delete \"\(existing.title)\" from \(names[existing.listID] ?? "its list")")
            }
            guard !given.isEmpty else { throw ToolInputError("the change for \(short) has nothing to change.") }
            kind = .update
        } else {
            guard !delete else { throw ToolInputError("deleting needs the reminder's id.") }
            guard let title = change["title"]?.trimmedString, !title.isEmpty else {
                throw ToolInputError("a new reminder needs a title.")
            }
            guard let list = lists.first(where: \.isDefault) ?? lists.first(where: \.allowsChanges) else {
                throw ToolInputError("there is no list to add a reminder to.")
            }
            reminder = Reminder(identifier: "", title: title, listID: list.id)
            kind = .create
        }

        var edits: [String] = []
        if let title = change["title"]?.trimmedString {
            guard !title.isEmpty else { throw ToolInputError("the title cannot be empty.") }
            if kind == .update, title != reminder.title { edits.append("title \"\(title)\"") }
            reminder.title = title
        }
        if let notes = change["notes"]?.stringValue {
            let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            reminder.notes = trimmed.isEmpty ? nil : notes
            edits.append(trimmed.isEmpty ? "remove the notes" : "new notes")
        }
        if let name = change["list"]?.trimmedString, !name.isEmpty {
            switch PersonalDataText.resolve(name, in: lists.map(\.named), noun: "list") {
            case .success(let list):
                if kind == .update, list.id != reminder.listID { edits.append("move to \(names[list.id] ?? list.title)") }
                reminder.listID = list.id
            case .failure(let error): throw error
            }
        }
        if let list = lists.first(where: { $0.id == reminder.listID }), !list.allowsChanges {
            throw ToolInputError("the list \(names[list.id] ?? list.title) is read only.")
        }
        var dueChanged = false
        if let text = change["due"]?.trimmedString, !text.isEmpty {
            if text.lowercased() == "none" {
                dueChanged = reminder.due != nil
                reminder.due = nil
                if dueChanged { edits.append("remove the due date") }
            } else {
                guard let input = dates.parse(text) else {
                    throw ToolInputError("due \"\(text)\" is not an ISO 8601 date or date-time such as 2026-11-21 or 2026-11-21T15:00.")
                }
                switch input {
                case .day(let day): reminder.due = .day(day)
                case .moment(let date, _): reminder.due = .moment(date)
                }
                dueChanged = true
                edits.append("due \(ReminderText.dueText(reminder.due, dates: dates))")
            }
        }
        if let priority = change["priority"]?.stringValue {
            guard let value = ReminderText.priorities[priority] else {
                throw ToolInputError("priority \"\(priority)\" is not one of none, low, medium, high.")
            }
            reminder.priority = value
            edits.append("priority \(priority)")
        }
        if let completed = change["completed"]?.boolValue {
            if kind == .update, completed != reminder.isCompleted { edits.append(completed ? "mark done" : "mark not done") }
            reminder.isCompleted = completed
        }

        let listName = names[reminder.listID] ?? "its list"
        let description: String
        if kind == .create {
            var details = [String]()
            if let due = reminder.due { details.append("due \(ReminderText.dueText(due, dates: dates))") }
            if reminder.priority > 0 { details.append("\(ReminderText.priorityName(reminder.priority)) priority") }
            description = "Create \"\(reminder.title)\" in \(listName)" + (details.isEmpty ? "" : ", " + details.joined(separator: ", "))
        } else {
            description = "Change \"\(reminder.title)\" in \(listName): " + (edits.isEmpty ? "no visible change" : edits.joined(separator: ", "))
        }
        return Plan(kind: kind, reminder: reminder, dueChanged: dueChanged, description: description)
    }

    private func find(_ short: String, everyReminder: inout [Reminder]?) async throws -> Reminder? {
        if let long = await identifiers.long(for: short) {
            return try await store.reminder(identifier: long)
        }
        // An id from an earlier run of the app. Find it by hashing every reminder's identifier.
        if everyReminder == nil {
            everyReminder = try await store.reminders(inLists: nil, status: .all)
        }
        let found = everyReminder?.first { ShortIdentifierTable.short($0.identifier) == short.lowercased() }
        if let found { await identifiers.remember(found.identifier) }
        return found
    }
}

/// How the reminder tools write a reminder for the model.
struct ReminderText {
    let dates: LocalDates
    let names: [String: String]
    let now: Date

    init(dates: LocalDates, lists: [ReminderList], now: Date) {
        self.dates = dates
        self.names = PersonalDataText.displayNames(lists.map(\.named))
        self.now = now
    }

    static let priorities = ["none": 0, "high": 1, "medium": 5, "low": 9]

    static func priorityName(_ value: Int) -> String {
        switch value {
        case 1...4: "high"
        case 5: "medium"
        case 6...9: "low"
        default: "none"
        }
    }

    static func dueText(_ due: ReminderDue?, dates: LocalDates) -> String {
        switch due {
        case .day(let day)?: dates.text(day)
        case .moment(let date)?: dates.text(date)
        case nil: "none"
        }
    }

    static func sortDate(_ due: ReminderDue, dates: LocalDates) -> Date {
        switch due {
        case .day(let day): day.start(in: dates.calendar)
        case .moment(let date): date
        }
    }

    /// Completed ones last, most recently completed first. The rest by due date, those with
    /// none last, then by priority, then by title.
    static func ordered(_ a: Reminder, _ b: Reminder, dates: LocalDates) -> Bool {
        if a.isCompleted != b.isCompleted { return !a.isCompleted }
        if a.isCompleted {
            return (a.completionDate ?? .distantPast) > (b.completionDate ?? .distantPast)
        }
        let aDue = a.due.map { sortDate($0, dates: dates) } ?? .distantFuture
        let bDue = b.due.map { sortDate($0, dates: dates) } ?? .distantFuture
        if aDue != bDue { return aDue < bDue }
        let aPriority = a.priority == 0 ? 10 : a.priority
        let bPriority = b.priority == 0 ? 10 : b.priority
        if aPriority != bPriority { return aPriority < bPriority }
        return a.title.localizedStandardCompare(b.title) == .orderedAscending
    }

    /// `3f9a2c1b | Buy milk | Groceries | due Sat 2026-11-21 15:00, overdue | high priority | notes: …`.
    func line(_ reminder: Reminder) -> String {
        var parts = [ShortIdentifierTable.short(reminder.identifier), reminder.title, names[reminder.listID] ?? "(unknown list)"]
        if let due = reminder.due {
            var text = "due \(Self.dueText(due, dates: dates))"
            if !reminder.isCompleted {
                let overdue = switch due {
                case .day(let day): day < dates.day(of: now)
                case .moment(let date): date < now
                }
                if overdue { text += ", overdue" }
            }
            parts.append(text)
        }
        if reminder.priority > 0 { parts.append("\(Self.priorityName(reminder.priority)) priority") }
        if reminder.isCompleted {
            parts.append(reminder.completionDate.map { "done \(dates.text($0))" } ?? "done")
        }
        if let notes = reminder.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("notes: \(PersonalDataText.clipped(notes))")
        }
        return parts.joined(separator: " | ")
    }
}
