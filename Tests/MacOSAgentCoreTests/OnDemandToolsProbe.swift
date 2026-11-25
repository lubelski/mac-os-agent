import Foundation
import Testing
@testable import MacOSAgentCore

/// A probe for MAC-2: does the model find and call tools as well when they sit in groups behind
/// `find_tools` / `use_tool` as when they are in the tool list?
///
/// It sends real requests to the model the app uses, with the owner's ChatGPT sign-in from the
/// Keychain, so it runs only when asked:
///
/// ```
/// MAC_OS_AGENT_TOOL_PROBE=1 swift test --filter OnDemandToolsProbe
/// ```
///
/// Every tool is a stand-in that records its call and returns made-up text. Nothing runs on the
/// Mac and nothing reaches Linear. The Linear tools are the real definitions from the app's MCP
/// tool cache. Results go to `MAC_OS_AGENT_PROBE_OUT`, one JSON line per run.
@Suite struct OnDemandToolsProbe {
    static let environment = ProcessInfo.processInfo.environment

    @Test(.enabled(if: environment["MAC_OS_AGENT_TOOL_PROBE"] == "1"))
    func probe() async throws {
        let model = Self.environment["MAC_OS_AGENT_PROBE_MODEL"] ?? "gpt-6.2-astra"
        let repetitions = Int(Self.environment["MAC_OS_AGENT_PROBE_REPS"] ?? "") ?? 2
        let output = URL(filePath: Self.environment["MAC_OS_AGENT_PROBE_OUT"] ?? NSTemporaryDirectory() + "tool-probe.jsonl")
        let only = Self.environment["MAC_OS_AGENT_PROBE_TASKS"].map { Set($0.split(separator: ",").map(String.init)) }

        let authenticator = ChatGPTAuthenticator(secrets: KeychainSecrets(), installationID: AgentPaths.installationID())
        let linear = MCPToolCache.read().servers["linear"]?.tools ?? []
        #expect(!linear.isEmpty, "The app's MCP tool cache has no Linear tools.")

        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }

        for task in ProbeTask.all where only?.contains(task.id) ?? true {
            for arm in Arm.allCases {
                for repetition in 1...repetitions {
                    let usage = UsageCounter()
                    let provider = CountingProvider(
                        inner: OpenAIResponsesProvider(
                            authenticator: authenticator, model: { model },
                            promptCacheKey: "mac-os-agent-tool-probe-\(UUID().uuidString.lowercased())"),
                        counter: usage)
                    let recorder = CallRecorder()
                    let tools = arm.tools(linear: linear, recorder: recorder)
                    let loop = AgentLoop(
                        provider: provider, thread: InMemoryThreadStore(), tools: tools,
                        instructions: arm.instructions, maximumModelReplies: 10)
                    let text = TextCollector()
                    var failure: String?
                    do {
                        try await loop.run(task.prompt, onEvent: { event in
                            if case .textDelta(let delta) = event { await text.add(delta) }
                        }, confirm: { _ in true })
                    } catch {
                        failure = "\(error)"
                    }
                    let calls = await recorder.calls
                    let reply = await text.text
                    let counts = await usage.snapshot
                    let result = RunResult(
                        task: task.id, arm: arm.rawValue, repetition: repetition, model: model,
                        passed: failure == nil && task.passes(calls),
                        usedShell: calls.contains { $0.tool == ShellCommandTool.name },
                        calls: calls, reply: reply, error: failure,
                        requests: counts.requests, inputTokens: counts.input, cachedInputTokens: counts.cached,
                        outputTokens: counts.output)
                    let line = try JSONEncoder().encode(result)
                    handle.write(line + Data("\n".utf8))
                    print("probe \(task.id) \(arm.rawValue) #\(repetition): \(result.passed ? "pass" : "FAIL") requests=\(counts.requests) input=\(counts.input) calls=\(calls.map(\.tool))")
                }
            }
        }
    }
}

// MARK: - Tasks

struct ProbeTask: Sendable {
    var id: String
    var prompt: String
    var passes: @Sendable ([RecordedCall]) -> Bool

    static func called(_ tool: String, _ calls: [RecordedCall], containing parts: [String] = []) -> Bool {
        calls.contains { call in
            call.tool == tool && parts.allSatisfy { call.arguments.localizedCaseInsensitiveContains($0) }
        }
    }

    static func noShell(_ calls: [RecordedCall]) -> Bool { !calls.contains { $0.tool == ShellCommandTool.name } }

    static let all: [ProbeTask] = [
        ProbeTask(id: "configured", prompt: "Do you have the linear MCP configured?") { calls in
            called("read_settings", calls, containing: ["mcp"]) && noShell(calls)
        },
        ProbeTask(id: "experiment", prompt: "Turn on the scripts experiment in MOA.") { calls in
            called("change_settings", calls, containing: ["scripts"]) && noShell(calls)
        },
        ProbeTask(id: "figma-http", prompt: "Configure the Figma MCP for MOA. Its endpoint is https://mcp.figma.com/mcp") { calls in
            // HTTP servers are not supported. Passing means no server was added, by any route.
            !called("change_settings", calls, containing: ["figma"]) && noShell(calls)
        },
        ProbeTask(id: "add-server", prompt: "Add the GitHub MCP server to your setup. The command is npx with the arguments -y @modelcontextprotocol/server-github.") { calls in
            called("change_settings", calls, containing: ["server-github"]) && noShell(calls)
        },
        ProbeTask(id: "linear-list", prompt: "Which Linear issues are assigned to me?") { calls in
            called("list_issues", calls, containing: ["me"])
        },
        ProbeTask(id: "linear-comment", prompt: "Leave a comment on MAC-13 in Linear saying I'll look at it Friday.") { calls in
            called("save_comment", calls, containing: ["MAC-13"])
        },
    ]
}

// MARK: - Arms

enum Arm: String, CaseIterable, Sendable {
    /// Settings and Linear tools in the tool list, as MCP tools are today.
    case listed
    /// Settings and Linear tools in groups, behind `find_tools` and `use_tool`.
    case grouped

    var instructions: String {
        let base = AgentInstructions.assemble(
            editable: AgentInstructions.defaultEditable, skills: [], skillsFolder: AgentPaths.skillsFolder)
        switch self {
        case .listed: return base
        case .grouped:
            return base + """


                More tools are kept in groups, out of your tool list. Call find_tools with a group's \
                name to see its tools, then use_tool to call one.
                Groups:
                - settings: this app's own setup (this app is MacOS Agent, also called MOA or \
                mac-os-agent): MCP servers and experiments.
                - linear: the Linear MCP server: issues, projects, comments, documents, cycles, \
                and teams in Linear.
                """
        }
    }

    func tools(linear: [MCPToolInfo], recorder: CallRecorder) -> [any AgentTool] {
        let builtIn: [any AgentTool] = ToolRegistry(builtIn: BuiltInTools.make()).tools.map {
            StandInTool(definition: $0.definition, recorder: recorder, reply: { _, _ in "Not available in this test." })
        }
        let settings = SettingsStandIns.definitions
        let linearDefinitions = linear.map {
            ToolDefinition(name: $0.name, description: $0.description, parameters: MCPTool.schema($0.inputSchema), strict: false)
        }
        switch self {
        case .listed:
            let settingsTools = settings.map { StandInTool(definition: $0, recorder: recorder, reply: SettingsStandIns.reply) }
            let linearTools = linearDefinitions.map { definition in
                var listed = definition
                listed.name = "linear__\(definition.name)"
                return StandInTool(definition: listed, recorder: recorder, recordAs: definition.name, reply: LinearStandIns.reply)
            }
            return builtIn + settingsTools + linearTools.sorted { $0.definition.name < $1.definition.name }
        case .grouped:
            let groups = ["settings": settings, "linear": linearDefinitions]
            return builtIn + [
                FindToolsTool(groups: groups, recorder: recorder),
                UseToolTool(groups: groups, recorder: recorder),
            ]
        }
    }
}

// MARK: - Stand-in tools

struct RecordedCall: Sendable, Codable {
    var tool: String
    var arguments: String
}

actor CallRecorder {
    var calls: [RecordedCall] = []
    func record(_ tool: String, _ arguments: JSONValue) { calls.append(RecordedCall(tool: tool, arguments: arguments.encodedString())) }
}

struct StandInTool: AgentTool {
    var definition: ToolDefinition
    var recorder: CallRecorder
    var recordAs: String?
    var reply: @Sendable (String, JSONValue) -> String

    func summary(arguments: JSONValue) -> String { definition.name }

    func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        let name = recordAs ?? definition.name
        await recorder.record(name, arguments)
        return reply(name, arguments)
    }
}

enum SettingsStandIns {
    static let areas: JSONValue = .object([
        "type": .string("string"), "enum": .array([.string("mcp_servers"), .string("experiments")]),
    ])

    static let definitions = [
        ToolDefinition(
            name: "read_settings",
            description: """
                Reads this app's own setup. This app is MacOS Agent, also called MOA or mac-os-agent. \
                mcp_servers: each server with whether it is saved, on, loaded in this run, connected, and \
                signed in, and which kinds of server are supported. experiments: each experiment and \
                whether it is on. The result also says what change_settings accepts for the area.
                """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object(["area": areas]),
                "required": .array([.string("area")]),
            ]),
            strict: false),
        ToolDefinition(
            name: "change_settings",
            description: """
                Changes this app's own setup and keeps everything else. mcp_servers: {"add": {"name", \
                "command", "args", "env_names"}}, {"remove": name}, {"turn_on": name}, or {"turn_off": \
                name}. Only servers the app starts with a command are supported. Remote HTTP servers are \
                not supported yet. experiments: {"experiment": key, "on": true or false}. The owner is asked \
                first. The result says when the change takes effect and what the owner still has to do.
                """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object(["area": areas, "change": .object(["type": .string("object")])]),
                "required": .array([.string("area"), .string("change")]),
            ]),
            strict: false),
    ]

    static let reply: @Sendable (String, JSONValue) -> String = { name, arguments in
        let area = arguments["area"]?.stringValue ?? ""
        if name == "read_settings" {
            if area == "experiments" {
                return """
                    {"experiments": [
                      {"key": "queueMessagesWhileRunning", "title": "Queue messages while a task runs", "on": false},
                      {"key": "suggestionsInFieldAndFooter", "title": "Suggestions in the field", "on": false},
                      {"key": "mcpServers", "title": "MCP servers", "on": true},
                      {"key": "panelWithBarsAndInputPill", "title": "Panel with bars", "on": true},
                      {"key": "scripts", "title": "Scripts that call tools", "on": false}],
                     "change": {"experiment": "<key>", "on": true}, "takes_effect": "mcpServers and scripts at the next launch, the others now"}
                    """
            }
            return """
                {"servers": [{"name": "linear", "command": "npx -y mcp-remote https://mcp.linear.app/sse", \
                "saved": true, "on": true, "loaded_in_this_run": true, "connected": true, "signed_in": true, "tools": 78}],
                 "supported": "Servers the app starts with a command (stdio). Remote HTTP servers are not supported yet; see MAC-2.",
                 "change": {"add": {"name": "<name>", "command": "<command>", "args": [], "env_names": []}},
                 "takes_effect": "next launch"}
                """
        }
        if arguments.encodedString().localizedCaseInsensitiveContains("http") && area == "mcp_servers"
            && !arguments.encodedString().contains("mcp-remote") && !arguments.encodedString().contains("npx") {
            return "Error: Remote HTTP servers are not supported yet. Only servers the app starts with a command."
        }
        return "Saved. The owner said yes. It takes effect at the next launch: the owner has to quit and open the app."
    }
}

enum LinearStandIns {
    static let reply: @Sendable (String, JSONValue) -> String = { name, _ in
        switch name {
        case "list_issues":
            return #"{"issues": [{"id": "MAC-13", "title": "Example issue one", "status": "Backlog"}, {"id": "MAC-18", "title": "Example issue two", "status": "In Progress"}]}"#
        case "save_comment":
            return #"{"id": "comment-1", "body": "saved"}"#
        default:
            return #"{"ok": true}"#
        }
    }
}

struct FindToolsTool: AgentTool {
    var groups: [String: [ToolDefinition]]
    var recorder: CallRecorder

    var definition: ToolDefinition {
        ToolDefinition(
            name: "find_tools",
            description: """
                Lists the tools in one of the groups named in your instructions. With a query, returns the \
                matching tools with their full descriptions and parameters, ready for use_tool. Without one, \
                returns every tool's name and first sentence.
                """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "group": .object(["type": .string("string")]),
                    "query": .object([
                        "type": .array([.string("string"), .string("null")]),
                        "description": .string("Words to match against tool names and descriptions, or null for the whole group."),
                    ]),
                ]),
                "required": .array([.string("group"), .string("query")]),
                "additionalProperties": .bool(false),
            ]))
    }

    func summary(arguments: JSONValue) -> String { "find_tools" }

    func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        await recorder.record("find_tools", arguments)
        let name = arguments["group"]?.stringValue ?? ""
        guard let tools = groups[name] else { return "Error: no group named \(name). Groups: \(groups.keys.sorted().joined(separator: ", "))." }
        let words = (arguments["query"]?.stringValue ?? "").lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if tools.count <= 4 || !words.isEmpty {
            let matches = tools.count <= 4 ? tools : tools.filter { tool in
                let text = (tool.name + " " + tool.description).lowercased()
                return words.contains { text.contains($0) }
            }
            if matches.isEmpty { return "No tools in \(name) match. Call find_tools with a null query to see them all." }
            return JSONValue.array(matches.prefix(8).map { tool in
                .object(["name": .string(tool.name), "description": .string(tool.description), "parameters": tool.parameters])
            }).encodedString()
        }
        return tools.map { "\($0.name): \(Self.firstSentence($0.description))" }.joined(separator: "\n")
    }

    static func firstSentence(_ text: String) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        if let end = line.range(of: ". ") { return String(line[..<end.lowerBound]) + "." }
        return String(line.prefix(160))
    }
}

struct UseToolTool: AgentTool {
    var groups: [String: [ToolDefinition]]
    var recorder: CallRecorder

    var definition: ToolDefinition {
        ToolDefinition(
            name: "use_tool",
            description: "Calls a tool from a group, by the name find_tools gave, with arguments that match its parameters.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "group": .object(["type": .string("string")]),
                    "name": .object(["type": .string("string")]),
                    "arguments": .object(["type": .string("object")]),
                ]),
                "required": .array([.string("group"), .string("name"), .string("arguments")]),
            ]),
            strict: false)
    }

    func summary(arguments: JSONValue) -> String { "use_tool" }

    func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        let group = arguments["group"]?.stringValue ?? ""
        let name = arguments["name"]?.stringValue ?? ""
        let inner = arguments["arguments"] ?? .object([:])
        guard let tools = groups[group] else { return "Error: no group named \(group)." }
        guard tools.contains(where: { $0.name == name }) else { return "Error: \(group) has no tool named \(name). Call find_tools first." }
        await recorder.record(name, inner)
        return group == "settings" ? SettingsStandIns.reply(name, inner) : LinearStandIns.reply(name, inner)
    }
}

// MARK: - Counting

struct RunResult: Codable {
    var task: String
    var arm: String
    var repetition: Int
    var model: String
    var passed: Bool
    var usedShell: Bool
    var calls: [RecordedCall]
    var reply: String
    var error: String?
    var requests: Int
    var inputTokens: Int
    var cachedInputTokens: Int
    var outputTokens: Int
}

actor UsageCounter {
    var requests = 0, input = 0, cached = 0, output = 0
    func add(_ usage: TokenUsage) {
        requests += 1
        input += usage.inputTokens
        cached += usage.cachedInputTokens
        output += usage.outputTokens
    }
    var snapshot: (requests: Int, input: Int, cached: Int, output: Int) { (requests, input, cached, output) }
}

actor TextCollector {
    var text = ""
    func add(_ delta: String) { text += delta }
}

struct CountingProvider: ModelProvider {
    var inner: any ModelProvider
    var counter: UsageCounter

    func streamReply(to request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        let upstream = inner.streamReply(to: request)
        let counter = counter
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in upstream {
                        if case .usage(let usage, _, _) = event { await counter.add(usage) }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
