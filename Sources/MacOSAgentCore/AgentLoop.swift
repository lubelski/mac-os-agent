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

/// The agent loop: send the current episode to the model, stream the reply, run the tools it
/// asks for, add the results, and repeat until the model replies without asking for a tool.
///
/// The loop runs the same against the kept thread and an incognito conversation held in memory.
public final class AgentLoop: Sendable {
    /// The result a call gets when the task was stopped before it ran, such as the second of two
    /// calls in one reply, or a call the model had written when its reply was cut off.
    public static let stoppedBeforeRunningOutput = "The task was stopped before this call ran."
    /// The result a call left without one gets at the start of the next instruction, when the
    /// app quit while it ran.
    public static let unfinishedOutput = "This command did not finish. The app quit or the task was stopped while it ran."

    public let provider: any ModelProvider
    public let thread: any ThreadStorage
    public let tools: [any AgentTool]
    /// Read once at the start of each instruction from the person, so an edit in Settings or a
    /// new skill applies from the next instruction and the text stays the same while one runs.
    public let instructions: @Sendable () async -> String
    public let maximumModelReplies: Int
    /// Where each request's token counts go. Nil keeps no record.
    public let usageLog: UsageLog?
    /// How long an episode can sit idle before the owner's next message starts a new one.
    public let episodeTimeout: @Sendable () -> TimeInterval

    public init(
        provider: any ModelProvider,
        thread: any ThreadStorage,
        tools: [any AgentTool],
        instructions: @escaping @Sendable () async -> String = { AgentInstructions.defaultPrompt },
        maximumModelReplies: Int = 40,
        usageLog: UsageLog? = nil,
        episodeTimeout: @escaping @Sendable () -> TimeInterval = { TimeInterval(EpisodeTimeoutSetting.defaultMinutes * 60) }
    ) {
        self.provider = provider
        self.thread = thread
        self.tools = tools
        self.instructions = instructions
        self.maximumModelReplies = maximumModelReplies
        self.usageLog = usageLog
        self.episodeTimeout = episodeTimeout
    }

    public convenience init(
        provider: any ModelProvider, thread: any ThreadStorage, tools: [any AgentTool], instructions: String,
        maximumModelReplies: Int = 40
    ) {
        self.init(
            provider: provider, thread: thread, tools: tools, instructions: { instructions },
            maximumModelReplies: maximumModelReplies)
    }

    /// Handles one instruction from the person. Returns when the model has finished, and
    /// throws `CancellationError` when the surrounding task is cancelled.
    ///
    /// A stopped task leaves the thread ready for the next request: every call the model made
    /// has a result before this throws. A call that never ran gets `stoppedBeforeRunningOutput`.
    ///
    /// - Parameters:
    ///   - userText: What the owner typed.
    ///   - skill: The skill they invoked with a slash, with the message the model is sent in
    ///     place of the typed text. Nil for a plain message.
    ///   - startsNewEpisode: True when the owner asked for a fresh start, such as with `/new`.
    ///     A new episode also starts on its own when the current one has timed out.
    public func run(
        _ userText: String,
        skill: ThreadItem.SkillInvocation? = nil,
        startsNewEpisode: Bool = false,
        now: Date = Date(),
        onEvent: @escaping @Sendable (AgentEvent) async -> Void,
        confirm: @escaping @Sendable (ConfirmationRequest) async -> Bool
    ) async throws {
        // A fresh start is recorded as a marker just before the message, so the thread stays
        // append-only. An episode with nothing in it yet needs none.
        if let current = await thread.currentEpisode, current.hasActivity {
            let timedOut = current.hasTimedOut(now: now, timeout: episodeTimeout())
            if startsNewEpisode || timedOut {
                let marker = ThreadItem.episodeStart(.init(reason: startsNewEpisode ? .requested : .timeout))
                await onEvent(.entryAdded(try await thread.append(marker, date: now)))
            }
        }

        // A call left without a result, because the app quit or a task was stopped, would make
        // the next request invalid. Answer it at the end of the thread instead of editing history.
        try await answerUnansweredCalls(with: Self.unfinishedOutput, onEvent: onEvent)

        await onEvent(.entryAdded(try await thread.append(.userMessage(text: userText, skill: skill), date: now)))
        let definitions = tools.map(\.definition)
        let instructions = await self.instructions()
        let fingerprint = PromptFingerprint.make(instructions: instructions, tools: definitions)
        let episodeID = await thread.currentEpisode?.id

        do {
            try await replyAndRunTools(
                instructions: instructions, definitions: definitions, fingerprint: fingerprint, episodeID: episodeID,
                onEvent: onEvent, confirm: confirm)
        } catch {
            // Stopping can surface as the provider's own error, such as a cancelled request, so
            // any error in a cancelled task counts as stopping.
            guard Task.isCancelled else { throw error }
            try await answerUnansweredCalls(with: Self.stoppedBeforeRunningOutput, onEvent: onEvent)
            throw CancellationError()
        }
    }

    /// Answers each call in the current episode that has no result, at the end of the thread.
    private func answerUnansweredCalls(with output: String, onEvent: @Sendable (AgentEvent) async -> Void) async throws {
        for call in await thread.unansweredToolCalls() {
            let entry = try await thread.append(.toolResult(.init(callID: call.callID, output: output)))
            await onEvent(.entryAdded(entry))
            await onEvent(.toolFinished(callID: call.callID))
        }
    }

    private func replyAndRunTools(
        instructions: String, definitions: [ToolDefinition], fingerprint: String, episodeID: UUID?,
        onEvent: @escaping @Sendable (AgentEvent) async -> Void,
        confirm: @escaping @Sendable (ConfirmationRequest) async -> Bool
    ) async throws {
        for _ in 0..<maximumModelReplies {
            try Task.checkCancellation()
            // Only the current episode goes to the model. Within it the request only grows at
            // the end, so the prompt cache holds from one request to the next.
            let request = ModelRequest(
                instructions: instructions, entries: await thread.contents.currentEpisodeEntries, tools: definitions)
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
                let (output, details) = await runTool(call, episodeID: episodeID, onEvent: onEvent, confirm: confirm)
                // The details are the app's own notes for the inspector. The model only ever
                // reads the call id and the output, so they leave the request unchanged.
                let result = ThreadItem.ToolResult(callID: call.callID, output: output, details: details)
                await onEvent(.entryAdded(try await thread.append(.toolResult(result))))
                await onEvent(.toolFinished(callID: call.callID))
                try Task.checkCancellation()
            }
        }
        throw AgentLoopError.tooManySteps(maximumModelReplies)
    }

    private func runTool(
        _ call: ThreadItem.ToolCall,
        episodeID: UUID?,
        onEvent: @Sendable (AgentEvent) async -> Void,
        confirm: @escaping @Sendable (ConfirmationRequest) async -> Bool
    ) async -> (String, ToolRunDetails?) {
        guard let tool = tools.first(where: { $0.definition.name == call.name }) else {
            return ("Error: there is no tool named \(call.name).", nil)
        }
        guard let arguments = JSONValue.parse(call.arguments), case .object = arguments else {
            return ("Error: the arguments were not a JSON object.", ToolRunDetails(source: tool.source.title))
        }
        await onEvent(.toolRunning(callID: call.callID, summary: tool.summary(arguments: arguments)))

        let report = ToolRunReport()
        let startDate = Date()
        let started = ContinuousClock.now
        // The go-ahead is timed and its answer noted here, so every tool that asks gets the same record.
        let timedConfirm: @Sendable (ConfirmationRequest) async -> Bool = { request in
            let asked = ContinuousClock.now
            let approved = await confirm(request)
            let waited = Self.seconds(ContinuousClock.now - asked)
            // Stopping the task ends the wait with no answer from the owner, so none is noted.
            let stopped = !approved && Task.isCancelled
            report.note { details in
                if !stopped { details.goAhead = approved ? .approved : .declined }
                details.waitedSeconds = (details.waitedSeconds ?? 0) + waited
            }
            return approved
        }
        let context = ToolRunContext(callID: call.callID, episodeID: episodeID, report: report, confirm: timedConfirm)
        let output = await tool.run(arguments: arguments, context: context)
        let elapsed = Self.seconds(ContinuousClock.now - started)
        report.note { details in
            details.started = startDate
            details.seconds = elapsed
            details.source = tool.source.title
            if Task.isCancelled, details.stopped == nil { details.stopped = true }
            if let waited = details.waitedSeconds { details.waitedSeconds = Self.rounded(waited) }
        }
        return (output, report.details)
    }

    private static func seconds(_ duration: Duration) -> Double {
        rounded(Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
    }

    /// To the millisecond, which is as fine as the inspector shows and keeps the thread line short.
    private static func rounded(_ seconds: Double) -> Double {
        (seconds * 1000).rounded() / 1000
    }
}
