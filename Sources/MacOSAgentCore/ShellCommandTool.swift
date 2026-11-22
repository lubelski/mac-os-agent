import Foundation

/// The one tool: run a command in zsh and return what it printed.
public struct ShellCommandTool: AgentTool {
    public static let name = "run_shell_command"

    /// How long a command may run before it is stopped.
    public var timeout: Duration
    /// The most output passed back to the model. Longer output keeps its start and end.
    public var outputLimit: Int
    /// How long a stopped command has to exit after SIGTERM before everything it started gets SIGKILL.
    public var killGracePeriod: Duration

    public init(timeout: Duration = .seconds(120), outputLimit: Int = 16_000, killGracePeriod: Duration = .seconds(2)) {
        self.timeout = timeout
        self.outputLimit = outputLimit
        self.killGracePeriod = killGracePeriod
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

    public var goAhead: ToolGoAhead {
        .sometimes("""
            Asks when the model marks a command destructive, or when the command matches the app's \
            own list of patterns for deleting, overwriting, uninstalling, quitting, killing processes, \
            sudo, and system settings. Either one is enough.
            """)
    }

    /// The output when the owner declines the go-ahead.
    public static let declinedOutput = "The person declined to run this command. It did not run."
    /// The output when the task was stopped before the command started.
    public static let stoppedBeforeRunningOutput = "The task was stopped before the command ran."
    /// The note added to the output when the task was stopped while the command ran.
    public static let stoppedWhileRunningNote = "[The task was stopped while this command ran.]"

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
                return Self.declinedOutput
            }
        }
        if Task.isCancelled { return Self.stoppedBeforeRunningOutput }
        return await execute(command)
    }

    func execute(_ command: String) async -> String {
        let launched: LaunchedCommand
        do {
            launched = try LaunchedCommand.start(command)
        } catch {
            return "Error: could not start zsh: \(error.localizedDescription)"
        }

        let output = OutputCollector()
        launched.output.readabilityHandler = { handle in
            output.append(handle.availableData)
        }

        let timeout = self.timeout
        let gracePeriod = self.killGracePeriod
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            output.markTimedOut()
            launched.stop(gracePeriod: gracePeriod)
        }
        let status = await withTaskCancellationHandler {
            await launched.exitStatus()
        } onCancel: {
            launched.stop(gracePeriod: gracePeriod)
        }
        watchdog.cancel()

        // A command can leave a background process holding the pipe open, so read what is
        // already there instead of waiting for the pipe to close.
        try? await Task.sleep(for: .milliseconds(100))
        launched.output.readabilityHandler = nil

        var result = Self.limit(output.text, to: outputLimit)
        if result.isEmpty { result = "(no output)" }
        if Task.isCancelled {
            result += "\n" + Self.stoppedWhileRunningNote
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

/// A zsh process started as the leader of its own process group, so stopping it reaches
/// everything it started, not only zsh.
///
/// `Process` would do for starting zsh, but it has no documented way to choose the process
/// group, so this uses `posix_spawn` with `POSIX_SPAWN_SETPGROUP`.
private struct LaunchedCommand: Sendable {
    /// zsh's process ID, which is also the ID of the process group it leads.
    let processID: pid_t
    /// The reading end of the pipe that carries both standard output and standard error.
    let output: FileHandle
    private let exit: AsyncStream<Int32>

    static func start(_ command: String) throws -> LaunchedCommand {
        var pipeEnds: [Int32] = [0, 0]
        guard pipe(&pipeEnds) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let readEnd = pipeEnds[0]
        let writeEnd = pipeEnds[1]
        defer { close(writeEnd) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 2)
        // Commands start in the home folder, like a new Terminal window.
        posix_spawn_file_actions_addchdir(&actions, URL.homeDirectory.path)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // A new process group whose ID is zsh's own process ID. Every other descriptor is closed
        // in the child, and signals start from their defaults and unblocked.
        posix_spawnattr_setflags(&attributes, Int16(
            POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        let arguments = ["/bin/zsh", "-l", "-c", command].map { strdup($0) }
        defer { arguments.forEach { free($0) } }
        var argv = arguments + [nil]

        var processID: pid_t = 0
        let result = posix_spawn(&processID, "/bin/zsh", &actions, &attributes, &argv, environ)
        guard result == 0 else {
            close(readEnd)
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
        }

        let exit = AsyncStream<Int32>.makeStream()
        let launchedID = processID
        DispatchQueue.global().async {
            var status: Int32 = 0
            while waitpid(launchedID, &status, 0) == -1 && errno == EINTR {}
            exit.continuation.yield(Self.terminationStatus(status))
            exit.continuation.finish()
        }
        return LaunchedCommand(
            processID: launchedID,
            output: FileHandle(fileDescriptor: readEnd, closeOnDealloc: true),
            exit: exit.stream)
    }

    /// Waits for zsh to exit. Returns its exit code, or the signal that ended it.
    func exitStatus() async -> Int32 {
        var status: Int32 = -1
        for await value in exit { status = value }
        return status
    }

    /// Sends SIGTERM to the whole process group, then SIGKILL to whatever is left of it after
    /// the grace period. Only for a command being stopped. A command that finished on its own
    /// leaves its background processes alone.
    func stop(gracePeriod: Duration) {
        let group = processID
        killpg(group, SIGTERM)
        Task.detached {
            try? await Task.sleep(for: gracePeriod)
            // Fails harmlessly with ESRCH when every process in the group has exited.
            killpg(group, SIGKILL)
        }
    }

    /// The same value `Process.terminationStatus` gives: the exit code, or the signal number.
    private static func terminationStatus(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : signal
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
