import Foundation

/// The one tool: run a command in zsh and return what it printed.
public struct ShellCommandTool: AgentTool {
    public static let name = "run_shell_command"

    /// How long a command may run before it is stopped.
    public var timeout: Duration
    /// The most output passed back to the model. Longer output keeps its start and end.
    public var outputLimit: Int

    public init(timeout: Duration = .seconds(120), outputLimit: Int = 16_000) {
        self.timeout = timeout
        self.outputLimit = outputLimit
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: Self.name,
            description: """
                Run a command with /bin/zsh as the signed-in user on this Mac and return its combined \
                output and exit status. Commands run without a terminal and cannot read input. \
                Commands that take longer than \(Int(timeout.components.seconds)) seconds are stopped.
                """,
            parameters: [
                "type": "object",
                "properties": [
                    "command": [
                        "type": "string",
                        "description": "The command line to run.",
                    ],
                    "destructive": [
                        "type": "boolean",
                        "description": """
                            True when the command deletes, overwrites, uninstalls, quits, or otherwise \
                            changes something that is hard to undo. The person is asked before it runs.
                            """,
                    ],
                ],
                "required": ["command", "destructive"],
                "additionalProperties": false,
            ]
        )
    }

    public func summary(arguments: JSONValue) -> String {
        arguments["command"]?.stringValue ?? "(no command)"
    }

    public func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        guard let command = arguments["command"]?.stringValue,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return "Error: the call did not include a command."
        }
        let markedDestructive = arguments["destructive"]?.boolValue ?? true
        if let reason = DestructiveCommandCheck.reasonToConfirm(command: command, markedDestructive: markedDestructive) {
            let approved = await context.confirm(
                ConfirmationRequest(callID: context.callID, command: command, reason: reason))
            if !approved {
                return "The person declined to run this command. It did not run."
            }
        }
        if Task.isCancelled { return "The task was stopped before the command ran." }
        return await execute(command)
    }

    func execute(_ command: String) async -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/zsh")
        process.arguments = ["-l", "-c", command]
        // Commands start in the home folder, like a new Terminal window.
        process.currentDirectoryURL = URL.homeDirectory
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let output = OutputCollector()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            output.append(handle.availableData)
        }

        let finished = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { finishedProcess in
            finished.continuation.yield(finishedProcess.terminationStatus)
            finished.continuation.finish()
        }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return "Error: could not start zsh: \(error.localizedDescription)"
        }

        let timeout = self.timeout
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            output.markTimedOut()
            process.terminate()
        }
        let status = await withTaskCancellationHandler {
            var status: Int32 = -1
            for await value in finished.stream { status = value }
            return status
        } onCancel: {
            process.terminate()
        }
        watchdog.cancel()

        // A command can leave a background process holding the pipe open, so read what is
        // already there instead of waiting for the pipe to close.
        try? await Task.sleep(for: .milliseconds(100))
        pipe.fileHandleForReading.readabilityHandler = nil

        var result = Self.limit(output.text, to: outputLimit)
        if result.isEmpty { result = "(no output)" }
        if Task.isCancelled {
            result += "\n[The task was stopped while this command ran.]"
        } else if output.timedOut {
            result += "\n[Stopped after the \(Int(timeout.components.seconds)) second limit.]"
        }
        result += "\n[exit status \(status)]"
        return result
    }

    static func limit(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let half = limit / 2
        let omitted = text.count - limit
        return String(text.prefix(half)) + "\n[… \(omitted) characters omitted …]\n" + String(text.suffix(half))
    }
}

/// Collects a command's output from the pipe's reading thread.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var didTimeOut = false

    func append(_ chunk: Data) {
        lock.withLock { data.append(chunk) }
    }

    func markTimedOut() {
        lock.withLock { didTimeOut = true }
    }

    var timedOut: Bool { lock.withLock { didTimeOut } }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
