import Foundation

/// What the loop reports to the panel while it works.
public enum AgentEvent: Sendable, Equatable {
    /// An entry was written to the thread.
    case entryAdded(ThreadEntry)
    /// More of the text the model is writing. The finished text also arrives as an entry.
    case textDelta(String)
    /// The model began a tool call.
    case toolCallStarted(callID: String, name: String)
    /// A tool began running.
    case toolRunning(callID: String, summary: String)
    /// A tool finished. Its result also arrives as an entry.
    case toolFinished(callID: String)
}

public enum AgentLoopError: Error, Equatable, LocalizedError {
    case tooManySteps(Int)

    public var errorDescription: String? {
        switch self {
        case .tooManySteps(let count): "Stopped after \(count) model replies without finishing."
        }
    }
}

/// The agent loop: send the thread to the model, stream the reply, run the tools it asks
/// for, add the results, and repeat until the model replies without asking for a tool.
public final class AgentLoop: Sendable {
    public let provider: any ModelProvider
    public let thread: ThreadStore
    public let tools: [any AgentTool]
    /// Read once at the start of each instruction from the person, so an edit in Settings or a
    /// new skill applies from the next instruction and the text stays the same while one runs.
    public let instructions: @Sendable () async -> String
    public let maximumModelReplies: Int
    /// Where each request's token counts go. Nil keeps no record.
    public let usageLog: UsageLog?

    public init(
        provider: any ModelProvider,
        thread: ThreadStore,
        tools: [any AgentTool],
        instructions: @escaping @Sendable () async -> String = { AgentInstructions.defaultPrompt },
        maximumModelReplies: Int = 40,
        usageLog: UsageLog? = nil
    ) {
        self.provider = provider
        self.thread = thread
        self.tools = tools
        self.instructions = instructions
        self.maximumModelReplies = maximumModelReplies
        self.usageLog = usageLog
    }

    public convenience init(
        provider: any ModelProvider, thread: ThreadStore, tools: [any AgentTool], instructions: String,
        maximumModelReplies: Int = 40
    ) {
        self.init(
            provider: provider, thread: thread, tools: tools, instructions: { instructions },
            maximumModelReplies: maximumModelReplies)
    }

    /// Handles one instruction from the person. Returns when the model has finished, and
    /// throws `CancellationError` when the surrounding task is cancelled.
    public func run(
        _ userText: String,
        onEvent: @escaping @Sendable (AgentEvent) async -> Void,
        confirm: @escaping @Sendable (ConfirmationRequest) async -> Bool
    ) async throws {
        // A call left without a result, because the app quit or a task was stopped, would make
        // the next request invalid. Answer it at the end of the thread instead of editing history.
        for call in await thread.unansweredToolCalls() {
            let entry = try await thread.append(.toolResult(.init(
                callID: call.callID,
                output: "This command did not finish. The app quit or the task was stopped while it ran.")))
            await onEvent(.entryAdded(entry))
        }

        await onEvent(.entryAdded(try await thread.append(.userMessage(text: userText))))
        let definitions = tools.map(\.definition)
        let instructions = await self.instructions()
        let fingerprint = PromptFingerprint.make(instructions: instructions, tools: definitions)

        for _ in 0..<maximumModelReplies {
            try Task.checkCancellation()
            let request = ModelRequest(instructions: instructions, entries: await thread.entries, tools: definitions)
            var calls: [ThreadItem.ToolCall] = []
            let started = ContinuousClock.now
            for try await event in provider.streamReply(to: request) {
                switch event {
                case .textDelta(let text):
                    await onEvent(.textDelta(text))
                case .toolCallStarted(let callID, let name):
                    await onEvent(.toolCallStarted(callID: callID, name: name))
                case .usage(let usage, let providerName, let model):
                    let elapsed = ContinuousClock.now - started
                    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                    usageLog?.append(UsageRecord(
                        date: Date(), provider: providerName, model: model, usage: usage,
                        seconds: (seconds * 10).rounded() / 10, prompt: fingerprint))
                case .item(let item):
                    if case .toolCall(let call) = item { calls.append(call) }
                    await onEvent(.entryAdded(try await thread.append(item)))
                }
            }
            try Task.checkCancellation()
            if calls.isEmpty { return }

            for call in calls {
                let output = await runTool(call, onEvent: onEvent, confirm: confirm)
                await onEvent(.entryAdded(try await thread.append(.toolResult(.init(callID: call.callID, output: output)))))
                await onEvent(.toolFinished(callID: call.callID))
                try Task.checkCancellation()
            }
        }
        throw AgentLoopError.tooManySteps(maximumModelReplies)
    }

    private func runTool(
        _ call: ThreadItem.ToolCall,
        onEvent: @Sendable (AgentEvent) async -> Void,
        confirm: @escaping @Sendable (ConfirmationRequest) async -> Bool
    ) async -> String {
        guard let tool = tools.first(where: { $0.definition.name == call.name }) else {
            return "Error: there is no tool named \(call.name)."
        }
        guard let arguments = JSONValue.parse(call.arguments), case .object = arguments else {
            return "Error: the arguments were not a JSON object."
        }
        await onEvent(.toolRunning(callID: call.callID, summary: tool.summary(arguments: arguments)))
        return await tool.run(arguments: arguments, context: ToolRunContext(callID: call.callID, confirm: confirm))
    }
}
