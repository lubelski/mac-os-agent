import Foundation

/// One line of the thread file. The thread only grows: entries are never edited or removed,
/// so every request starts with the same prefix as the one before it and prompt caching works.
public struct ThreadEntry: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var date: Date
    public var item: ThreadItem

    public init(id: UUID = UUID(), date: Date = Date(), item: ThreadItem) {
        self.id = id
        self.date = date
        self.item = item
    }

    private enum CodingKeys: String, CodingKey { case id, date, item }
}

/// What an entry holds. The cases are provider neutral, apart from `providerItem`, which a
/// provider fills with whatever it needs to send the item back exactly as it received it.
public enum ThreadItem: Sendable, Equatable, Codable {
    /// What the person typed into the panel.
    case userMessage(text: String)
    /// Text the model wrote.
    case assistantMessage(AssistantMessage)
    /// Model output that only the provider understands, such as an encrypted reasoning item.
    case providerItem(ProviderItem)
    /// The model asked to run a tool.
    case toolCall(ToolCall)
    /// What running a tool produced. Every tool call gets exactly one result.
    case toolResult(ToolResult)
    /// Marks the start of a new episode. Written just before the owner's first message in it.
    /// The thread from before these markers existed has none, and its episodes are derived
    /// from the pauses between entries instead. See `EpisodeTracker`.
    case episodeStart(EpisodeStart)

    public struct EpisodeStart: Sendable, Equatable, Codable {
        public enum Reason: String, Sendable, Equatable, Codable {
            /// The owner wrote after the previous episode had been idle longer than the timeout.
            case timeout
            /// The owner asked for a fresh start, with `/new`.
            case requested
        }

        public var reason: Reason

        public init(reason: Reason) {
            self.reason = reason
        }
    }

    public struct AssistantMessage: Sendable, Equatable, Codable {
        public var text: String
        public var provider: String
        public var model: String
        /// The provider's own id for the message, when it has one.
        public var providerID: String?
        /// Anything else the provider needs to send the message back as it was.
        public var providerData: JSONValue?

        public init(text: String, provider: String, model: String, providerID: String? = nil, providerData: JSONValue? = nil) {
            self.text = text
            self.provider = provider
            self.model = model
            self.providerID = providerID
            self.providerData = providerData
        }
    }

    public struct ProviderItem: Sendable, Equatable, Codable {
        public var provider: String
        public var model: String
        public var payload: JSONValue

        public init(provider: String, model: String, payload: JSONValue) {
            self.provider = provider
            self.model = model
            self.payload = payload
        }
    }

    public struct ToolCall: Sendable, Equatable, Codable {
        public var callID: String
        public var name: String
        /// The arguments as the model wrote them, a JSON object in text form.
        public var arguments: String
        public var provider: String
        public var model: String
        public var providerID: String?

        public init(callID: String, name: String, arguments: String, provider: String, model: String, providerID: String? = nil) {
            self.callID = callID
            self.name = name
            self.arguments = arguments
            self.provider = provider
            self.model = model
            self.providerID = providerID
        }
    }

    public struct ToolResult: Sendable, Equatable, Codable {
        public var callID: String
        public var output: String
        /// What the app noted about the run, for the tool call inspector. Never sent to the
        /// model. Results written before it existed have none, and their lines stay as they are.
        public var details: ToolRunDetails?

        public init(callID: String, output: String, details: ToolRunDetails? = nil) {
            self.callID = callID
            self.output = output
            self.details = details
        }
    }

    private enum CodingKeys: String, CodingKey { case type, value }

    private enum Kind: String, Codable {
        case userMessage = "user_message"
        case assistantMessage = "assistant_message"
        case providerItem = "provider_item"
        case toolCall = "tool_call"
        case toolResult = "tool_result"
        case episodeStart = "episode_start"
    }

    private struct UserText: Codable { var text: String }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .userMessage: self = .userMessage(text: try container.decode(UserText.self, forKey: .value).text)
        case .assistantMessage: self = .assistantMessage(try container.decode(AssistantMessage.self, forKey: .value))
        case .providerItem: self = .providerItem(try container.decode(ProviderItem.self, forKey: .value))
        case .toolCall: self = .toolCall(try container.decode(ToolCall.self, forKey: .value))
        case .toolResult: self = .toolResult(try container.decode(ToolResult.self, forKey: .value))
        case .episodeStart: self = .episodeStart(try container.decode(EpisodeStart.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .userMessage(let text):
            try container.encode(Kind.userMessage, forKey: .type)
            try container.encode(UserText(text: text), forKey: .value)
        case .assistantMessage(let value):
            try container.encode(Kind.assistantMessage, forKey: .type)
            try container.encode(value, forKey: .value)
        case .providerItem(let value):
            try container.encode(Kind.providerItem, forKey: .type)
            try container.encode(value, forKey: .value)
        case .toolCall(let value):
            try container.encode(Kind.toolCall, forKey: .type)
            try container.encode(value, forKey: .value)
        case .toolResult(let value):
            try container.encode(Kind.toolResult, forKey: .type)
            try container.encode(value, forKey: .value)
        case .episodeStart(let value):
            try container.encode(Kind.episodeStart, forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}
