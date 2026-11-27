import Foundation

/// Runs one script in the helper, `mac-os-agent-script-runner`, and relays the tool calls it
/// makes to the app.
///
/// The helper is a process of its own, so a script that never stops can be killed, and it is
/// signed with the App Sandbox, so it has no file or network access of its own. Its source is in
/// `Sources/mac-os-agent-script-runner`.
///
/// The two sides send one JSON object per line:
/// - The app starts a script with `{"type": "start", "code", "tools"}`. Each tool is its
///   `name`, its `jsName` (the name with characters JavaScript does not allow in an identifier
///   made underscores), its `description`, and its `parameters` as a JSON string.
/// - The helper asks for a tool with `{"type": "call", "id", "tool", "arguments"}`, the
///   arguments as a JSON string, and the app answers `{"type": "result", "id", "ok", "value"}`.
///   A result that is not ok rejects the script's promise with an `Error` whose message is the
///   value.
/// - The helper sends the script's output as it is made with `{"type": "output", "text",
///   "console"}`, and ends with `{"type": "done", "ok", "value"?, "error"?}`, the error being
///   `{"message", "line"?, "stack"?}`.
public enum ScriptRunner {
    /// The helper's file name. It sits next to the app's executable in the bundle, and next to
    /// the test binaries in a SwiftPM build.
    public static let helperName = "mac-os-agent-script-runner"

    /// The helper next to the running app's executable.
    public static var bundledHelper: URL? {
        Bundle.main.executableURL?.deletingLastPathComponent().appending(path: helperName)
    }

    /// One tool as the script sees it.
    public struct Tool: Sendable, Equatable {
        public var name: String
        public var description: String
        public var parameters: JSONValue

        public init(name: String, description: String, parameters: JSONValue) {
            self.name = name
            self.description = description
            self.parameters = parameters
        }

        /// The name as a JavaScript identifier: `my-tool` is `my_tool`. Tool names allow only
        /// letters, digits, underscores, and hyphens, so hyphens are all there is to change.
        public var jsName: String {
            let name = name.replacingOccurrences(of: "-", with: "_")
            return name.first?.isNumber == true ? "_" + name : name
        }
    }

    /// What a script did.
    public struct Outcome: Sendable, Equatable {
        public enum End: Sendable, Equatable {
            /// It returned, with its return value as text, or nil when it returned nothing.
            case completed(value: String?)
            /// It threw, or could not be parsed.
            case failed(message: String, line: Int?)
            /// It ran past its time limit and was killed.
            case timedOut
            /// The task was stopped while it ran.
            case stopped
            /// The helper could not be started, or ended without saying how the script did.
            case helperFailed(String)
        }

        public var end: End
        /// The text it wrote with `text()` and `console`, in order.
        public var output: [String]
        /// How many tools it called.
        public var calls: Int
        public var seconds: Double
    }

    /// Runs `code` with these tools. `callTool` runs a call, with the tool's name and its
    /// arguments as a JSON string, and returns whether it succeeded and the text it returned.
    /// Calls are run one at a time, in the order the script made them.
    ///
    /// - Parameters:
    ///   - timeout: How long the script may run, not counting `paused` time.
    ///   - paused: Seconds to leave out of the time limit so far, such as time spent waiting
    ///     for the owner's go-ahead. Read whenever the limit is checked.
    public static func run(
        code: String,
        tools: [Tool],
        helper: URL,
        timeout: Duration,
        paused: @escaping @Sendable () -> Duration = { .zero },
        callTool: @escaping @Sendable (_ name: String, _ arguments: String) async -> (ok: Bool, value: String)
    ) async -> Outcome {
        let started = ContinuousClock.now
        func outcome(_ end: Outcome.End, output: [String] = [], calls: Int = 0) -> Outcome {
            let elapsed = ContinuousClock.now - started
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            return Outcome(end: end, output: output, calls: calls, seconds: (seconds * 10).rounded() / 10)
        }

        let process: HelperProcess
        do {
            process = try HelperProcess.start(helper)
        } catch {
            return outcome(.helperFailed("The script runner could not start: \(error.localizedDescription)"))
        }
        defer { process.kill() }

        let toolList: [JSONValue] = tools.map { tool in
            .object([
                "name": .string(tool.name),
                "jsName": .string(tool.jsName),
                "description": .string(tool.description),
                "parameters": .string(tool.parameters.encodedString()),
            ])
        }
        process.send(.object(["type": "start", "code": .string(code), "tools": .array(toolList)]))

        let timedOut = Flag()
        let watchdog = Task {
            while !Task.isCancelled {
                // Read the time before the paused total. A wait still going counts up to when
                // the total is read, so read in this order the limit can never pass during one.
                let now = ContinuousClock.now
                let deadline = started + timeout + paused()
                if now >= deadline {
                    timedOut.set()
                    process.kill()
                    return
                }
                try? await Task.sleep(until: min(deadline, .now + .milliseconds(250)))
            }
        }
        defer { watchdog.cancel() }

        var output: [String] = []
        var calls = 0
        let end: Outcome.End? = await withTaskCancellationHandler {
            for await message in process.messages {
                switch message["type"]?.stringValue {
                case "output":
                    output.append(message["text"]?.stringValue ?? "")
                case "call":
                    guard let id = message["id"]?.numberValue.flatMap(Int.init(exactly:)) else { continue }
                    calls += 1
                    let result = await callTool(message["tool"]?.stringValue ?? "", message["arguments"]?.stringValue ?? "{}")
                    if Task.isCancelled { return nil }
                    process.send(.object([
                        "type": "result", "id": .number(Double(id)), "ok": .bool(result.ok), "value": .string(result.value),
                    ]))
                case "done":
                    if message["ok"]?.boolValue == true {
                        return .completed(value: message["value"]?.stringValue)
                    }
                    let error = message["error"]
                    return .failed(
                        message: error?["message"]?.stringValue ?? "The script failed.", line: error?["line"]?.numberValue.flatMap(Int.init(exactly:)))
                default:
                    continue
                }
            }
            return nil
        } onCancel: {
            process.kill()
        }

        if Task.isCancelled { return outcome(.stopped, output: output, calls: calls) }
        if timedOut.isSet { return outcome(.timedOut, output: output, calls: calls) }
        return outcome(end ?? .helperFailed("The script runner ended without finishing the script."), output: output, calls: calls)
    }
}

/// A flag set once, from any thread.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// The helper process, with a pipe each way.
private final class HelperProcess: @unchecked Sendable {
    private let process: Process
    private let input: FileHandle
    let messages: AsyncStream<JSONValue>

    private init(process: Process, input: FileHandle, messages: AsyncStream<JSONValue>) {
        self.process = process
        self.input = input
        self.messages = messages
    }

    static func start(_ helper: URL) throws -> HelperProcess {
        let process = Process()
        process.executableURL = helper
        // Nothing from the app's environment, such as tokens in it, reaches the helper.
        process.environment = [:]
        let toHelper = Pipe()
        let fromHelper = Pipe()
        process.standardInput = toHelper
        process.standardOutput = fromHelper
        process.standardError = FileHandle.nullDevice

        let (stream, continuation) = AsyncStream<JSONValue>.makeStream()
        let reader = LineReader()
        fromHelper.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            for line in reader.append(data) {
                if let message = JSONValue.parse(line) { continuation.yield(message) }
            }
        }
        process.terminationHandler = { _ in
            // Whatever is still in the pipe has been read by now or is lost with the helper.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { continuation.finish() }
        }
        try process.run()
        return HelperProcess(process: process, input: toHelper.fileHandleForWriting, messages: stream)
    }

    private let writeLock = NSLock()

    func send(_ message: JSONValue) {
        writeLock.withLock {
            guard process.isRunning else { return }
            try? input.write(contentsOf: Data((message.encodedString() + "\n").utf8))
        }
    }

    /// Ends the helper at once. It holds nothing that needs saving.
    func kill() {
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        try? input.close()
    }
}

/// Splits what arrives on a pipe into lines.
private final class LineReader: @unchecked Sendable {
    private var buffer = Data()

    func append(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        return lines
    }
}
