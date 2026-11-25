import Foundation

/// A tool the model ran on the provider's side, such as OpenAI's hosted web search. No call
/// comes back to the app and nothing runs here. The panel shows it as a tool row like any
/// other, read from the provider's item in the thread, so a row rebuilt from the saved thread
/// reads the same as the live one.
public struct HostedToolCall: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case running
        case completed
        case failed(String)
    }

    /// The provider's id for the item, used as the row's id.
    public var callID: String
    /// The hosted tool's name, as the provider calls it, such as `web_search`.
    public var name: String
    /// The row's line, such as `Search the web swift 6.2 release date`.
    public var summary: String
    public var status: Status
    /// What the call acted on, as the provider gave it, for the inspector's input.
    public var arguments: JSONValue
    /// Addresses the provider says it consulted, when the item carries them.
    public var sources: [String]
    /// Who ran it, for the inspector's tool line.
    public var host: String

    public init(
        callID: String, name: String, summary: String, status: Status, arguments: JSONValue,
        sources: [String] = [], host: String
    ) {
        self.callID = callID
        self.name = name
        self.summary = summary
        self.status = status
        self.arguments = arguments
        self.sources = sources
        self.host = host
    }

    /// What the inspector shows as the call's output. A failed call starts with `Error:`, so
    /// its row reads as failed.
    public var output: String {
        switch status {
        case .running:
            return ""
        case .failed(let status):
            return "Error: the web search ended with status \(status)."
        case .completed:
            var lines: [String] = []
            switch arguments["type"]?.stringValue {
            case "search":
                if let query = HostedWebSearch.query(arguments) { lines.append("Searched the web for: \(query)") }
            case "open_page":
                if let url = arguments["url"]?.stringValue { lines.append("Opened the page: \(url)") }
            case "find_in_page", "find":
                if let pattern = arguments["pattern"]?.stringValue { lines.append("Looked for: \(pattern)") }
                if let url = arguments["url"]?.stringValue { lines.append("On the page: \(url)") }
            default:
                break
            }
            if !sources.isEmpty {
                lines.append("")
                lines.append("Sources:")
                lines += sources
            }
            if !lines.isEmpty { lines.append("") }
            lines.append("The search ran on \(host)'s side. Its results went to the model and are not kept here.")
            return lines.joined(separator: "\n")
        }
    }
}

/// OpenAI's hosted web search, the tool Codex uses: `{"type": "web_search"}` in the request's
/// tools, and `web_search_call` items in the reply.
public enum HostedWebSearch {
    /// The tool entry as the Responses API takes it.
    public static let toolName = "web_search"
    /// The output item's type.
    public static let itemType = "web_search_call"
    /// The first words of a search's row, the same for the hosted search and `search_web`.
    public static let searchWords = "Search the web"

    /// The query of a `search` action: `query`, or the `queries` it lists.
    static func query(_ action: JSONValue?) -> String? {
        if let query = action?["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            return query
        }
        let queries = (action?["queries"]?.arrayValue ?? []).compactMap(\.stringValue).filter { !$0.isEmpty }
        return queries.isEmpty ? nil : queries.joined(separator: "; ")
    }

    /// The row's line for an action: `Search the web <query>`, `Open page <url>`, or
    /// `Find <pattern> in <url>`. A call with no action yet, while it starts, is a search.
    public static func summary(action: JSONValue?) -> String {
        func line(_ head: String, _ rest: String?) -> String {
            guard let rest = rest.map(AgentInstructions.singleLine), !rest.isEmpty else { return head }
            return "\(head) \(rest)"
        }
        switch action?["type"]?.stringValue {
        case "open_page":
            return line("Open page", action?["url"]?.stringValue)
        case "find_in_page", "find":
            let pattern = action?["pattern"]?.stringValue
            let url = action?["url"]?.stringValue
            if let pattern, let url { return "Find \(AgentInstructions.singleLine(pattern)) in \(url)" }
            return line("Find in page", pattern ?? url)
        default:
            return line(searchWords, query(action))
        }
    }

    /// Reads a Responses `web_search_call` item, finished or just started. Nil for any other item.
    public static func call(fromOpenAIItem item: JSONValue) -> HostedToolCall? {
        guard item["type"]?.stringValue == itemType, let id = item["id"]?.stringValue else { return nil }
        let action = item["action"]
        let status: HostedToolCall.Status
        switch item["status"]?.stringValue {
        case "completed": status = .completed
        case "failed", "incomplete": status = .failed(item["status"]?.stringValue ?? "failed")
        default: status = .running
        }
        let sources = (action?["sources"]?.arrayValue ?? []).compactMap { $0["url"]?.stringValue }
        return HostedToolCall(
            callID: id, name: toolName, summary: summary(action: action), status: status,
            arguments: action ?? [:], sources: sources, host: "OpenAI")
    }
}

extension ThreadItem.ProviderItem {
    /// The hosted tool call this item records, such as an OpenAI web search, or nil for an item
    /// that is not one, such as encrypted reasoning.
    public var hostedToolCall: HostedToolCall? {
        guard provider == OpenAIResponses.providerName else { return nil }
        return HostedWebSearch.call(fromOpenAIItem: payload)
    }
}
