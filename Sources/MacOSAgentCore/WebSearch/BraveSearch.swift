import Foundation

/// The Brave Search API key, kept where the sign-in is kept: the Keychain in a release build
/// and `secrets.json` otherwise. See `SecretStorage`. It is never kept in the preferences,
/// never logged, and never in Copy Diagnostics.
public struct BraveSearchKey: Sendable {
    public static let secretKey = "brave-search-api-key"

    public let secrets: any SecretStore

    public init(secrets: any SecretStore) {
        self.secrets = secrets
    }

    /// The key, trimmed, or nil when none is saved.
    public func read() -> String? {
        guard let value = secrets.read(Self.secretKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    public var isSet: Bool { read() != nil }

    /// Saves the key, trimmed. A blank key removes it.
    public func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            remove()
        } else {
            try secrets.write(trimmed, for: Self.secretKey)
        }
    }

    public func remove() {
        secrets.delete(Self.secretKey)
    }
}

/// The Brave Search web search endpoint, its request, and its results as text for the model.
public enum BraveSearch {
    public static let endpoint = URL(string: "https://api.search.brave.com/res/v1/web/search")!
    public static let defaultCount = 5
    public static let maximumCount = 10
    /// Brave's own freshness values: the past day, week, month, and year.
    public static let freshnessValues = ["pd", "pw", "pm", "py"]
    public static let timeoutSeconds: TimeInterval = 15
    /// The most of a result passed to the model, as for an MCP tool's result.
    public static let outputLimit = 16_000

    /// The count asked for, held between 1 and the maximum. Null or missing is the default.
    public static func clampedCount(_ value: JSONValue?) -> Int {
        guard let number = value?.numberValue else { return defaultCount }
        return min(max(Int(number), 1), maximumCount)
    }

    public static func request(query: String, count: Int, freshness: String?, key: String) -> URLRequest {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "count", value: String(count))]
        if let freshness { items.append(URLQueryItem(name: "freshness", value: freshness)) }
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
        request.setValue("mac-os-agent", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// The sentence the model reads when the call failed, by HTTP status.
    public static func statusError(_ status: Int) -> String {
        switch status {
        case 401, 403:
            "Error: Brave Search refused the API key (status \(status)). The owner can check the key in Settings, General."
        case 429:
            "Error: Brave Search's rate limit was reached, so the search did not run. Try again in a little while."
        default:
            "Error: Brave Search answered with status \(status), so the search did not run."
        }
    }

    public static let noKeyError = "Error: no Brave Search API key is set, so the search did not run. The owner can add one in Settings, General."
    public static let timeoutError = "Error: Brave Search did not answer within 15 seconds."
    public static let unreadableError = "Error: Brave Search's answer could not be read."

    public static func networkError(_ error: Error) -> String {
        "Error: the search could not reach Brave Search: \(error.localizedDescription)"
    }

    /// The web results as a numbered list: each title, its address, its description, and its
    /// age when Brave gives one. Brave's highlight markup and HTML entities are taken out. A
    /// list longer than `limit` is cut there, with a note saying so.
    public static func resultText(from body: JSONValue, query: String, limit: Int = outputLimit) -> String {
        let results = body["web"]?["results"]?.arrayValue ?? []
        var blocks: [String] = []
        for result in results {
            guard let url = result["url"]?.stringValue, !url.isEmpty else { continue }
            let title = plainText(result["title"]?.stringValue ?? "")
            var lines = ["\(blocks.count + 1). \(title.isEmpty ? url : title)", "   \(url)"]
            let description = plainText(result["description"]?.stringValue ?? "")
            if !description.isEmpty { lines.append("   \(description)") }
            if let age = result["age"]?.stringValue.map(plainText), !age.isEmpty { lines.append("   Age: \(age)") }
            blocks.append(lines.joined(separator: "\n"))
        }
        if blocks.isEmpty { return "Brave Search found no results for \"\(query)\"." }
        var text = blocks.joined(separator: "\n\n")
        if text.count > limit {
            let total = text.count
            text = String(text.prefix(limit)) + "\n[Cut at \(limit) of \(total) characters.]"
        }
        return text
    }

    /// Text without HTML tags, with its entities decoded and its spaces collapsed to one line.
    public static func plainText(_ html: String) -> String {
        let withoutTags = html.replacing(/<[^>]*>/, with: "")
        let decoded = decodeEntities(withoutTags)
        return decoded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "hellip": "…", "mdash": "—", "ndash": "–", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text.replacing(/&(#[xX][0-9A-Fa-f]+|#[0-9]+|[A-Za-z]+);/) { match in
            let name = String(match.output.1)
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                if let code = UInt32(name.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(code) { return String(Character(scalar)) }
            } else if name.hasPrefix("#") {
                if let code = UInt32(name.dropFirst()), let scalar = Unicode.Scalar(code) { return String(Character(scalar)) }
            } else if let value = namedEntities[name] {
                return value
            }
            return String(match.output.0)
        }
    }
}

/// `search_web`: searches the web with the Brave Search API. It is in the tool list only when
/// Settings, General has Brave Search chosen at launch, at the very end of the built-in list.
public struct SearchWebTool: AgentTool {
    public static let name = "search_web"

    public let key: BraveSearchKey?
    /// The network, the same seam the sign-in uses. Tests use a stand-in and never reach it.
    public let transport: any HTTPTransport

    /// - Parameter key: Read at each call, so adding or changing the key needs no relaunch. Nil
    ///   for a tool that only gives summaries.
    public init(key: BraveSearchKey?, transport: any HTTPTransport = URLSessionTransport()) {
        self.key = key
        self.transport = transport
    }

    public var source: ToolSource { .webSearch }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: Self.name,
            description: "Search the web with Brave Search. Returns titles, addresses, and snippets.",
            parameters: Schema.object([
                "query": Schema.string("What to search for."),
                "count": Schema.nullableInteger("How many results, 1 to \(BraveSearch.maximumCount). Null for \(BraveSearch.defaultCount)."),
                "freshness": Schema.nullableChoice(
                    BraveSearch.freshnessValues,
                    "Only pages from the past day (pd), week (pw), month (pm), or year (py). Null for any age."),
            ]))
    }

    public func summary(arguments: JSONValue) -> String {
        let query = arguments["query"]?.trimmedString ?? ""
        return query.isEmpty ? HostedWebSearch.searchWords : "\(HostedWebSearch.searchWords) \(query)"
    }

    public func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        guard let query = arguments["query"]?.trimmedString, !query.isEmpty else {
            return "Error: the call did not include a query."
        }
        guard let apiKey = key?.read() else { return BraveSearch.noKeyError }
        let freshness = arguments["freshness"]?.stringValue.flatMap { BraveSearch.freshnessValues.contains($0) ? $0 : nil }
        let request = BraveSearch.request(
            query: query, count: BraveSearch.clampedCount(arguments["count"]), freshness: freshness, key: apiKey)
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch is CancellationError {
            return AgentLoop.stoppedBeforeRunningOutput
        } catch let error as URLError where error.code == .timedOut {
            return BraveSearch.timeoutError
        } catch let error as URLError where error.code == .cancelled {
            return AgentLoop.stoppedBeforeRunningOutput
        } catch {
            return BraveSearch.networkError(error)
        }
        guard (200..<300).contains(response.statusCode) else { return BraveSearch.statusError(response.statusCode) }
        guard let body = JSONValue.parse(String(decoding: data, as: UTF8.self)) else { return BraveSearch.unreadableError }
        return BraveSearch.resultText(from: body, query: query)
    }
}
