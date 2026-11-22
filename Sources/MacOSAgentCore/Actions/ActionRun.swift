import Foundation
import Synchronization

extension ThreadItem {
    /// The record of a saved action the owner ran from the instant row, kept on their message
    /// in the thread. The model is sent `message` in place of the typed text, so when the owner
    /// follows up ("undo that"), the agent knows what ran and what came of it.
    ///
    /// It is an owner's message rather than tool calls, because the model made no calls: a
    /// function call in the request with no model turn that made it would not be valid input.
    /// It is appended at the end like any message, so the request's prefix stays as it was.
    public struct ActionRun: Sendable, Equatable, Codable {
        public struct Step: Sendable, Equatable, Codable {
            /// The id of the step's row in the panel, which the inspector opens it by.
            public var callID: String
            public var tool: String
            /// The arguments as JSON text, the same shape as a model's call.
            public var arguments: String
            public var output: String
            public var details: ToolRunDetails?
            /// Why the step would have asked for a go-ahead had the agent made the call. It did
            /// not ask, since running the action was the go-ahead.
            public var goAheadReason: String?

            public init(callID: String, tool: String, arguments: String, output: String, details: ToolRunDetails? = nil, goAheadReason: String? = nil) {
                self.callID = callID
                self.tool = tool
                self.arguments = arguments
                self.output = output
                self.details = details
                self.goAheadReason = goAheadReason
            }

            /// The step as a stored tool call, for the panel's row and the inspector.
            public var call: ThreadItem.ToolCall {
                ThreadItem.ToolCall(callID: callID, name: tool, arguments: arguments, provider: "mac-os-agent", model: "action")
            }
        }

        /// The action's id, its file's name.
        public var id: String
        public var name: String
        /// How many steps the action has. Steps after a failed one did not run and are not in `steps`.
        public var stepCount: Int
        /// The steps that ran, in order.
        public var steps: [Step]
        /// The index of the step that failed, which stopped the run. Nil when every step finished.
        public var failedStep: Int?
        /// What the model is sent for this message. Stored whole, like a skill's message, so a
        /// later request in the episode sends exactly the same text.
        public var message: String

        public init(id: String, name: String, stepCount: Int, steps: [Step], failedStep: Int?, message: String) {
            self.id = id
            self.name = name
            self.stepCount = stepCount
            self.steps = steps
            self.failedStep = failedStep
            self.message = message
        }

        /// One line on how it ended, for the panel: nil when every step finished, and otherwise
        /// which step failed and what did not run.
        public var outcomeNotice: String? {
            guard let failedStep else { return nil }
            let skipped = stepCount - failedStep - 1
            let rest = skipped == 0 ? "" : skipped == 1 ? " The step after it did not run." : " The \(skipped) steps after it did not run."
            return stepCount == 1 ? "\(name) failed." : "\(name) stopped at step \(failedStep + 1) of \(stepCount).\(rest)"
        }

        /// The most of each step's output the model's note carries.
        public static let messageOutputLimit = 1_500

        /// The note the model reads for the run, between `<action_run>` tags.
        public static func message(
            typed: String, action: SavedAction, steps: [Step], failedStep: Int?
        ) -> String {
            var lines = [
                "<action_run>",
                "The person typed \"\(typed)\" and ran their quick action \"\(action.name)\" (\(action.id)) from the instant row. "
                    + "The app ran its steps itself, without you. Choosing it from the list was their go-ahead, so nothing asked.",
            ]
            for (index, step) in steps.enumerated() {
                var output = step.output
                if output.count > messageOutputLimit { output = String(output.prefix(messageOutputLimit)) + "\n[shortened]" }
                lines.append("Step \(index + 1) of \(action.steps.count): \(step.tool) \(step.arguments)")
                lines.append("Result: \(output)")
            }
            if let failedStep {
                let skipped = action.steps.count - failedStep - 1
                lines.append(skipped > 0
                    ? "Step \(failedStep + 1) failed, so the app stopped and the \(skipped) after it did not run."
                    : "Step \(failedStep + 1) failed.")
            } else {
                lines.append(action.steps.count == 1 ? "It finished." : "All \(action.steps.count) steps finished.")
            }
            lines.append("No reply was asked for. This is a record, so you know it happened if they refer to it.")
            lines.append("</action_run>")
            return lines.joined(separator: "\n")
        }
    }
}

/// What the panel needs to show an action's run before it ends.
public struct ActionRunStart: Sendable, Equatable {
    /// The id the run's entry will have in the thread.
    public var entryID: UUID
    public var date: Date
    /// What the owner typed.
    public var text: String
    public var name: String

    public init(entryID: UUID, date: Date, text: String, name: String) {
        self.entryID = entryID
        self.date = date
        self.text = text
        self.name = name
    }

    /// The row id of a step, such as `…-step-1`.
    public static func callID(entryID: UUID, index: Int) -> String {
        "\(entryID.uuidString)-step-\(index + 1)"
    }
}

extension AgentLoop {
    /// Runs a saved action the owner chose in the instant row, with no model request, and
    /// keeps a record of it in the thread.
    ///
    /// The steps run in order through the same tools the model's calls use, and the run stops
    /// at the first that fails. Every go-ahead a step would ask for is given at once: the owner
    /// chose the action from a list, so they have already said yes. Refusals that are not a
    /// go-ahead, such as a theme that is too hard to read, still stop a step.
    ///
    /// The record is one owner's message at the end of the thread, after an episode marker and
    /// answers to any unanswered calls, as a typed message would be. Stopping the task stops the
    /// step that is running, and the record says so.
    @discardableResult
    public func runAction(
        _ action: SavedAction,
        typed: String,
        startsNewEpisode: Bool = false,
        now: Date = Date(),
        onEvent: @escaping @Sendable (AgentEvent) async -> Void
    ) async throws -> ThreadEntry {
        try await prepareForOwnerEntry(startsNewEpisode: startsNewEpisode, now: now, onEvent: onEvent)
        let entryID = UUID()
        await onEvent(.actionStarted(ActionRunStart(entryID: entryID, date: now, text: typed, name: action.name)))
        let episodeID = await thread.currentEpisode?.id

        var steps: [ThreadItem.ActionRun.Step] = []
        var failedStep: Int?
        for (index, step) in action.steps.enumerated() {
            let callID = ActionRunStart.callID(entryID: entryID, index: index)
            let arguments = step.arguments.encodedString()
            let call = ThreadItem.ToolCall(callID: callID, name: step.tool, arguments: arguments, provider: "mac-os-agent", model: "action")
            await onEvent(.toolCallStarted(callID: callID, name: step.tool))
            let asked = Mutex<String?>(nil)
            var (output, details) = await runTool(call, episodeID: episodeID, onEvent: onEvent, confirm: { request in
                asked.withLock { $0 = request.reason }
                return true
            })
            let reason = asked.withLock { $0 }
            if reason != nil {
                details?.goAhead = .preapproved
                details?.waitedSeconds = nil
            }
            steps.append(.init(callID: callID, tool: step.tool, arguments: arguments, output: output, details: details, goAheadReason: reason))
            await onEvent(.toolFinished(callID: callID))
            let outcome = TranscriptRow.outcome(ofOutput: output)
            if outcome == .failed || outcome == .stopped || outcome == .declined || Task.isCancelled {
                failedStep = index
                break
            }
        }
        let record = ThreadItem.ActionRun(
            id: action.id, name: action.name, stepCount: action.steps.count, steps: steps, failedStep: failedStep,
            message: ThreadItem.ActionRun.message(typed: typed, action: action, steps: steps, failedStep: failedStep))
        let entry = try await thread.append(.userMessage(text: typed, action: record), date: now, id: entryID)
        await onEvent(.entryAdded(entry))
        return entry
    }
}
