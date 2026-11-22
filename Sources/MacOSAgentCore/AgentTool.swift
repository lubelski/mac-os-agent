import Foundation

/// How a tool is described to the model.
public struct ToolDefinition: Sendable, Equatable {
    public var name: String
    public var description: String
    /// A JSON Schema object for the arguments.
    public var parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// What a tool wants to do, shown to the owner when it needs their go-ahead. It describes
/// itself: the card's question and buttons, what it lists, and the line under the tool's row
/// while it waits. None of it is sent to the model.
public struct ConfirmationRequest: Sendable, Equatable, Identifiable {
    /// What kind of action is asking, which sets the wording.
    public enum Kind: Sendable, Equatable {
        case shellCommand
        case reminderChanges
        case eventChanges
        case quitApplication
        case deleteTheme
    }

    /// One change in a list of them, such as deleting one reminder.
    public struct Change: Sendable, Equatable {
        public enum Action: String, Sendable, Equatable {
            case create = "Create"
            case change = "Change"
            case delete = "Delete"
        }

        public var action: Action
        /// What the change is to, after the action's word, such as `"Buy eggs" from Groceries`.
        public var subject: String

        public init(_ action: Action, _ subject: String) {
            self.action = action
            self.subject = subject
        }

        /// The change as one line, such as `Delete "Buy eggs" from Groceries`.
        public var text: String { "\(action.rawValue) \(subject)" }
    }

    /// What the card shows under its question.
    public enum Body: Sendable, Equatable {
        /// A shell command, shown as code.
        case command(String)
        /// A list of changes, one per line.
        case changes([Change])
        /// The one thing acted on, such as an app or a theme, by its name and a detail.
        case item(name: String, detail: String?)
    }

    public var id: String { callID }
    public var callID: String
    public var kind: Kind
    public var body: Body
    /// Why it needs a go-ahead, in a few words that follow "It", such as "deletes a reminder".
    public var reason: String

    public init(callID: String, kind: Kind, body: Body, reason: String) {
        self.callID = callID
        self.kind = kind
        self.body = body
        self.reason = reason
    }

    /// A shell command.
    public init(callID: String, command: String, reason: String) {
        self.init(callID: callID, kind: .shellCommand, body: .command(command), reason: reason)
    }

    private var changeCount: Int {
        if case .changes(let changes) = body { changes.count } else { 1 }
    }

    private var itemName: String? {
        if case .item(let name, _) = body { name } else { nil }
    }

    /// The question the card asks, such as "Run this command?".
    public var question: String {
        switch kind {
        case .shellCommand: "Run this command?"
        case .reminderChanges: changeCount == 1 ? "Make this change in Reminders?" : "Make these \(changeCount) changes in Reminders?"
        case .eventChanges: changeCount == 1 ? "Make this change in Calendar?" : "Make these \(changeCount) changes in Calendar?"
        case .quitApplication: "Quit this app?"
        case .deleteTheme: "Delete this theme?"
        }
    }

    /// The card's first line: the question and the reason, such as
    /// "Run this command? It deletes files."
    public var prompt: String {
        "\(question) It \(reason)."
    }

    /// The button that goes ahead.
    public var approveTitle: String {
        switch kind {
        case .shellCommand: "Run"
        case .reminderChanges, .eventChanges: changeCount == 1 ? "Make Change" : "Make Changes"
        case .quitApplication: "Quit"
        case .deleteTheme: "Delete"
        }
    }

    /// The button that declines.
    public var declineTitle: String {
        switch kind {
        case .shellCommand: "Don’t Run"
        case .reminderChanges, .eventChanges: "Don’t Change"
        case .quitApplication: "Don’t Quit"
        case .deleteTheme: "Don’t Delete"
        }
    }

    /// The line under the tool's row while it waits.
    public var waitingText: String {
        let waiting = "waiting for your go-ahead"
        switch kind {
        case .shellCommand:
            return waiting
        case .reminderChanges, .eventChanges:
            let noun = kind == .reminderChanges ? "a reminder" : "an event"
            if case .changes(let changes) = body, changes.count == 1 {
                return "\(waiting) to \(changes[0].action.rawValue.lowercased()) \(noun)"
            }
            return "\(waiting) to make \(changeCount) changes in \(kind == .reminderChanges ? "Reminders" : "Calendar")"
        case .quitApplication:
            return itemName.map { "\(waiting) to quit \($0)" } ?? waiting
        case .deleteTheme:
            return itemName.map { "\(waiting) to delete the theme \($0)" } ?? waiting
        }
    }

    /// The body as plain text: the command, one change per line, or the item and its detail.
    public var text: String {
        switch body {
        case .command(let command): command
        case .changes(let changes): changes.map(\.text).joined(separator: "\n")
        case .item(let name, let detail): detail.map { "\(name) (\($0))" } ?? name
        }
    }
}

/// What a tool can reach while it runs.
public struct ToolRunContext: Sendable {
    public var callID: String
    /// The episode the call was made in. History search leaves it out, since the model already
    /// sees it.
    public var episodeID: UUID?
    /// Asks the person whether to go ahead. Waits as long as it takes.
    public var confirm: @Sendable (ConfirmationRequest) async -> Bool
    /// Where the tool notes facts about its run for the inspector, such as an exit status.
    /// What it notes is stored beside the result and never reaches the model.
    public var report: ToolRunReport

    public init(
        callID: String, episodeID: UUID? = nil, report: ToolRunReport = ToolRunReport(),
        confirm: @escaping @Sendable (ConfirmationRequest) async -> Bool
    ) {
        self.callID = callID
        self.episodeID = episodeID
        self.report = report
        self.confirm = confirm
    }
}

/// A tool the model can call. The set of tools is fixed for a conversation, because a tool
/// list that changes partway through breaks prompt caching.
public protocol AgentTool: Sendable {
    var definition: ToolDefinition { get }
    /// Where the tool comes from. Built in unless the tool says otherwise.
    var source: ToolSource { get }
    /// When the tool waits for the owner's go-ahead, as shown in Settings. Never unless the
    /// tool says otherwise.
    var goAhead: ToolGoAhead { get }
    /// A one-line summary of a call for the panel, such as the command being run.
    func summary(arguments: JSONValue) -> String
    /// Runs the tool. The returned text is what the model reads as the result.
    func run(arguments: JSONValue, context: ToolRunContext) async -> String
}
