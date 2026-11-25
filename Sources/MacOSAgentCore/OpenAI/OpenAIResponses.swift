import Foundation

/// Request bodies and stream events of the OpenAI Responses API, kept free of networking
/// so they can be tested. The shapes follow pi's `openai-responses.ts` and
/// `openai-responses-shared.ts`.
public enum OpenAIResponses {
    public static let providerName = "openai"

    /// The JSON body for `POST /v1/responses`.
    ///
    /// Sign in with ChatGPT rejects `prompt_cache_retention`, `prompt_cache_options`,
    /// `max_output_tokens`, and `temperature`, so they are never sent. `store` is false, so
    /// reasoning comes back encrypted and is replayed from the thread.
    public static func body(
        for request: ModelRequest, model: String, reasoningEffort: String, promptCacheKey: String,
        timeZone: TimeZone = .current
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "model": .string(model),
            "input": .array(input(for: request, model: model, timeZone: timeZone)),
            "stream": true,
            "store": false,
            "prompt_cache_key": .string(String(promptCacheKey.prefix(64))),
            "reasoning": ["effort": .string(reasoningEffort), "summary": "auto"],
            "include": ["reasoning.encrypted_content"],
        ]
        var tools: [JSONValue] = request.tools.map { tool in
            [
                "type": "function",
                "name": .string(tool.name),
                "description": .string(tool.description),
                "parameters": tool.parameters,
                "strict": .bool(tool.strict),
            ]
        }
        // The hosted web search goes after the function tools, so the list before it is the
        // same as without it.
        if request.webSearch { tools.append(["type": .string(HostedWebSearch.toolName)]) }
        if !tools.isEmpty { object["tools"] = .array(tools) }
        return .object(object)
    }

    /// The thread as Responses input items. Items that only make sense to the model that
    /// produced them, such as encrypted reasoning, are left out after a model change.
    public static func input(for request: ModelRequest, model: String, timeZone: TimeZone = .current) -> [JSONValue] {
        var items: [JSONValue] = [["role": "developer", "content": .string(request.instructions)]]
        for (index, entry) in request.entries.enumerated() {
            switch entry.item {
            case .userMessage(let text, let skill, let action):
                let sent = ThreadItem.modelText(text: text, skill: skill, action: action)
                let stamped = "[\(timestamp(entry.date, timeZone: timeZone))] \(sent)"
                items.append(["role": "user", "content": [["type": "input_text", "text": .string(stamped)]]])
            case .assistantMessage(let message):
                var item: [String: JSONValue] = [
                    "type": "message",
                    "role": "assistant",
                    "content": [["type": "output_text", "text": .string(message.text), "annotations": []]],
                    "status": "completed",
                    "id": .string(messageID(message, index: index)),
                ]
                if message.provider == providerName, let phase = message.providerData?["phase"], phase != .null {
                    item["phase"] = phase
                }
                items.append(.object(item))
            case .providerItem(let providerItem):
                // Reasoning and hosted web search calls are replayed under the same rule: only
                // to the model that produced them. With `store` false the next request in the
                // episode has to carry them, as Codex does.
                guard providerItem.provider == providerName, providerItem.model == model else { continue }
                items.append(providerItem.payload)
            case .toolCall(let call):
                var item: [String: JSONValue] = [
                    "type": "function_call",
                    "call_id": .string(call.callID),
                    "name": .string(call.name),
                    "arguments": .string(call.arguments),
                ]
                // OpenAI pairs function call ids with the reasoning that produced them. Leave the
                // id out after a model change so it does not check that pairing.
                if call.provider == providerName, call.model == model, let id = call.providerID, id.hasPrefix("fc_") {
                    item["id"] = .string(id)
                }
                items.append(.object(item))
            case .toolResult(let result):
                items.append([
                    "type": "function_call_output",
                    "call_id": .string(result.callID),
                    "output": .string(result.output),
                ])
            case .appOpened(let opening):
                // Logged when it happened and sent only now, with the next request of its
                // episode. It comes after everything the earlier requests carried, so their
                // prefix is unchanged.
                let stamped = "[\(timestamp(entry.date, timeZone: timeZone))] \(opening.message)"
                items.append(["role": "user", "content": [["type": "input_text", "text": .string(stamped)]]])
            case .episodeStart:
                // The loop sends only the current episode and leaves its marker out. A marker
                // carries nothing for the model in any case.
                continue
            }
        }
        return items
    }

    static func messageID(_ message: ThreadItem.AssistantMessage, index: Int) -> String {
        if message.provider == providerName, let id = message.providerID, id.hasPrefix("msg_"), id.count <= 64 {
            return id
        }
        return "msg_mac_os_agent_\(index)"
    }

    /// The local time a message was sent, such as `2026-11-21 14:03 PST`.
    static func timestamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
        return formatter.string(from: date)
    }

    /// Reads the `usage` object of a finished response. OpenAI counts cached tokens inside
    /// `input_tokens` and reasoning tokens inside `output_tokens`, the same as `TokenUsage`.
    public static func usage(from response: JSONValue?) -> TokenUsage? {
        guard let usage = response?["usage"], let input = usage["input_tokens"]?.numberValue else { return nil }
        return TokenUsage(
            inputTokens: Int(input),
            cachedInputTokens: Int(usage["input_tokens_details"]?["cached_tokens"]?.numberValue ?? 0),
            outputTokens: Int(usage["output_tokens"]?.numberValue ?? 0),
            reasoningTokens: usage["output_tokens_details"]?["reasoning_tokens"]?.numberValue.map { Int($0) },
            reasoningRemovals: reasoningRemovals(from: response?["input_transformations"]))
    }

    /// Counts the replayed reasoning items the response says were withheld, by reason. From
    /// GPT-6.2 on, OpenAI lists them in `input_transformations`, as pi's `appendReasoningRemovals`
    /// reads them. `turn_boundary` is left out: older models drop every earlier turn's reasoning
    /// that way as a matter of course.
    static func reasoningRemovals(from transformations: JSONValue?) -> [String: Int]? {
        var counts: [String: Int] = [:]
        for item in transformations?.arrayValue ?? [] {
            guard item["type"]?.stringValue == "reasoning", item["action"]?.stringValue == "removed" else { continue }
            let reason = item["reason"]?.stringValue ?? "unknown"
            if reason == "turn_boundary" { continue }
            counts[reason, default: 0] += 1
        }
        return counts.isEmpty ? nil : counts
    }

    public enum StreamError: Error, Equatable, LocalizedError {
        case failed(String)
        case incomplete(String)
        case endedEarly

        public var errorDescription: String? {
            switch self {
            case .failed(let message): message
            case .incomplete(let reason): "The response was cut short: \(reason)"
            case .endedEarly: "The response stream ended before the reply was complete."
            }
        }
    }

    /// Turns Responses stream events into `ModelStreamEvent`s.
    public struct StreamParser {
        public let model: String
        public private(set) var sawTerminalEvent = false

        public init(model: String) {
            self.model = model
        }

        /// Handles one `data:` payload of the event stream.
        public mutating func consume(_ event: JSONValue) throws -> [ModelStreamEvent] {
            switch event["type"]?.stringValue {
            case "response.output_item.added":
                if let item = event["item"], item["type"]?.stringValue == "function_call",
                   let callID = item["call_id"]?.stringValue, let name = item["name"]?.stringValue
                {
                    return [.toolCallStarted(callID: callID, name: name)]
                }
                if let item = event["item"], let call = HostedWebSearch.call(fromOpenAIItem: item) {
                    return [.hostedToolStarted(call)]
                }
            case "response.output_text.delta", "response.refusal.delta":
                if let delta = event["delta"]?.stringValue { return [.textDelta(delta)] }
            case "response.output_item.done":
                if let item = event["item"], let finished = finishedItem(item) { return [.item(finished)] }
            case "response.completed":
                sawTerminalEvent = true
                return usageEvent(event["response"])
            case "response.incomplete":
                sawTerminalEvent = true
                let reason = event["response"]?["incomplete_details"]?["reason"]?.stringValue
                if reason != "max_output_tokens" {
                    throw StreamError.incomplete(reason ?? "no reason given")
                }
                return usageEvent(event["response"])
            case "response.failed":
                sawTerminalEvent = true
                let error = event["response"]?["error"]
                let code = error?["code"]?.stringValue ?? "unknown"
                let message = error?["message"]?.stringValue ?? "no message"
                throw StreamError.failed(OpenAIResponsesProvider.explain("\(code): \(message)"))
            case "error":
                let code = event["code"]?.stringValue ?? "unknown"
                let message = event["message"]?.stringValue ?? "no message"
                throw StreamError.failed(OpenAIResponsesProvider.explain("Error code \(code): \(message)"))
            default:
                break
            }
            return []
        }

        /// Call when the stream ends. Throws when no terminal event arrived.
        public func finish() throws {
            if !sawTerminalEvent { throw StreamError.endedEarly }
        }

        private func usageEvent(_ response: JSONValue?) -> [ModelStreamEvent] {
            guard let usage = OpenAIResponses.usage(from: response) else { return [] }
            return [.usage(usage, provider: providerName, model: model)]
        }

        private func finishedItem(_ item: JSONValue) -> ThreadItem? {
            switch item["type"]?.stringValue {
            case "reasoning", HostedWebSearch.itemType:
                // Kept whole, so it can be sent back as it came. A web search call also shows
                // as a row in the panel. See `ProviderItem.hostedToolCall`.
                return .providerItem(.init(provider: providerName, model: model, payload: item))
            case "message":
                let text = (item["content"]?.arrayValue ?? []).compactMap { part -> String? in
                    part["type"]?.stringValue == "refusal" ? part["refusal"]?.stringValue : part["text"]?.stringValue
                }.joined()
                var data: JSONValue? = nil
                if let phase = item["phase"], phase != .null { data = ["phase": phase] }
                return .assistantMessage(.init(
                    text: text, provider: providerName, model: model,
                    providerID: item["id"]?.stringValue, providerData: data))
            case "function_call":
                guard let callID = item["call_id"]?.stringValue, let name = item["name"]?.stringValue else { return nil }
                return .toolCall(.init(
                    callID: callID, name: name, arguments: item["arguments"]?.stringValue ?? "{}",
                    provider: providerName, model: model, providerID: item["id"]?.stringValue))
            default:
                return nil
            }
        }
    }
}
