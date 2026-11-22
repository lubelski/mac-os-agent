import Foundation
import Testing
@testable import MacOSAgentCore

@Suite struct OpenAIResponsesTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let date = Date(timeIntervalSince1970: 1_795_000_000)

    private func entry(_ item: ThreadItem) -> ThreadEntry {
        ThreadEntry(date: date, item: item)
    }

    private func request(_ items: [ThreadItem]) -> ModelRequest {
        ModelRequest(instructions: "Be brief.", entries: items.map(entry), tools: [ShellCommandTool().definition])
    }

    @Test func theBodyLeavesOutFieldsSignInWithChatGPTRejects() {
        let body = OpenAIResponses.body(
            for: request([.userMessage(text: "hi")]), model: "gpt-6-luna", reasoningEffort: "low",
            promptCacheKey: "mac-os-agent-key", timeZone: utc)
        #expect(body["model"] == "gpt-6-luna")
        #expect(body["stream"] == true)
        #expect(body["store"] == false)
        #expect(body["prompt_cache_key"] == "mac-os-agent-key")
        #expect(body["reasoning"] == ["effort": "low", "summary": "auto"])
        #expect(body["include"] == ["reasoning.encrypted_content"])
        for field in ["prompt_cache_retention", "prompt_cache_options", "max_output_tokens", "temperature", "instructions"] {
            #expect(body[field] == nil, "\(field)")
        }
        let tool = body["tools"]?.arrayValue?.first
        #expect(tool?["type"] == "function")
        #expect(tool?["name"] == "run_shell_command")
        #expect(tool?["strict"] == true)
    }

    @Test func theThreadBecomesResponsesInput() {
        let reasoning: JSONValue = ["type": "reasoning", "id": "rs_1", "encrypted_content": "secret", "summary": []]
        let input = OpenAIResponses.input(for: request([
            .userMessage(text: "list my apps"),
            .providerItem(.init(provider: "openai", model: "gpt-6-luna", payload: reasoning)),
            .toolCall(.init(callID: "call_1", name: "run_shell_command", arguments: #"{"command":"ls /Applications","destructive":false}"#, provider: "openai", model: "gpt-6-luna", providerID: "fc_1")),
            .toolResult(.init(callID: "call_1", output: "Safari.app")),
            .assistantMessage(.init(text: "You have Safari.", provider: "openai", model: "gpt-6-luna", providerID: "msg_1", providerData: ["phase": "final_answer"])),
        ]), model: "gpt-6-luna", timeZone: utc)

        #expect(input == [
            ["role": "developer", "content": "Be brief."],
            ["role": "user", "content": [["type": "input_text", "text": "[2026-11-18 11:06 GMT] list my apps"]]],
            reasoning,
            ["type": "function_call", "call_id": "call_1", "name": "run_shell_command",
             "arguments": #"{"command":"ls /Applications","destructive":false}"#, "id": "fc_1"],
            ["type": "function_call_output", "call_id": "call_1", "output": "Safari.app"],
            ["type": "message", "role": "assistant", "status": "completed", "id": "msg_1", "phase": "final_answer",
             "content": [["type": "output_text", "text": "You have Safari.", "annotations": []]]],
        ])
    }

    @Test func modelSpecificItemsAreLeftOutAfterAModelChange() {
        let input = OpenAIResponses.input(for: request([
            .providerItem(.init(provider: "openai", model: "gpt-6-sol", payload: ["type": "reasoning", "id": "rs_1"])),
            .toolCall(.init(callID: "call_1", name: "run_shell_command", arguments: "{}", provider: "openai", model: "gpt-6-sol", providerID: "fc_1")),
            .toolResult(.init(callID: "call_1", output: "ok")),
        ]), model: "gpt-6-luna", timeZone: utc)
        #expect(input.count == 3)
        #expect(input[1]["type"] == "function_call")
        #expect(input[1]["id"] == nil)
    }

    @Test func theSameThreadAlwaysEncodesToTheSameBytes() {
        let thread = request([.userMessage(text: "a"), assistant("b")])
        let first = OpenAIResponses.body(for: thread, model: "m", reasoningEffort: "low", promptCacheKey: "k", timeZone: utc)
        let second = OpenAIResponses.body(for: thread, model: "m", reasoningEffort: "low", promptCacheKey: "k", timeZone: utc)
        #expect(first.encodedString() == second.encodedString())
    }

    @Test func streamEventsBecomeThreadItems() throws {
        var parser = OpenAIResponses.StreamParser(model: "gpt-6-luna")
        let events: [JSONValue] = [
            ["type": "response.created", "response": ["id": "resp_1"]],
            ["type": "response.output_item.added", "output_index": 0, "item": ["type": "reasoning", "id": "rs_1"]],
            ["type": "response.output_item.done", "output_index": 0, "item": ["type": "reasoning", "id": "rs_1", "encrypted_content": "e", "summary": []]],
            ["type": "response.output_item.added", "output_index": 1, "item": ["type": "message", "id": "msg_1", "content": []]],
            ["type": "response.output_text.delta", "output_index": 1, "delta": "Look"],
            ["type": "response.output_text.delta", "output_index": 1, "delta": "ing"],
            ["type": "response.output_item.done", "output_index": 1, "item": [
                "type": "message", "id": "msg_1", "phase": "commentary",
                "content": [["type": "output_text", "text": "Looking", "annotations": []]],
            ]],
            ["type": "response.output_item.added", "output_index": 2, "item": [
                "type": "function_call", "id": "fc_1", "call_id": "call_1", "name": "run_shell_command", "arguments": "",
            ]],
            ["type": "response.function_call_arguments.delta", "output_index": 2, "delta": "{\"command\""],
            ["type": "response.output_item.done", "output_index": 2, "item": [
                "type": "function_call", "id": "fc_1", "call_id": "call_1", "name": "run_shell_command",
                "arguments": #"{"command":"ls","destructive":false}"#,
            ]],
            ["type": "response.completed", "response": ["id": "resp_1", "status": "completed"]],
        ]
        var output: [ModelStreamEvent] = []
        for event in events { output += try parser.consume(event) }
        try parser.finish()

        #expect(output == [
            .item(.providerItem(.init(provider: "openai", model: "gpt-6-luna", payload: ["type": "reasoning", "id": "rs_1", "encrypted_content": "e", "summary": []]))),
            .textDelta("Look"),
            .textDelta("ing"),
            .item(.assistantMessage(.init(text: "Looking", provider: "openai", model: "gpt-6-luna", providerID: "msg_1", providerData: ["phase": "commentary"]))),
            .toolCallStarted(callID: "call_1", name: "run_shell_command"),
            .item(.toolCall(.init(callID: "call_1", name: "run_shell_command", arguments: #"{"command":"ls","destructive":false}"#, provider: "openai", model: "gpt-6-luna", providerID: "fc_1"))),
        ])
    }

    @Test func failuresAndEarlyEndsThrow() throws {
        var parser = OpenAIResponses.StreamParser(model: "m")
        #expect(throws: OpenAIResponses.StreamError.endedEarly) { try parser.finish() }
        #expect(throws: OpenAIResponses.StreamError.self) {
            try parser.consume(["type": "response.failed", "response": ["error": ["code": "server_error", "message": "boom"]]])
        }
        var limited = OpenAIResponses.StreamParser(model: "m")
        #expect(throws: OpenAIResponses.StreamError.failed(
            "Error code subscription_sharing_usage_limit_exceeded: limit\nCheck your ChatGPT usage: https://chatgpt.com/settings/usage"
        )) {
            try limited.consume(["type": "error", "code": "subscription_sharing_usage_limit_exceeded", "message": "limit"])
        }
        var incomplete = OpenAIResponses.StreamParser(model: "m")
        #expect(throws: OpenAIResponses.StreamError.incomplete("content_filter")) {
            try incomplete.consume(["type": "response.incomplete", "response": ["incomplete_details": ["reason": "content_filter"]]])
        }
    }

    @Test func jsonValuesRoundTrip() {
        let value: JSONValue = ["a": [1, .number(2.5), "x", true, nil], "b": ["c": false]]
        #expect(JSONValue.parse(value.encodedString()) == value)
        #expect(JSONValue.parse("true") == .bool(true))
        #expect(JSONValue.parse("1") == .number(1))
    }
}
