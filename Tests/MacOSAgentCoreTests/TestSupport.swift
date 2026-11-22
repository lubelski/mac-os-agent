import Foundation
@testable import MacOSAgentCore

/// A provider that plays back scripted replies and records every request it receives.
final class FakeProvider: ModelProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [[ModelStreamEvent]]
    private var recorded: [ModelRequest] = []
    /// When set, each reply waits this long before its first event.
    var delay: Duration?

    init(replies: [[ModelStreamEvent]]) {
        self.replies = replies
    }

    var requests: [ModelRequest] { lock.withLock { recorded } }

    func streamReply(to request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        let events: [ModelStreamEvent] = lock.withLock {
            recorded.append(request)
            return replies.isEmpty ? [] : replies.removeFirst()
        }
        let delay = delay
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let delay { try await Task.sleep(for: delay) }
                    for event in events { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// A tool that records its calls and returns a fixed result.
final class RecordingTool: AgentTool, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [JSONValue] = []
    let result: String

    init(result: String = "done") {
        self.result = result
    }

    var received: [JSONValue] { lock.withLock { calls } }

    var definition: ToolDefinition {
        ToolDefinition(name: "record", description: "Records calls.", parameters: ["type": "object"])
    }

    func summary(arguments: JSONValue) -> String { "record" }

    func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        lock.withLock { calls.append(arguments) }
        return result
    }
}

/// Collects agent events.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AgentEvent] = []

    var events: [AgentEvent] { lock.withLock { stored } }

    func record(_ event: AgentEvent) {
        lock.withLock { stored.append(event) }
    }
}

final class MemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]

    init(_ values: [String: String] = [:]) {
        self.values = values
    }

    func read(_ key: String) -> String? { lock.withLock { values[key] } }
    func write(_ value: String, for key: String) throws { lock.withLock { values[key] = value } }
    func delete(_ key: String) { _ = lock.withLock { values.removeValue(forKey: key) } }
}

final class FakeTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [URLRequest] = []
    let status: Int
    let body: Data

    init(status: Int = 200, body: JSONValue) {
        self.status = status
        self.body = Data(body.encodedString().utf8)
    }

    var requests: [URLRequest] { lock.withLock { sent } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { sent.append(request) }
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

func temporaryThreadFile() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "mac-os-agent-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        .appending(path: "thread.jsonl")
}

func toolCall(_ callID: String, name: String, arguments: JSONValue, model: String = "test-model") -> ThreadItem {
    .toolCall(.init(
        callID: callID, name: name, arguments: arguments.encodedString(), provider: "test", model: model,
        providerID: "fc_\(callID)"))
}

func assistant(_ text: String) -> ThreadItem {
    .assistantMessage(.init(text: text, provider: "test", model: "test-model"))
}
