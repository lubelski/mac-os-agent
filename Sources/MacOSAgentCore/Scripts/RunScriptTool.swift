import Foundation

/// `run_script`: the model writes JavaScript that calls the agent's other tools, and only what
/// the script outputs reaches the model. A script can chain calls, such as looking something
/// up and then acting on it, and cut a long result down, in one step.
///
/// It is the scripts experiment, in the tool list only when that switch was on at launch. It
/// goes last, after the MCP tools, so every other tool keeps its place.
///
/// The script never asks for a go-ahead of its own. Each call it makes runs through the called
/// tool's own `run`, with the same `confirm`, so it asks exactly when a direct call would.
public struct RunScriptTool: AgentTool {
    public static let name = "run_script"

    /// The time limit when the script does not set one.
    public static let defaultTimeout: Duration = .seconds(60)
    /// The longest time limit a script can set.
    public static let longestTimeout: Duration = .seconds(600)
    /// The most output passed back to the model, as for a shell command. Longer output keeps
    /// its start and end.
    public static let outputLimit = 16_000

    /// The tools a script can call: every tool in the run's list but this one.
    public let tools: [any AgentTool]
    /// The helper that runs scripts. Nil when it is missing, and every call then says so.
    public let helper: URL?

    public init(tools: [any AgentTool], helper: URL? = ScriptRunner.bundledHelper) {
        self.tools = tools.filter { $0.definition.name != Self.name }
        self.helper = helper
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: Self.name,
            description: """
                Run a short JavaScript script that calls your other tools, and get back only what \
                it outputs. Use it to chain several calls, to act on one call's result with \
                another, or to cut a long result down to what matters, instead of writing a \
                program in the shell.

                The script is the body of an async function, so top-level await and return work. \
                Every other tool you have is `await tools.<name>(args)`, taking the same \
                arguments object you would pass it directly, with hyphens in a name made \
                underscores. A call resolves to the text the tool returns, and rejects with an \
                Error when the tool returns an error or the person declines its go-ahead. \
                Calls run one at a time. Each one asks the person for a go-ahead exactly when \
                calling the tool directly would. Calls already made are not undone when a \
                later step fails.

                Output with text(value) and console.log(...). A returned value is added after \
                them, as JSON unless it is a string. ALL_TOOLS lists every tool's name and \
                description, and describeTool(name) gives one tool's parameters.

                There is nothing else: no files, network, timers, fetch, require, or modules. \
                Reach the Mac only through the tools. The script is stopped after \
                \(Int(Self.defaultTimeout.components.seconds)) seconds, not counting time waiting \
                for a go-ahead. A first line `// @options: {"timeout_ms": 120000}` sets up to \
                \(Int(Self.longestTimeout.components.seconds)) seconds.
                """,
            parameters: [
                "type": "object",
                "properties": [
                    "code": [
                        "type": "string",
                        "description": "The JavaScript, as plain source: not JSON and not in a Markdown code fence.",
                    ],
                ],
                "required": ["code"],
                "additionalProperties": false,
            ]
        )
    }

    /// Its own group in Settings, Tools.
    public static let scripts = ToolSource(id: "scripts", title: "Scripts")
    public var source: ToolSource { Self.scripts }

    public var goAhead: ToolGoAhead {
        .sometimes("Never asks for the script itself. Each tool the script calls asks exactly when a direct call to it would.")
    }

    /// The name its rows show, before the script's first line.
    public static let displayName = "Script"

    /// `Script` and the script's first line of code, such as `Script const events = await …`.
    public func summary(arguments: JSONValue) -> String {
        guard let code = arguments["code"]?.stringValue else { return Self.displayName }
        let firstLine = code.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("// @options:") }
        return firstLine.map { "\(Self.displayName) \($0)" } ?? Self.displayName
    }

    public func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        guard let code = arguments["code"]?.stringValue,
              !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return "Error: the call did not include a script."
        }
        guard let helper, FileManager.default.isExecutableFile(atPath: helper.path) else {
            return "Error: the script runner is missing from the app, so scripts cannot run."
        }
        let timeout: Duration
        switch Self.timeout(in: code) {
        case .success(let value): timeout = value
        case .failure(let problem): return "Error: \(problem.message)"
        }

        let waiting = WaitedTime()
        let tools = Dictionary(self.tools.map { ($0.definition.name, $0) }, uniquingKeysWith: { first, _ in first })
        let outcome = await ScriptRunner.run(
            code: code,
            tools: self.tools.map {
                ScriptRunner.Tool(name: $0.definition.name, description: $0.definition.description, parameters: $0.definition.parameters)
            },
            helper: helper,
            timeout: timeout,
            paused: { waiting.total }
        ) { name, argumentsText in
            await Self.call(tools[name], named: name, arguments: argumentsText, context: context, waiting: waiting)
        }
        context.report.note { details in
            if outcome.end == .timedOut { details.timedOut = true }
            if outcome.end == .stopped { details.stopped = true }
        }
        return Self.result(of: outcome, timeout: timeout)
    }

    /// Runs one call the script made, as the loop runs a direct call: through the tool's own
    /// `run`, asking with the script call's `confirm`.
    static func call(
        _ tool: (any AgentTool)?, named name: String, arguments text: String, context: ToolRunContext, waiting: WaitedTime
    ) async -> (ok: Bool, value: String) {
        guard let tool else { return (false, "There is no tool named \(name).") }
        guard let arguments = JSONValue.parse(text), case .object = arguments else {
            return (false, "The arguments to \(name) were not a JSON object.")
        }
        let declined = Flag()
        let nested = ToolRunContext(
            callID: context.callID, episodeID: context.episodeID, report: ToolRunReport()
        ) { request in
            var request = request
            request.fromScript = true
            waiting.begin()
            let approved = await context.confirm(request)
            waiting.end()
            if !approved, !Task.isCancelled { declined.set() }
            return approved
        }
        let output = await tool.run(arguments: arguments, context: nested)
        if declined.isSet { return (false, output) }
        // The app's tools and MCP results report failure as text that starts this way.
        // The script's Error carries the rest, since its message is shown as "Error: …".
        if output.hasPrefix("Error:") {
            return (false, String(output.dropFirst("Error:".count)).trimmingCharacters(in: .whitespaces))
        }
        return (true, output)
    }

    struct OptionsProblem: Error, Equatable {
        var message: String
    }

    /// The time limit the script's first line sets with `// @options: {"timeout_ms": …}`, or
    /// the default.
    static func timeout(in code: String) -> Result<Duration, OptionsProblem> {
        let firstLine = code.prefix { $0 != "\n" }.trimmingCharacters(in: .whitespaces)
        let marker = "// @options:"
        guard firstLine.hasPrefix(marker) else { return .success(defaultTimeout) }
        guard let options = JSONValue.parse(String(firstLine.dropFirst(marker.count))), case .object(let fields) = options else {
            return .failure(OptionsProblem(message: "the @options line is not a JSON object."))
        }
        if let unknown = fields.keys.sorted().first(where: { $0 != "timeout_ms" }) {
            return .failure(OptionsProblem(message: "the @options line has \"\(unknown)\", and only timeout_ms is known."))
        }
        guard let milliseconds = fields["timeout_ms"]?.numberValue else { return .success(defaultTimeout) }
        guard milliseconds > 0 else { return .failure(OptionsProblem(message: "timeout_ms must be more than 0.")) }
        return .success(min(.milliseconds(Int64(milliseconds)), longestTimeout))
    }

    /// What the model reads: how the script ended, its output, and its value or error.
    static func result(of outcome: ScriptRunner.Outcome, timeout: Duration) -> String {
        let time = "\(formatted(outcome.seconds)) seconds"
        var lines: [String] = []
        var failed = true
        switch outcome.end {
        case .completed:
            lines.append("Script completed in \(time).")
            failed = false
        case .failed:
            lines.append("Script failed after \(time).")
        case .timedOut:
            let limit = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            lines.append("Script stopped at its \(formatted((limit * 10).rounded() / 10)) second limit.")
        case .stopped:
            lines.append("The task was stopped while this script ran.")
        case .helperFailed(let message):
            lines.append("Error: \(message)")
        }
        lines += outcome.output
        switch outcome.end {
        case .completed(let value?):
            lines.append(value)
        case .failed(let message, let line):
            lines.append("Script error: \(message)" + (line.map { " (line \($0))" } ?? ""))
        default:
            break
        }
        if failed, outcome.calls > 0 {
            lines.append("[\(outcome.calls == 1 ? "The 1 tool call" : "The \(outcome.calls) tool calls") it made before ending were not undone.]")
        }
        if lines.count == 1, !failed { lines.append("(no output)") }
        return ShellCommandTool.limit(lines.joined(separator: "\n"), to: outputLimit)
    }

    private static func formatted(_ seconds: Double) -> String {
        seconds.rounded() == seconds ? String(Int(seconds)) : String(format: "%.1f", seconds)
    }
}

/// Time a script spent waiting for the owner, which its time limit leaves out. A wait still
/// going counts up to now, so a long wait for a go-ahead never runs the script out of time.
final class WaitedTime: @unchecked Sendable {
    private let lock = NSLock()
    private var finished: Duration = .zero
    private var since: ContinuousClock.Instant?

    func begin() { lock.withLock { since = .now } }

    func end() {
        lock.withLock {
            if let since { finished += ContinuousClock.now - since }
            since = nil
        }
    }

    var total: Duration {
        lock.withLock { finished + (since.map { ContinuousClock.now - $0 } ?? .zero) }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
