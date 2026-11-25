import Foundation

/// Everything a provider needs for one model reply.
public struct ModelRequest: Sendable {
    /// Standing instructions. They do not change within a conversation.
    public var instructions: String
    /// The current episode, oldest first, without its marker.
    public var entries: [ThreadEntry]
    /// The fixed tool list.
    public var tools: [ToolDefinition]
    /// Whether the provider's own hosted web search is offered beside the tools. It is fixed
    /// for a run, like the tool list. False sends the request exactly as before web search.
    public var webSearch: Bool

    public init(instructions: String, entries: [ThreadEntry], tools: [ToolDefinition], webSearch: Bool = false) {
        self.instructions = instructions
        self.entries = entries
        self.tools = tools
        self.webSearch = webSearch
    }
}

/// What a provider reports while a reply streams in.
public enum ModelStreamEvent: Sendable, Equatable {
    /// More of the text the model is writing.
    case textDelta(String)
    /// The model began a tool call. Its arguments arrive later, with the finished item.
    case toolCallStarted(callID: String, name: String)
    /// The model began a tool that runs on the provider's side, such as a hosted web search.
    /// Nothing runs in the app. The finished call arrives later as a provider item.
    case hostedToolStarted(HostedToolCall)
    /// A finished piece of the reply, ready to be added to the thread.
    case item(ThreadItem)
    /// The token counts for the request, reported once it is complete.
    case usage(TokenUsage, provider: String, model: String)
    /// Digests of what the request sent, reported before the reply. See `RequestDigest`.
    case requestSent(items: [String])
}

/// The seam between the loop and a model API. The loop knows nothing about any one API.
public protocol ModelProvider: Sendable {
    /// Streams one reply. The stream ends when the reply is complete and throws when it fails.
    func streamReply(to request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error>
}
