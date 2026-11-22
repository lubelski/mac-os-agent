import Foundation
import Testing
@testable import MacOSAgentCore

@Suite struct TokenUsageTests {
    /// The shape of a `response.completed` event from the Responses API, with the output cut down.
    private let completed = JSONValue.parse("""
        {
          "type": "response.completed",
          "sequence_number": 42,
          "response": {
            "id": "resp_123",
            "object": "response",
            "status": "completed",
            "model": "gpt-6-luna",
            "output": [],
            "usage": {
              "input_tokens": 12840,
              "input_tokens_details": {"cached_tokens": 11520},
              "output_tokens": 210,
              "output_tokens_details": {"reasoning_tokens": 64},
              "total_tokens": 13050
            }
          }
        }
        """)!

    @Test func theCompletedResponseReportsUsage() throws {
        var parser = OpenAIResponses.StreamParser(model: "gpt-6-luna")
        let events = try parser.consume(completed)
        #expect(events == [.usage(
            TokenUsage(inputTokens: 12840, cachedInputTokens: 11520, outputTokens: 210, reasoningTokens: 64),
            provider: "openai", model: "gpt-6-luna")])
        try parser.finish()
    }

    @Test func missingDetailsCountAsZeroOrUnknown() {
        let usage = OpenAIResponses.usage(from: ["usage": ["input_tokens": 100, "output_tokens": 5]])
        #expect(usage == TokenUsage(inputTokens: 100, cachedInputTokens: 0, outputTokens: 5, reasoningTokens: nil))
        #expect(OpenAIResponses.usage(from: ["status": "completed"]) == nil)
        #expect(OpenAIResponses.usage(from: nil) == nil)
    }

    @Test func aResponseCutShortAtTheOutputLimitStillReportsUsage() throws {
        var parser = OpenAIResponses.StreamParser(model: "m")
        let events = try parser.consume([
            "type": "response.incomplete",
            "response": ["incomplete_details": ["reason": "max_output_tokens"], "usage": ["input_tokens": 10, "output_tokens": 3]],
        ])
        #expect(events == [.usage(TokenUsage(inputTokens: 10, cachedInputTokens: 0, outputTokens: 3), provider: "openai", model: "m")])
    }

    @Test func cachedShare() {
        #expect(TokenUsage(inputTokens: 200, cachedInputTokens: 150, outputTokens: 1).cachedShare == 0.75)
        #expect(TokenUsage(inputTokens: 0, cachedInputTokens: 0, outputTokens: 1).cachedShare == 0)
    }
}

@Suite struct UsageLogTests {
    private func temporaryLog() -> UsageLog {
        UsageLog(fileURL: temporaryThreadFile().deletingLastPathComponent().appending(path: "usage.jsonl"))
    }

    @Test func writesOneLineOfCountsPerRequest() throws {
        let log = temporaryLog()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        log.append(UsageRecord(date: date, provider: "openai", model: "gpt-6-luna",
                               usage: TokenUsage(inputTokens: 1000, cachedInputTokens: 900, outputTokens: 20, reasoningTokens: 8)))
        log.append(UsageRecord(date: date, provider: "openai", model: "gpt-6-luna",
                               usage: TokenUsage(inputTokens: 1100, cachedInputTokens: 1000, outputTokens: 30)))
        let text = try String(contentsOf: log.fileURL, encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(text.hasSuffix("\n"))
        #expect(lines[0] == #"{"cached":900,"date":"2027-01-15T08:00:00Z","input":1000,"model":"gpt-6-luna","output":20,"provider":"openai","reasoning":8}"#)
        #expect(log.records().map(\.input) == [1000, 1100])
    }

    @Test func summarizesTheLastRequestAndToday() throws {
        let log = temporaryLog()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let yesterday = now.addingTimeInterval(-86_400)
        log.append(UsageRecord(date: yesterday, provider: "p", model: "m",
                               usage: TokenUsage(inputTokens: 5000, cachedInputTokens: 0, outputTokens: 10)))
        log.append(UsageRecord(date: now.addingTimeInterval(-60), provider: "p", model: "m",
                               usage: TokenUsage(inputTokens: 1000, cachedInputTokens: 0, outputTokens: 10)))
        log.append(UsageRecord(date: now, provider: "p", model: "m",
                               usage: TokenUsage(inputTokens: 3000, cachedInputTokens: 2000, outputTokens: 30)))
        // A damaged line is skipped.
        let handle = try FileHandle(forWritingTo: log.fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{not json\n".utf8))
        try handle.close()

        let summary = log.summary(now: now, calendar: calendar)
        #expect(summary.last?.input == 3000)
        #expect(summary.today.requests == 2)
        #expect(summary.today.input == 4000)
        #expect(summary.today.cached == 2000)
        #expect(summary.today.output == 40)
        #expect(summary.today.cachedShare == 0.5)
    }

    @Test func aMissingLogIsEmpty() {
        let summary = temporaryLog().summary()
        #expect(summary.last == nil)
        #expect(summary.today.requests == 0)
    }

    @Test func theLoopLogsEachRequestWithoutChangingTheThread() async throws {
        let store = try ThreadStore(fileURL: temporaryThreadFile())
        let usage = TokenUsage(inputTokens: 50, cachedInputTokens: 0, outputTokens: 5)
        let provider = FakeProvider(replies: [
            [.item(toolCall("a", name: "record", arguments: [:])), .usage(usage, provider: "test", model: "m")],
            [.item(assistant("done")), .usage(usage, provider: "test", model: "m")],
        ])
        let log = temporaryLog()
        let loop = AgentLoop(provider: provider, thread: store, tools: [RecordingTool()], usageLog: log)
        try await loop.run("go", onEvent: { _ in }, confirm: { _ in true })
        #expect(log.records().count == 2)
        #expect(log.records().allSatisfy { $0.model == "m" && $0.provider == "test" })
        #expect(await store.entries.count == 4)
    }
}
