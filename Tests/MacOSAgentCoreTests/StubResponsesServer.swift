import Foundation
import Synchronization
@testable import MacOSAgentCore

/// A stand-in for OpenAI's Responses API, reached through a `URLSession` whose requests it
/// answers, so a test drives the real `OpenAIResponsesProvider` and sees the real bytes it sends.
///
/// It plays back scripted replies as an event stream and keeps a fake prompt cache that follows
/// the rules OpenAI publishes for GPT-5.6 and later (developers.openai.com, Prompt caching):
///
/// - The cacheable prompt is the tool list, then the input items, in that order.
/// - A prefix can be read from the cache only where it ends at a lookup boundary: the end of
///   the first block of developer messages, the end of a user message, or the end of the last
///   tool result in a consecutive group. Assistant messages, calls, and reasoning are not.
/// - Each request writes the prefix up to its latest boundary, the implicit breakpoint, and
///   looks up the longest cached prefix among its boundaries, the latest 21 of them and the
///   end of the developer block.
/// - It also writes the prefix up to the end of the developer block. The page does not say
///   so. It is assumed from our own usage log, where GPT-6.2 requests kept reading the same
///   3,840 tokens after the rest of the prefix changed.
/// - Nothing under 1,024 tokens is cached.
/// - The cache is per model.
///
/// Tokens are counted as characters over 4 of a rendering that keeps only what the model reads
/// (roles, text, call names and arguments, outputs, reasoning ids), not JSON framing.
///
/// It also does what GPT-6.2 does with replayed reasoning: when the input before a reasoning
/// item is not what the model had read when it wrote the item, the item is withheld and listed
/// in `input_transformations` with the reason `prefix_mismatch`.
final class StubResponsesServer: Sendable {
    /// One piece of a scripted reply.
    enum Output: Sendable {
        case reasoning
        case call(name: String, arguments: JSONValue)
        case message(String, phase: String? = "final_answer")
    }

    /// A request as it arrived.
    struct Received: Sendable {
        var headers: [String: String]
        var body: JSONValue
        var data: Data
        var input: [JSONValue] { body["input"]?.arrayValue ?? [] }
    }

    /// What the server reported for a request.
    struct Reported: Sendable, Equatable {
        var inputTokens: Int
        var cachedTokens: Int
        var cacheWriteTokens: Int
        var removedReasoning: [String]
    }

    private struct State {
        var replies: [[Output]] = []
        var received: [Received] = []
        var reported: [Reported] = []
        /// Cached prefixes, by model, as the rendered text up to a boundary.
        var cache: [String: Set<String>] = [:]
        /// For each reasoning item the server wrote, the rendered prompt the model had read.
        var reasoningContext: [String: String] = [:]
        var nextID = 1
    }

    let id = UUID().uuidString
    let minimumTokens: Int
    private let state = Mutex(State())

    init(replies: [[Output]], minimumTokens: Int = 1024) {
        self.minimumTokens = minimumTokens
        state.withLock { $0.replies = replies }
        Self.servers.withLock { $0[id] = self }
    }

    deinit {
        let id = id
        Self.servers.withLock { _ = $0.removeValue(forKey: id) }
    }

    var received: [Received] { state.withLock { $0.received } }
    var reported: [Reported] { state.withLock { $0.reported } }

    func enqueue(_ reply: [Output]) {
        state.withLock { $0.replies.append(reply) }
    }

    /// A session whose requests this server answers.
    func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubResponsesProtocol.self]
        configuration.httpAdditionalHeaders = [Self.routingHeader: id]
        return URLSession(configuration: configuration)
    }

    // MARK: Answering a request

    func respond(to data: Data, headers: [String: String]) -> Data {
        let body = JSONValue.parse(String(decoding: data, as: UTF8.self)) ?? .null
        let model = body["model"]?.stringValue ?? ""
        let tools = body["tools"] ?? .array([])
        let input = body["input"]?.arrayValue ?? []

        return state.withLock { state in
            state.received.append(Received(headers: headers, body: body, data: data))

            // Reasoning whose earlier input changed is withheld, as GPT-6.2 does.
            var removed: [String] = []
            var rendered = Self.render(tools: tools)
            var kept: [JSONValue] = []
            for item in input {
                if item["type"]?.stringValue == "reasoning", let reasoningID = item["id"]?.stringValue,
                   let context = state.reasoningContext[reasoningID], context != rendered
                {
                    removed.append(reasoningID)
                    continue
                }
                kept.append(item)
                rendered += Self.render(item)
            }

            // The cache, over what the model reads.
            let boundaries = Self.boundaries(tools: tools, input: kept)
            let prompt = boundaries.prompt
            let inputTokens = Self.tokens(prompt)
            var lookups = Array(boundaries.ends.suffix(21))
            if let developerEnd = boundaries.developerEnd, !lookups.contains(developerEnd) { lookups.append(developerEnd) }
            let cached = state.cache[model, default: []]
            let hit = lookups.sorted(by: >).first { end in
                Self.tokens(prompt.prefix(end)) >= minimumTokens && cached.contains(String(prompt.prefix(end)))
            } ?? 0
            var written = 0
            var writes: [Int] = []
            if let developerEnd = boundaries.developerEnd { writes.append(developerEnd) }
            if let breakpoint = boundaries.ends.last, breakpoint != boundaries.developerEnd { writes.append(breakpoint) }
            var covered = hit
            for end in writes where Self.tokens(prompt.prefix(end)) >= minimumTokens {
                let prefix = String(prompt.prefix(end))
                guard !cached.contains(prefix) else { continue }
                state.cache[model, default: []].insert(prefix)
                if end > covered {
                    written += Self.tokens(prompt.prefix(end)) - Self.tokens(prompt.prefix(covered))
                    covered = end
                }
            }
            let cachedTokens = hit > 0 ? Self.tokens(prompt.prefix(hit)) : 0

            // The reply.
            let reply = state.replies.isEmpty ? [Output.message("ok")] : state.replies.removeFirst()
            var events: [JSONValue] = [["type": "response.created", "response": ["id": .string("resp_\(state.nextID)")]]]
            var context = rendered
            for output in reply {
                let n = state.nextID
                state.nextID += 1
                let item: JSONValue
                switch output {
                case .reasoning:
                    item = ["type": "reasoning", "id": .string("rs_\(n)"), "summary": [],
                            "encrypted_content": .string("encrypted-\(n)")]
                    state.reasoningContext["rs_\(n)"] = context
                case .call(let name, let arguments):
                    item = ["type": "function_call", "id": .string("fc_\(n)"), "call_id": .string("call_\(n)"),
                            "name": .string(name), "arguments": .string(arguments.encodedString()), "status": "completed"]
                    events.append(["type": "response.output_item.added", "item": item])
                case .message(let text, let phase):
                    var object: [String: JSONValue] = [
                        "type": "message", "id": .string("msg_\(n)"), "role": "assistant", "status": "completed",
                        "content": [["type": "output_text", "text": .string(text), "annotations": []]],
                    ]
                    if let phase { object["phase"] = .string(phase) }
                    item = .object(object)
                    events.append(["type": "response.output_text.delta", "delta": .string(text)])
                }
                context += Self.render(item)
                events.append(["type": "response.output_item.done", "item": item])
            }
            let transformations: [JSONValue] = removed.map {
                ["type": "reasoning", "id": .string($0), "action": "removed", "reason": "prefix_mismatch"]
            }
            events.append([
                "type": "response.completed",
                "response": [
                    "status": "completed",
                    "usage": [
                        "input_tokens": .number(Double(inputTokens)),
                        "input_tokens_details": [
                            "cached_tokens": .number(Double(cachedTokens)),
                            "cache_write_tokens": .number(Double(written)),
                        ],
                        "output_tokens": 1,
                    ],
                    "input_transformations": .array(transformations),
                ],
            ])
            state.reported.append(Reported(
                inputTokens: inputTokens, cachedTokens: cachedTokens, cacheWriteTokens: written, removedReasoning: removed))
            let stream = events.map { "data: \($0.encodedString())\n\n" }.joined() + "data: [DONE]\n\n"
            return Data(stream.utf8)
        }
    }

    // MARK: What the model reads

    static func tokens<S: StringProtocol>(_ text: S) -> Int { text.count / 4 }

    static func render(tools: JSONValue) -> String {
        (tools.arrayValue ?? []).map { "<tool>\($0.encodedString())</tool>" }.joined()
    }

    /// The parts of an item the model reads, so a replay that differs only in framing, such as
    /// an item id or `status`, reads the same, as it would to the model.
    static func render(_ item: JSONValue) -> String {
        switch item["type"]?.stringValue {
        case "reasoning":
            return "<reasoning \(item["id"]?.stringValue ?? "")/>"
        case "function_call":
            return "<call \(item["call_id"]?.stringValue ?? "") \(item["name"]?.stringValue ?? "")>"
                + (item["arguments"]?.stringValue ?? "") + "</call>"
        case "function_call_output":
            return "<result \(item["call_id"]?.stringValue ?? "")>" + (item["output"]?.stringValue ?? "") + "</result>"
        default:
            let role = item["role"]?.stringValue ?? "?"
            let text: String
            if let string = item["content"]?.stringValue {
                text = string
            } else {
                text = (item["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined()
            }
            let phase = item["phase"]?.stringValue.map { " phase=\($0)" } ?? ""
            return "<\(role)\(phase)>\(text)</\(role)>"
        }
    }

    /// The rendered prompt and the character offsets where a cached prefix can end.
    static func boundaries(tools: JSONValue, input: [JSONValue]) -> (prompt: String, ends: [Int], developerEnd: Int?) {
        var prompt = render(tools: tools)
        var ends: [Int] = []
        var developerEnd: Int?
        var inFirstDeveloperBlock = true
        for (index, item) in input.enumerated() {
            prompt += render(item)
            let role = item["role"]?.stringValue
            let type = item["type"]?.stringValue
            if role == "developer" {
                if inFirstDeveloperBlock, input.indices.contains(index + 1) ? input[index + 1]["role"]?.stringValue != "developer" : true {
                    developerEnd = prompt.count
                    ends.append(prompt.count)
                }
                continue
            }
            inFirstDeveloperBlock = false
            if role == "user" {
                ends.append(prompt.count)
            } else if type == "function_call_output" {
                let next = input.indices.contains(index + 1) ? input[index + 1]["type"]?.stringValue : nil
                if next != "function_call_output" { ends.append(prompt.count) }
            }
        }
        return (prompt, ends, developerEnd)
    }

    // MARK: Routing requests to their server

    static let routingHeader = "X-Stub-Responses-Server"
    private static let servers = Mutex<[String: StubResponsesServer]>([:])

    static func server(for request: URLRequest) -> StubResponsesServer? {
        guard let id = request.value(forHTTPHeaderField: routingHeader) else { return nil }
        return servers.withLock { $0[id] }
    }
}

/// Hands each request of a stub session to its `StubResponsesServer`.
final class StubResponsesProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let server = StubResponsesServer.server(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        var headers = request.allHTTPHeaderFields ?? [:]
        headers.removeValue(forKey: StubResponsesServer.routingHeader)
        let reply = server.respond(to: Self.body(of: request), headers: headers)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// A session moves the body to a stream before a protocol sees it.
    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
