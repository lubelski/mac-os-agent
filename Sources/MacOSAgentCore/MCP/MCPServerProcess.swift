import Foundation
import Synchronization

/// Where an MCP server's command is looked for, and the environment it starts with.
///
/// An app opened from Finder gets launchd's short PATH, not the shell's, so `npx` and `uvx`
/// would not be found. The shell tool gets around it by running every command in a login zsh.
/// A server cannot start that way, because a login shell's profile may print to standard
/// output, which is the server's channel. So the PATH a login zsh sets up is read once, between
/// markers, and the folders that `npx`, `uvx`, and the like usually live in are added after it.
/// The command is then found on that PATH and started directly, with that PATH.
public enum MCPEnvironment {
    /// Folders that commonly hold node, uv, bun, deno, cargo, and Homebrew tools, in this order,
    /// after the login shell's PATH. Only the ones that exist are used.
    static func wellKnownFolders(home: String = NSHomeDirectory()) -> [String] {
        var folders = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
            "\(home)/.local/bin", "\(home)/.cargo/bin", "\(home)/.bun/bin", "\(home)/.deno/bin",
            "\(home)/.volta/bin", "\(home)/Library/pnpm", "\(home)/.local/share/mise/shims", "\(home)/.asdf/shims",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        // nvm keeps each node version in a folder of its own. The newest is used.
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm),
           let newest = versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedAscending }).last
        {
            folders.insert("\(nvm)/\(newest)/bin", at: 3)
        }
        return folders.filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// The PATH a login zsh sets up, read once and kept. Empty when zsh does not answer within
    /// a few seconds.
    static let loginShellPath: [String] = readLoginShellPath()

    /// The PATH a server starts with: the login shell's, then the well-known folders, then the
    /// app's own, without repeats.
    public static var searchPath: [String] {
        var seen = Set<String>()
        let own = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return (loginShellPath + wellKnownFolders() + own).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The app's environment with the search PATH, and the entry's own `env` on top. An `env`
    /// that sets PATH wins.
    public static func environment(for entry: MCPServerEntry, path: [String] = searchPath) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path.joined(separator: ":")
        for (key, value) in entry.env { environment[key] = value }
        return environment
    }

    /// The command's full path: as written when it has a slash, after `~`, or else the first
    /// executable file of that name on the PATH. Nil when there is none.
    public static func resolve(_ command: String, path: String) -> String? {
        let manager = FileManager.default
        if command.contains("/") {
            let full = (command as NSString).expandingTildeInPath
            return manager.isExecutableFile(atPath: full) ? full : nil
        }
        for folder in path.split(separator: ":") {
            let candidate = "\(folder)/\(command)"
            var isFolder: ObjCBool = false
            if manager.fileExists(atPath: candidate, isDirectory: &isFolder), !isFolder.boolValue,
               manager.isExecutableFile(atPath: candidate)
            {
                return candidate
            }
        }
        return nil
    }

    private static let marker = "__MAC_OS_AGENT_PATH__"

    private static func readLoginShellPath() -> [String] {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/zsh")
        process.arguments = ["-l", "-c", "printf '\\n\(marker)%s\(marker)\\n' \"$PATH\""]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        do { try process.run() } catch { return [] }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            return []
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let parts = text.components(separatedBy: marker)
        guard parts.count >= 3 else { return [] }
        return parts[1].split(separator: ":").map(String.init)
    }
}

/// A server's process, started by the app as the leader of its own process group, with pipes
/// for its standard input, output, and error. Stopping it reaches everything it started, such
/// as the node process `npx` runs.
public final class MCPServerProcess: Sendable {
    public let processID: pid_t
    /// The app reads the server's standard output here.
    public let outputDescriptor: Int32
    /// The app writes to the server's standard input here.
    public let inputDescriptor: Int32
    private let errorTail: Mutex<Data>
    private let exit: Mutex<(status: Int32?, waiters: [CheckedContinuation<Int32, Never>])>
    private let errorHandle: FileHandle
    private let closed = Mutex(false)

    /// The process groups of every server still running, so the app can stop them all as it quits.
    private static let running = Mutex<Set<pid_t>>([])

    /// How much of standard error is kept, for the reason a server failed.
    static let errorTailLimit = 2_000

    private init(processID: pid_t, output: Int32, input: Int32, error: Int32) {
        self.processID = processID
        outputDescriptor = output
        inputDescriptor = input
        errorTail = Mutex(Data())
        exit = Mutex((nil, []))
        errorHandle = FileHandle(fileDescriptor: error, closeOnDealloc: true)
    }

    /// Starts the entry's command, found on the search PATH. Throws `MCPConnectionError`.
    public static func launch(_ entry: MCPServerEntry) throws -> MCPServerProcess {
        let environment = MCPEnvironment.environment(for: entry)
        guard let executable = MCPEnvironment.resolve(entry.command, path: environment["PATH"] ?? "") else {
            throw MCPConnectionError.commandNotFound(entry.command)
        }
        return try launch(executable: executable, arguments: entry.args, environment: environment)
    }

    static func launch(executable: String, arguments: [String], environment: [String: String]) throws -> MCPServerProcess {
        var input: [Int32] = [0, 0]
        var output: [Int32] = [0, 0]
        var error: [Int32] = [0, 0]
        guard pipe(&input) == 0, pipe(&output) == 0, pipe(&error) == 0 else {
            throw MCPConnectionError.couldNotStart(String(cString: strerror(errno)))
        }
        // Writing to a server that has exited fails with EPIPE instead of killing the app.
        _ = fcntl(input[1], F_SETNOSIGPIPE, 1)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, input[0], 0)
        posix_spawn_file_actions_adddup2(&actions, output[1], 1)
        posix_spawn_file_actions_adddup2(&actions, error[1], 2)
        // Servers start in the home folder. This app has no working directory of its own.
        posix_spawn_file_actions_addchdir(&actions, URL.homeDirectory.path)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(
            POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        let argv = ([executable] + arguments).map { strdup($0) }
        defer { argv.forEach { free($0) } }
        var argvList = argv + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") }
        defer { envp.forEach { free($0) } }
        var envList = envp + [nil]

        var processID: pid_t = 0
        let result = posix_spawn(&processID, executable, &actions, &attributes, &argvList, &envList)
        // The child's ends are the child's now.
        close(input[0])
        close(output[1])
        close(error[1])
        guard result == 0 else {
            close(input[1])
            close(output[0])
            close(error[0])
            throw MCPConnectionError.couldNotStart(String(cString: strerror(result)))
        }
        let launchedID = processID
        running.withLock { _ = $0.insert(launchedID) }
        let process = MCPServerProcess(processID: launchedID, output: output[0], input: input[1], error: error[0])
        process.errorHandle.readabilityHandler = { [weak process] handle in
            let chunk = handle.availableData
            guard let process else { return }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            process.errorTail.withLock { tail in
                tail.append(chunk)
                if tail.count > errorTailLimit { tail = tail.suffix(errorTailLimit) }
            }
        }
        DispatchQueue.global().async { [process] in
            var status: Int32 = 0
            while waitpid(launchedID, &status, 0) == -1 && errno == EINTR {}
            let signal = status & 0x7f
            let code = signal == 0 ? (status >> 8) & 0xff : 128 + signal
            running.withLock { _ = $0.remove(launchedID) }
            let waiters = process.exit.withLock { state in
                state.status = code
                defer { state.waiters = [] }
                return state.waiters
            }
            for waiter in waiters { waiter.resume(returning: code) }
        }
        return process
    }

    /// The exit status once the process has exited.
    public var exitStatus: Int32? { exit.withLock { $0.status } }

    /// Waits for the process to exit and returns its status.
    public func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            let status = exit.withLock { state -> Int32? in
                if let status = state.status { return status }
                state.waiters.append(continuation)
                return nil
            }
            if let status { continuation.resume(returning: status) }
        }
    }

    /// The last lines the server wrote to standard error, on one line.
    public var errorText: String {
        let text = errorTail.withLock { String(decoding: $0, as: UTF8.self) }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.suffix(3).joined(separator: " ")
    }

    /// Asks the process group to end, and kills what is left after the grace period. Closes
    /// the app's ends of the pipes.
    public func stop(gracePeriod: Duration = .seconds(2)) async {
        closeDescriptors()
        killpg(processID, SIGTERM)
        let exited = await withTaskGroup(of: Bool.self) { group in
            group.addTask { _ = await self.waitForExit(); return true }
            group.addTask { try? await Task.sleep(for: gracePeriod); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        // The leader may have exited and left a child behind, so the rest of the group goes too.
        _ = exited
        killpg(processID, SIGKILL)
    }

    /// Closes the app's ends of the pipes, once. The server sees its input end.
    public func closeDescriptors() {
        let wasClosed = closed.withLock { closed in
            defer { closed = true }
            return closed
        }
        guard !wasClosed else { return }
        close(inputDescriptor)
        close(outputDescriptor)
    }

    /// Stops every server process still running, for the app quitting. It waits up to the grace
    /// period for them to exit, then kills what is left, so none outlives the app.
    public static func stopAll(gracePeriod: TimeInterval = 1) {
        let groups = running.withLock { $0 }
        guard !groups.isEmpty else { return }
        for group in groups { killpg(group, SIGTERM) }
        let deadline = Date().addingTimeInterval(gracePeriod)
        while Date() < deadline, !running.withLock({ $0.isEmpty }) {
            Thread.sleep(forTimeInterval: 0.02)
        }
        // Whatever is left in each group, leader or not.
        for group in groups { killpg(group, SIGKILL) }
    }

    /// The process groups still running, for tests.
    public static var runningProcessGroups: Set<pid_t> { running.withLock { $0 } }
}
