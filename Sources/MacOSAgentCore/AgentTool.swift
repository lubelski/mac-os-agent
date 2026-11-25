import Foundation

/// How a tool is described to the model.
public struct ToolDefinition: Sendable, Equatable {
    public var name: String
    public var description: String
    /// A JSON Schema object for the arguments.
    public var parameters: JSONValue
    /// The model is held to the schema exactly. The built-in tools' schemas are written for
    /// that. A schema from an MCP server is not, so its tools are sent without it.
    public var strict: Bool

    public init(name: String, description: String, parameters: JSONValue, strict: Bool = true) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.strict = strict
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
        case deleteQuickAction
        /// A tool from an MCP server.
        case mcpToolCall
        /// A change to the app's own setup, from `change_settings`.
        case settingsChange
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
        /// A call to a tool on an MCP server, with its arguments as indented JSON.
        case toolCall(server: String, tool: String, arguments: String)
        /// A change to the app's setup in plain words, such as "Add the MCP server figma", and
        /// lines about it, such as the command it runs and when it takes effect.
        case setting(change: String, notes: [String])
    }

    public var id: String { callID }
    public var callID: String
    public var kind: Kind
    public var body: Body
    /// Why it needs a go-ahead, in a few words that follow "It", such as "deletes a reminder".
    public var reason: String
    /// A call made by a `run_script` script. The card says so, and declining does not end the
    /// row, since the script runs on.
    public var fromScript = false

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

    private var toolCallName: String? {
        if case .toolCall(_, let tool, _) = body { tool } else { nil }
    }

    /// The question the card asks, such as "Run this command?".
    public var question: String {
        switch kind {
        case .shellCommand: "Run this command?"
        case .reminderChanges: changeCount == 1 ? "Make this change in Reminders?" : "Make these \(changeCount) changes in Reminders?"
        case .eventChanges: changeCount == 1 ? "Make this change in Calendar?" : "Make these \(changeCount) changes in Calendar?"
        case .quitApplication: "Quit this app?"
        case .deleteTheme: "Delete this theme?"
        case .deleteQuickAction: "Delete this quick action?"
        case .mcpToolCall: "Call this tool?"
        case .settingsChange: "Change this setting?"
        }
    }

    /// The card's first line: the question and the reason, such as
    /// "Run this command? It deletes files."
    public var prompt: String {
        "\(question) It \(reason)." + (fromScript ? " A script is asking." : "")
    }

    /// The button that goes ahead.
    public var approveTitle: String {
        switch kind {
        case .shellCommand: "Run"
        case .reminderChanges, .eventChanges: changeCount == 1 ? "Make Change" : "Make Changes"
        case .quitApplication: "Quit"
        case .deleteTheme, .deleteQuickAction: "Delete"
        case .mcpToolCall: "Call"
        case .settingsChange: "Change"
        }
    }

    /// A third button that goes ahead and stops this tool asking from now on, or nil for a card
    /// with only two. Only an MCP tool's card has it, since its go-ahead is a setting per tool.
    public var alwaysApproveTitle: String? {
        kind == .mcpToolCall ? "Always Call" : nil
    }

    /// The line under the buttons that says where to turn asking back on, for a card with the
    /// third button.
    public var alwaysApproveNote: String? {
        kind == .mcpToolCall ? "Always Call stops asking for this tool. Settings > Tools turns asking back on." : nil
    }

    /// The button that declines.
    public var declineTitle: String {
        switch kind {
        case .shellCommand: "Don’t Run"
        case .reminderChanges, .eventChanges: "Don’t Change"
        case .quitApplication: "Don’t Quit"
        case .deleteTheme, .deleteQuickAction: "Don’t Delete"
        case .mcpToolCall: "Don’t Call"
        case .settingsChange: "Don’t Change"
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
        case .deleteQuickAction:
            return itemName.map { "\(waiting) to delete the quick action \($0)" } ?? waiting
        case .mcpToolCall:
            return toolCallName.map { "\(waiting) to call \($0)" } ?? waiting
        case .settingsChange:
            return "\(waiting) to change a setting"
        }
    }

    /// The body as plain text: the command, one change per line, or the item and its detail.
    public var text: String {
        switch body {
        case .command(let command): command
        case .changes(let changes): changes.map(\.text).joined(separator: "\n")
        case .item(let name, let detail): detail.map { "\(name) (\($0))" } ?? name
        case .toolCall(let server, let tool, let arguments): "\(tool) on \(server)\n\(arguments)"
        case .setting(let change, let notes): ([change] + notes).joined(separator: "\n")
        }
    }
}

/// The owner's answer to a go-ahead card.
public enum ConfirmationAnswer: Sendable, Equatable {
    case declined
    case approved
    /// Go ahead, and stop asking before this tool from now on. Only a card with
    /// `alwaysApproveTitle` offers it. The tool that asked records the setting.
    case approvedAlways

    public var isApproved: Bool { self != .declined }
}

/// What a tool can reach while it runs.
public struct ToolRunContext: Sendable {
    public var callID: String
    /// The episode the call was made in. History search leaves it out, since the model already
    /// sees it.
    public var episodeID: UUID?
    /// Asks the person whether to go ahead, and returns their full answer. Waits as long as it
    /// takes.
    public var answer: @Sendable (ConfirmationRequest) async -> ConfirmationAnswer
    /// Where the tool notes facts about its run for the inspector, such as an exit status.
    /// What it notes is stored beside the result and never reaches the model.
    public var report: ToolRunReport

    public init(
        callID: String, episodeID: UUID? = nil, report: ToolRunReport = ToolRunReport(),
        answer: @escaping @Sendable (ConfirmationRequest) async -> ConfirmationAnswer
    ) {
        self.callID = callID
        self.episodeID = episodeID
        self.report = report
        self.answer = answer
    }

    /// A context whose go-ahead is yes or no, as most callers and tests need.
    public init(
        callID: String, episodeID: UUID? = nil, report: ToolRunReport = ToolRunReport(),
        confirm: @escaping @Sendable (ConfirmationRequest) async -> Bool
    ) {
        self.init(callID: callID, episodeID: episodeID, report: report) { request in
            await confirm(request) ? .approved : .declined
        }
    }

    /// Asks the person whether to go ahead. Either way of going ahead counts as yes.
    public func confirm(_ request: ConfirmationRequest) async -> Bool {
        await answer(request).isApproved
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
