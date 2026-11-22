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

/// A command a tool wants to run, shown to the person when it needs their go-ahead.
public struct ConfirmationRequest: Sendable, Equatable, Identifiable {
    public var id: String { callID }
    public var callID: String
    public var command: String
    /// Why the command needs a go-ahead, in a few words.
    public var reason: String

    public init(callID: String, command: String, reason: String) {
        self.callID = callID
        self.command = command
        self.reason = reason
    }
}

/// What a tool can reach while it runs.
public struct ToolRunContext: Sendable {
    public var callID: String
    /// The episode the call was made in. History search leaves it out, since the model already
    /// sees it. An incognito episode's id is never in the kept thread, so nothing is left out.
    public var episodeID: UUID?
    /// Asks the person whether to go ahead. Waits as long as it takes.
    public var confirm: @Sendable (ConfirmationRequest) async -> Bool

    public init(callID: String, episodeID: UUID? = nil, confirm: @escaping @Sendable (ConfirmationRequest) async -> Bool) {
        self.callID = callID
        self.episodeID = episodeID
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
