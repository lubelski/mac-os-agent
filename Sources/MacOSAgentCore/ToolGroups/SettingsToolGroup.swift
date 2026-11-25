import Foundation

/// The settings group: `read_settings` and `change_settings`, which read and change the app's
/// own setup. It is the settings tools experiment, behind `find_tools` and `use_tool`.
///
/// Two areas are covered, each described once in `SettingsArea`: the MCP servers and the
/// experiments. What `read_settings` reports, what `change_settings` accepts, and when a
/// change takes effect all come from there, so the docs the model reads come from the code.
public enum SettingsToolGroup {
    public static let name = "settings"

    public static let summary = """
        MOA's own setup: its MCP servers (saved, on, loaded in this run, connected) and its \
        experiments. Read them with read_settings before answering about them. Every change \
        asks the owner first.
        """

    /// The group as the instructions list it.
    public static let listing = AgentInstructions.ToolGroupSummary(name: name, summary: summary)

    public static func make(access: AppSettingsAccess) -> OnDemandToolGroup {
        OnDemandToolGroup(name: name, summary: summary, tools: [
            ReadSettingsTool(access: access),
            ChangeSettingsTool(access: access),
        ])
    }
}

/// What the settings tools read and change. The app gives them the real files, the run's MCP
/// servers, and its preferences. Tests give them temporary ones.
public struct AppSettingsAccess: @unchecked Sendable {
    /// `mcp-servers.json`, read fresh at each call, so a tool reports what is saved now.
    public var serversFile: URL
    /// This run's servers: their live state, and turning one on or off, which its
    /// `MCPSettingsStore` keeps.
    public var mcp: MCPServerPool
    /// The number of tools each server has in this run's tool list, by server. A server
    /// missing here is not loaded in this run.
    public var toolsInThisRun: [String: Int]
    /// Where the experiments' switches are kept. `UserDefaults` is safe to use from any thread.
    public var defaults: UserDefaults
    /// The experiments that were on when the app launched, for those read only at launch.
    public var experimentsOnAtLaunch: Set<Experiment>

    public init(
        serversFile: URL = AgentPaths.mcpServersFile, mcp: MCPServerPool, toolsInThisRun: [String: Int],
        defaults: UserDefaults = .standard, experimentsOnAtLaunch: Set<Experiment>
    ) {
        self.serversFile = serversFile
        self.mcp = mcp
        self.toolsInThisRun = toolsInThisRun
        self.defaults = defaults
        self.experimentsOnAtLaunch = experimentsOnAtLaunch
    }
}

extension AppSettingsAccess {
    /// Access to nothing real, for tools that only give their rows' summaries, which read
    /// nothing but the arguments. Their `run` is never called.
    static var summariesOnly: AppSettingsAccess {
        AppSettingsAccess(
            serversFile: FileManager.default.temporaryDirectory.appending(path: "mac-os-agent-no-mcp-servers.json"),
            mcp: .empty, toolsInThisRun: [:], experimentsOnAtLaunch: [])
    }
}

// MARK: - The areas

/// One area of the app's setup, described once: what it holds, where it is kept, what
/// `change_settings` accepts, and when a change takes effect.
public enum SettingsArea: String, CaseIterable, Sendable {
    case mcpServers = "mcp_servers"
    case experiments

    public var holds: String {
        switch self {
        case .mcpServers:
            "The MCP servers MOA starts, whose tools the agent gets: each one's command, the names of its environment variables, whether it is on, and how it is doing in this run."
        case .experiments:
            "Features being tried, each a switch that is off until the owner turns it on."
        }
    }

    public var keptIn: String {
        switch self {
        case .mcpServers:
            "mcp-servers.json in the app's data folder holds the servers, in the mcpServers shape other apps use. mcp-settings.json beside it holds which are off. Settings, MCP Servers shows them and opens the file."
        case .experiments:
            "The app's preferences. Settings, Experiments has a switch for each."
        }
    }

    /// What `change_settings` takes for the area, one shape per line.
    public var accepts: [String] {
        switch self {
        case .mcpServers:
            [
                #"{"add": {"name": "<name>", "command": "<command>", "args": ["<arg>", …], "env_names": ["<NAME>", …]}}"#,
                #"{"remove": "<name>"}"#,
                #"{"turn_on": "<name>"}"#,
                #"{"turn_off": "<name>"}"#,
            ]
        case .experiments:
            [#"{"experiment": "<key>", "on": true or false}"#]
        }
    }

    /// Rules for a change, beyond its shape.
    public var changeRules: [String] {
        switch self {
        case .mcpServers:
            [
                "A name is 1 to \(MCPServerConfig.nameLimit) letters, digits, hyphens, and single underscores, and is not already taken. To change a server, remove it and add it again.",
                "env_names are only the names of environment variables. Their values are never taken from you or shown to you: the owner fills them in mcp-servers.json.",
                "Supported: servers MOA starts with a command. A remote HTTP server is reached through the mcp-remote bridge: command npx, args [\"-y\", \"mcp-remote\", \"<url>\"]. The go-ahead card tells the owner it is a bridge.",
            ]
        case .experiments:
            ["The key is one of the experiments' keys, as read_settings lists them."]
        }
    }

    public var takesEffect: String {
        switch self {
        case .mcpServers:
            "The tool list is built at launch, so a server added, removed, turned on, or turned off joins or leaves it at the next launch: the owner quits MOA and opens it again. Turning a server on or off also starts or stops it now."
        case .experiments:
            "Each experiment says when a change to it takes effect."
        }
    }

    /// The description as `read_settings` returns it.
    var description: [String: JSONValue] {
        [
            "holds": .string(holds),
            "kept_in": .string(keptIn),
            "takes_effect": .string(takesEffect),
            "change_settings_accepts": .array(accepts.map(JSONValue.string)),
            "change_rules": .array(changeRules.map(JSONValue.string)),
        ]
    }

    static var parameter: JSONValue {
        ["type": "string", "enum": .array(allCases.map { .string($0.rawValue) })]
    }

    var title: String {
        switch self {
        case .mcpServers: "MCP servers"
        case .experiments: "experiments"
        }
    }
}

// MARK: - read_settings

/// `read_settings`: the app's setup as it really is, in layers: what is saved, what is on, and
/// what this run loaded and is doing. It never returns an environment variable's value.
public struct ReadSettingsTool: AgentTool {
    public static let name = "read_settings"

    public let access: AppSettingsAccess

    public init(access: AppSettingsAccess) {
        self.access = access
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: Self.name,
            description: """
                Reads MOA's own setup, for one area. mcp_servers: each server with whether it is saved, \
                on, loaded in this run, and connected or failed and why, its command, the names of its \
                environment variables, and whether it is a bridge to a remote server, and which kinds \
                of server are supported. experiments: each experiment's key, title, whether it is on, \
                and when a change takes effect. The result also says what change_settings accepts for \
                the area.
                """,
            parameters: [
                "type": "object",
                "properties": ["area": SettingsArea.parameter],
                "required": ["area"],
                "additionalProperties": false,
            ])
    }

    public func summary(arguments: JSONValue) -> String {
        guard let area = arguments["area"]?.stringValue.flatMap(SettingsArea.init) else { return "Settings read" }
        return "Settings read \(area.title)"
    }

    public func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        guard let area = arguments["area"]?.stringValue.flatMap(SettingsArea.init) else {
            return "Error: area must be one of \(SettingsArea.allCases.map(\.rawValue).joined(separator: ", "))."
        }
        var result = area.description
        result["area"] = .string(area.rawValue)
        switch area {
        case .mcpServers: result.merge(await mcpServers(), uniquingKeysWith: { _, new in new })
        case .experiments: result["experiments"] = experiments()
        }
        return JSONValue.object(result).prettyEncodedString()
    }

    func experiments() -> JSONValue {
        .array(Experiment.allCases.map { experiment in
            var item: [String: JSONValue] = [
                "key": .string(experiment.rawValue),
                "title": .string(experiment.title),
                "on": .bool(experiment.isOn(access.defaults)),
                "takes_effect": .string(experiment.whenAChangeTakesEffect),
            ]
            if experiment.isReadAtLaunch {
                item["on_at_launch"] = .bool(access.experimentsOnAtLaunch.contains(experiment))
            }
            return .object(item)
        })
    }

    func mcpServers() async -> [String: JSONValue] {
        let saved = MCPServerConfig.read(from: access.serversFile)
        let live = await access.mcp.statuses()
        let poolActive = await access.mcp.isActive
        let experimentOn = Experiment.mcpServers.isOn(access.defaults)
        var servers: [JSONValue] = []
        for entry in saved.servers {
            servers.append(.object(describe(entry, saved: true, live: live.first { $0.entry.name == entry.name }, poolActive: poolActive)))
        }
        // A server this run started that has since left the file.
        for status in live where !saved.servers.contains(where: { $0.name == status.entry.name }) {
            servers.append(.object(describe(status.entry, saved: false, live: status, poolActive: poolActive)))
        }
        var result: [String: JSONValue] = [
            "mcp_servers_experiment": [
                "on": .bool(experimentOn),
                "on_at_launch": .bool(access.experimentsOnAtLaunch.contains(.mcpServers)),
                "note": .string(experimentOn
                    ? "MCP servers are on. With the experiment off, no server starts and no MCP tool is in the list."
                    : "The MCP servers experiment is off, so no server starts and no MCP tool is in the tool list. Turn it on with change_settings in the experiments area."),
            ],
            "servers": .array(servers),
        ]
        if !saved.fileExists { result["file"] = "mcp-servers.json does not exist yet. Adding a server creates it." }
        if let problem = saved.fileProblem { result["file_problem"] = .string(problem) }
        return result
    }

    func describe(_ entry: MCPServerEntry, saved: Bool, live: MCPServerStatus?, poolActive: Bool) -> [String: JSONValue] {
        var item: [String: JSONValue] = [
            "name": .string(entry.name),
            "saved": .bool(saved),
            "on": .bool(access.mcp.settings.isEnabled(entry.name)),
            "command": .string(MCPCommandDisplay.line(entry)),
            "env_names": .array(entry.env.keys.sorted().map(JSONValue.string)),
            "loaded_in_this_run": .bool(access.toolsInThisRun[entry.name] != nil),
            "tools_in_this_run": .number(Double(access.toolsInThisRun[entry.name] ?? 0)),
            "status": .string(Self.status(entry: entry, live: live, poolActive: poolActive, on: access.mcp.settings.isEnabled(entry.name))),
        ]
        if let problem = entry.problem { item["problem"] = .string(problem) }
        if let live, let tools = live.liveTools { item["tools_now"] = .number(Double(tools.count)) }
        if let bridge = MCPRemoteBridge(entry) {
            item["bridge"] = [
                "remote_url": .string(MCPCommandDisplay.hidingSecrets(inURL: bridge.url)),
                "through": .string(bridge.runDescription),
            ]
        }
        return item
    }

    /// How the server is doing in this run, in a few words.
    static func status(entry: MCPServerEntry, live: MCPServerStatus?, poolActive: Bool, on: Bool) -> String {
        if let problem = entry.problem { return "not valid: \(problem)" }
        guard poolActive else { return "not started: the MCP servers experiment is off" }
        guard let live else { return "not started in this run: it was added after launch, and starts at the next launch" }
        switch live.state {
        case .off: return "off"
        case .starting: return "starting"
        case .connected: return "connected"
        case .failed(let message): return "failed: \(message)"
        case .invalid(let problem): return "not valid when the app launched: \(problem)"
        }
    }
}

// MARK: - change_settings

/// `change_settings`: changes one thing in the app's setup and keeps everything else. Every
/// change waits for the owner's go-ahead. An MCP server change always asks, since a server is a
/// program MOA starts, and no setting turns that off.
public struct ChangeSettingsTool: AgentTool {
    public static let name = "change_settings"

    public let access: AppSettingsAccess

    public init(access: AppSettingsAccess) {
        self.access = access
    }

    public var definition: ToolDefinition {
        let shapes = SettingsArea.allCases.map { area in
            "\(area.rawValue): " + area.accepts.joined(separator: ", or ")
        }.joined(separator: "\n")
        return ToolDefinition(
            name: Self.name,
            description: """
                Changes one thing in MOA's own setup and keeps everything else. The owner is asked \
                first. The result says what changed, when it takes effect, and what the owner still \
                has to do. Call read_settings first for the area's rules. The change for each area:
                \(shapes)
                """,
            parameters: [
                "type": "object",
                "properties": [
                    "area": SettingsArea.parameter,
                    "change": ["type": "object", "description": "One change, in the shape for the area."],
                ],
                "required": ["area", "change"],
            ],
            strict: false)
    }

    public var goAhead: ToolGoAhead { .always }

    public func summary(arguments: JSONValue) -> String {
        let change = arguments["change"] ?? .null
        switch arguments["area"]?.stringValue.flatMap(SettingsArea.init) {
        case .mcpServers:
            if let name = change["add"]?["name"]?.stringValue { return "Settings add the MCP server \(name)" }
            if let name = change["remove"]?.stringValue { return "Settings remove the MCP server \(name)" }
            if let name = change["turn_on"]?.stringValue { return "Settings turn on the MCP server \(name)" }
            if let name = change["turn_off"]?.stringValue { return "Settings turn off the MCP server \(name)" }
            return "Settings MCP servers"
        case .experiments:
            guard let key = change["experiment"]?.stringValue else { return "Settings experiments" }
            let on = change["on"]?.boolValue
            return "Settings turn \(on == false ? "off" : "on") the experiment \(Experiment(rawValue: key)?.title ?? key)"
        case nil:
            return "Settings"
        }
    }

    public static let declinedOutput = "Error: the owner declined this change. Nothing was changed."

    public func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        guard let area = arguments["area"]?.stringValue.flatMap(SettingsArea.init) else {
            return "Error: area must be one of \(SettingsArea.allCases.map(\.rawValue).joined(separator: ", "))."
        }
        guard let change = arguments["change"], case .object(let fields) = change else {
            return "Error: change must be an object. For \(area.rawValue): \(area.accepts.joined(separator: ", or "))."
        }
        switch area {
        case .mcpServers: return await changeServers(fields, context: context)
        case .experiments: return await changeExperiment(fields, context: context)
        }
    }

    // MARK: Experiments

    func changeExperiment(_ fields: [String: JSONValue], context: ToolRunContext) async -> String {
        let keys = Experiment.allCases.map(\.rawValue).joined(separator: ", ")
        guard let key = fields["experiment"]?.stringValue, let on = fields["on"]?.boolValue else {
            return "Error: the change should be \(SettingsArea.experiments.accepts[0]). The keys are: \(keys)."
        }
        guard let experiment = Experiment(rawValue: key) else {
            return "Error: there is no experiment with the key \"\(key)\". The keys are: \(keys)."
        }
        let word = on ? "on" : "off"
        if experiment.isOn(access.defaults) == on {
            return "The experiment \(experiment.title) (\(key)) is already \(word). Nothing was changed."
        }
        let request = ConfirmationRequest(
            callID: context.callID, kind: .settingsChange,
            body: .setting(
                change: "Turn \(word) the experiment “\(experiment.title)”",
                notes: ["Takes effect: \(experiment.whenAChangeTakesEffect)"]),
            reason: "changes how MOA works")
        guard await context.confirm(request) else { return Self.declinedOutput }
        experiment.set(on, access.defaults)
        var lines = ["Turned \(word) the experiment \(experiment.title) (\(key)). The owner said yes."]
        lines.append("Takes effect: \(experiment.whenAChangeTakesEffect)")
        if experiment.isReadAtLaunch { lines.append("The owner has to quit MOA and open it again for all of it to apply.") }
        return lines.joined(separator: "\n")
    }

    // MARK: MCP servers

    func changeServers(_ fields: [String: JSONValue], context: ToolRunContext) async -> String {
        let actions = ["add", "remove", "turn_on", "turn_off"].filter { fields[$0] != nil }
        guard actions.count == 1, fields.count == 1 else {
            return "Error: the change should have exactly one of add, remove, turn_on, or turn_off: "
                + SettingsArea.mcpServers.accepts.joined(separator: ", or ") + "."
        }
        let value = fields[actions[0]] ?? .null
        switch actions[0] {
        case "add": return await add(value, context: context)
        case "remove": return await remove(value, context: context)
        case "turn_on": return await turn(true, value, context: context)
        default: return await turn(false, value, context: context)
        }
    }

    /// A new server as the file will hold it, or why it cannot be added.
    func newServer(_ value: JSONValue) -> Result<MCPServerFile.NewServer, ChangeProblem> {
        guard case .object(let fields) = value else {
            return .failure(ChangeProblem("add should be an object: \(SettingsArea.mcpServers.accepts[0])."))
        }
        if fields["env"] != nil {
            return .failure(ChangeProblem("environment values are never taken from the agent. Pass env_names, the names only, and the owner fills in the values."))
        }
        let known: Set = ["name", "command", "args", "env_names"]
        if let unknown = fields.keys.sorted().first(where: { !known.contains($0) }) {
            if unknown == "url" || unknown == "serverUrl" {
                return .failure(ChangeProblem(Self.remoteAdvice))
            }
            return .failure(ChangeProblem("add has \"\(unknown)\", and only name, command, args, and env_names are known."))
        }
        guard let name = fields["name"]?.stringValue else { return .failure(ChangeProblem("add needs a name.")) }
        if let problem = MCPServerConfig.problem(withName: name) { return .failure(ChangeProblem(problem)) }
        guard let command = fields["command"]?.stringValue?.trimmingCharacters(in: .whitespaces), !command.isEmpty else {
            return .failure(ChangeProblem("add needs a command, the program MOA starts."))
        }
        if command.hasPrefix("http://") || command.hasPrefix("https://") { return .failure(ChangeProblem(Self.remoteAdvice)) }
        var args: [String] = []
        if let raw = fields["args"], raw != .null {
            guard let list = raw.arrayValue, list.allSatisfy({ $0.stringValue != nil }) else {
                return .failure(ChangeProblem("args should be a list of strings."))
            }
            args = list.compactMap(\.stringValue)
        }
        var envNames: [String] = []
        if let raw = fields["env_names"], raw != .null {
            guard let list = raw.arrayValue, list.allSatisfy({ $0.stringValue != nil }) else {
                return .failure(ChangeProblem("env_names should be a list of strings."))
            }
            envNames = list.compactMap(\.stringValue)
            if let bad = envNames.first(where: { !Self.isEnvironmentName($0) }) {
                return .failure(ChangeProblem("\"\(bad)\" is not an environment variable name. A name is letters, digits, and underscores, and does not start with a digit."))
            }
        }
        let server = MCPServerFile.NewServer(name: name, command: command, args: args, envNames: envNames)
        // The same check reading the file at launch makes.
        if let problem = MCPServerConfig.entry(named: name, server.value).problem { return .failure(ChangeProblem(problem)) }
        return .success(server)
    }

    static let remoteAdvice = """
        MOA does not reach remote HTTP servers itself yet. It reaches one through the mcp-remote bridge: \
        add it with command "npx" and args ["-y", "mcp-remote", "<url>"]. The owner is told it is a bridge.
        """

    static func isEnvironmentName(_ name: String) -> Bool {
        guard let first = name.first, !first.isNumber else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    func add(_ value: JSONValue, context: ToolRunContext) async -> String {
        let server: MCPServerFile.NewServer
        switch newServer(value) {
        case .success(let made): server = made
        case .failure(let problem): return "Error: \(problem.message)"
        }
        let file = MCPServerFile(url: access.serversFile)
        // Checked before asking, so the owner is not asked about a change that cannot be made.
        if case .failure(let problem) = file.adding(server) { return "Error: \(problem.message)" }

        let entry = MCPServerEntry(name: server.name, command: server.command, args: server.args)
        let bridge = MCPRemoteBridge(entry)
        var notes = ["Command: \(MCPCommandDisplay.line(entry))"]
        if let bridge { notes.append(bridge.cardSentence(server: server.name)) }
        if !server.envNames.isEmpty {
            notes.append("Needs values you fill in: \(server.envNames.joined(separator: ", ")).")
        }
        notes.append("Its tools join at the next launch.")
        let request = ConfirmationRequest(
            callID: context.callID, kind: .settingsChange,
            body: .setting(change: "Add the MCP server \(server.name)", notes: notes),
            reason: "adds a program MOA starts, whose tools the agent can call")
        guard await context.confirm(request) else { return Self.declinedOutput }

        // Read again and merged now, so a change made while the owner decided is kept.
        switch file.adding(server) {
        case .failure(let problem): return "Error: \(problem.message) Nothing was changed."
        case .success(let text):
            do { try file.write(text) } catch { return "Error: could not save mcp-servers.json: \(error.localizedDescription)" }
        }
        var lines = ["Added the MCP server \(server.name) to mcp-servers.json. The owner said yes."]
        if let bridge {
            lines.append("It is a bridge: a remote server at \(MCPCommandDisplay.hidingSecrets(inURL: bridge.url)), reached through mcp-remote, \(bridge.runDescription).")
        }
        lines.append("Takes effect at the next launch: the owner has to quit MOA and open it again, and its tools join the tool list then.")
        if !server.envNames.isEmpty {
            lines.append("Still to do: the owner fills in the values of \(server.envNames.joined(separator: ", ")) in mcp-servers.json, which Settings, MCP Servers opens. They are empty now, and you never see them.")
        }
        if bridge != nil {
            lines.append("If the remote server needs a sign-in, a browser page opens the first time it starts, and the owner signs in there.")
        }
        if !Experiment.mcpServers.isOn(access.defaults) {
            lines.append("The MCP servers experiment is off, so no server starts until it is on.")
        }
        return lines.joined(separator: "\n")
    }

    func remove(_ value: JSONValue, context: ToolRunContext) async -> String {
        guard let name = value.stringValue else { return "Error: remove takes the server's name, as in \(SettingsArea.mcpServers.accepts[1])." }
        let file = MCPServerFile(url: access.serversFile)
        if case .failure(let problem) = file.removing(name) { return "Error: \(problem.message)" }
        let entry = MCPServerConfig.read(from: access.serversFile).servers.first { $0.name == name }
        var notes: [String] = []
        if let entry { notes.append("Command: \(MCPCommandDisplay.line(entry))") }
        if let entry, let bridge = MCPRemoteBridge(entry) { notes.append(bridge.cardSentence(server: name)) }
        if let entry, !entry.env.isEmpty { notes.append("Its environment values are removed with it.") }
        notes.append("Its tools leave at the next launch.")
        let request = ConfirmationRequest(
            callID: context.callID, kind: .settingsChange,
            body: .setting(change: "Remove the MCP server \(name)", notes: notes),
            reason: "removes a server and its saved settings from mcp-servers.json")
        guard await context.confirm(request) else { return Self.declinedOutput }
        switch file.removing(name) {
        case .failure(let problem): return "Error: \(problem.message) Nothing was changed."
        case .success(let text):
            do { try file.write(text) } catch { return "Error: could not save mcp-servers.json: \(error.localizedDescription)" }
        }
        return """
            Removed the MCP server \(name) from mcp-servers.json. The owner said yes.
            Takes effect at the next launch: its tools stay in this run's list until the owner quits MOA and opens it again.
            """
    }

    func turn(_ on: Bool, _ value: JSONValue, context: ToolRunContext) async -> String {
        let word = on ? "on" : "off"
        guard let name = value.stringValue else { return "Error: turn_\(word) takes the server's name, as in {\"turn_\(word)\": \"<name>\"}." }
        let config = MCPServerConfig.read(from: access.serversFile)
        guard let entry = config.servers.first(where: { $0.name == name }) else {
            let names = config.servers.map(\.name)
            return "Error: there is no MCP server named \"\(name)\" in mcp-servers.json."
                + (names.isEmpty ? " There are none." : " The servers are: \(names.joined(separator: ", ")).")
        }
        if access.mcp.settings.isEnabled(name) == on {
            return "The MCP server \(name) is already \(word). Nothing was changed."
        }
        var notes = ["Command: \(MCPCommandDisplay.line(entry))"]
        if let bridge = MCPRemoteBridge(entry) { notes.append(bridge.cardSentence(server: name)) }
        notes.append(on ? "It starts now, and its tools join at the next launch." : "It stops now, and its tools leave at the next launch.")
        let request = ConfirmationRequest(
            callID: context.callID, kind: .settingsChange,
            body: .setting(change: "Turn \(word) the MCP server \(name)", notes: notes),
            reason: on ? "starts a program whose tools the agent can call" : "stops a server MOA runs")
        guard await context.confirm(request) else { return Self.declinedOutput }
        do {
            try await access.mcp.setEnabled(on, server: name)
        } catch {
            return "Error: could not save mcp-settings.json: \(error.localizedDescription)"
        }
        var lines = ["Turned \(word) the MCP server \(name). The owner said yes."]
        lines.append(on
            ? "It starts now when MCP servers are on. Its tools join the tool list at the next launch: the owner has to quit MOA and open it again."
            : "It is stopped now. Its tools leave the tool list at the next launch, and a call to one before then says it is off.")
        if on, !Experiment.mcpServers.isOn(access.defaults) {
            lines.append("The MCP servers experiment is off, so it does not start until that is on.")
        }
        return lines.joined(separator: "\n")
    }

    struct ChangeProblem: Error, Equatable {
        var message: String
        init(_ message: String) { self.message = message }
    }
}

// MARK: - The servers file

/// `mcp-servers.json` as the settings tools change it: read fresh at each change, one server
/// added or removed, and every other entry and key kept as it was, in its order, with its
/// numbers and strings exactly as written. Saved readable only by the owner, since it can hold
/// tokens.
struct MCPServerFile {
    var url: URL

    struct NewServer: Equatable {
        var name: String
        var command: String
        var args: [String]
        var envNames: [String]

        /// The entry as the file holds it. Each environment variable's value is empty, for the
        /// owner to fill in.
        var value: JSONValue {
            var object: [String: JSONValue] = ["command": .string(command), "args": .array(args.map(JSONValue.string))]
            if !envNames.isEmpty { object["env"] = .object(Dictionary(envNames.map { ($0, JSONValue.string("")) }, uniquingKeysWith: { first, _ in first })) }
            return .object(object)
        }

        var node: JSONNode {
            var members: [(key: String, value: JSONNode)] = [
                (quoted("command"), .scalar(quoted(command))),
                (quoted("args"), .array(args.map { .scalar(quoted($0)) })),
            ]
            if !envNames.isEmpty {
                var seen = Set<String>()
                members.append((quoted("env"), .object(envNames.filter { seen.insert($0).inserted }.map { (quoted($0), .scalar(quoted(""))) })))
            }
            return .object(members)
        }
    }

    typealias Problem = ChangeSettingsTool.ChangeProblem

    /// The file's text with the server added, or why it cannot be.
    func adding(_ server: NewServer) -> Result<String, Problem> {
        servers().flatMap { root, servers in
            if servers.contains(where: { Self.name(ofKey: $0.key) == server.name }) {
                return .failure(Problem("there is already an MCP server named \"\(server.name)\". Remove it first to replace it, or pick another name."))
            }
            return text(root: root, servers: servers + [(quoted(server.name), server.node)])
        }
    }

    /// The file's text with the server removed, or why it cannot be.
    func removing(_ name: String) -> Result<String, Problem> {
        servers().flatMap { root, servers in
            guard servers.contains(where: { Self.name(ofKey: $0.key) == name }) else {
                let names = servers.compactMap { Self.name(ofKey: $0.key) }
                return .failure(Problem("there is no MCP server named \"\(name)\" in mcp-servers.json."
                    + (names.isEmpty ? " There are none." : " The servers are: \(names.joined(separator: ", ")).")))
            }
            return text(root: root, servers: servers.filter { Self.name(ofKey: $0.key) != name })
        }
    }

    /// The file's top-level members and its servers, read now. A missing or empty file is none.
    private func servers() -> Result<([(key: String, value: JSONNode)], [(key: String, value: JSONNode)]), Problem> {
        let data = (try? Data(contentsOf: url)) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .success(([], [])) }
        guard let root = JSONNode.parse(text), case .object(let members) = root else {
            return .failure(Problem("mcp-servers.json is not a valid JSON object, so it was left alone. The owner has to fix it first."))
        }
        guard let list = members.first(where: { Self.name(ofKey: $0.key) == "mcpServers" }) else { return .success((members, [])) }
        guard case .object(let servers) = list.value else {
            return .failure(Problem("\"mcpServers\" in mcp-servers.json is not an object, so the file was left alone. The owner has to fix it first."))
        }
        return .success((members, servers))
    }

    /// The whole file with `servers` as its `mcpServers`, checked the way launch reads it.
    private func text(root: [(key: String, value: JSONNode)], servers: [(key: String, value: JSONNode)]) -> Result<String, Problem> {
        var members = root
        if let index = members.firstIndex(where: { Self.name(ofKey: $0.key) == "mcpServers" }) {
            members[index].value = .object(servers)
        } else {
            members.append((quoted("mcpServers"), .object(servers)))
        }
        let text = JSONNode.object(members).prettyText() + "\n"
        if let problem = MCPServerConfig.parse(Data(text.utf8)).fileProblem { return .failure(Problem(problem)) }
        return .success(text)
    }

    /// Writes the text in place of the file, through a symbolic link if the file is one, made
    /// readable only by the owner before it holds anything.
    func write(_ text: String) throws {
        let manager = FileManager.default
        let target = url.resolvingSymlinksInPath()
        let folder = target.deletingLastPathComponent()
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appending(path: ".\(target.lastPathComponent).\(UUID().uuidString)")
        guard manager.createFile(atPath: temporary.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(temporary.path, target.path) != 0 {
            let code = errno
            try? manager.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// A key as the file wrote it, quotes and escapes included, read as the name it spells.
    static func name(ofKey key: String) -> String? {
        try? JSONDecoder().decode(String.self, from: Data(key.utf8))
    }
}

/// A string as JSON source text, with its quotes.
private func quoted(_ text: String) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return (try? encoder.encode(text)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
}

// MARK: - Bridges and display

/// A server entry that reaches a remote HTTP server through `mcp-remote`, the supported way
/// until MOA speaks HTTP itself: `npx -y mcp-remote <url>`, or `mcp-remote <url>`.
public struct MCPRemoteBridge: Sendable, Equatable {
    public var url: String
    /// The program that runs the bridge: `npx`, or `mcp-remote` itself.
    public var runner: String

    public init?(_ entry: MCPServerEntry) {
        let command = (entry.command as NSString).lastPathComponent
        let rest: ArraySlice<String>
        if command == "mcp-remote" {
            rest = entry.args[...]
        } else if command == "npx", let index = entry.args.firstIndex(where: { $0 == "mcp-remote" || $0.hasPrefix("mcp-remote@") }) {
            rest = entry.args[(index + 1)...]
        } else {
            return nil
        }
        guard let url = rest.first(where: { $0.hasPrefix("http://") || $0.hasPrefix("https://") }) else { return nil }
        self.url = url
        runner = command
    }

    /// How the bridge is run, such as "run with npx".
    public var runDescription: String {
        runner == "npx" ? "run with npx" : "run as mcp-remote"
    }

    /// The card's plain sentence, such as "figma is a remote server. MOA will reach it
    /// through mcp-remote, run with npx."
    public func cardSentence(server: String) -> String {
        "\(server) is a remote server. MOA will reach it through mcp-remote, \(runDescription)."
    }
}

/// A server's command line as the settings tools show it, with what looks like a secret in
/// it hidden: a header's value, and a URL's query value whose name says it is a key or token.
/// Environment values are never part of it.
enum MCPCommandDisplay {
    static let hidden = "(hidden)"

    static func line(_ entry: MCPServerEntry) -> String {
        var shown = entry
        var hideNext = false
        shown.args = entry.args.map { argument in
            defer { hideNext = argument == "--header" || argument == "-H" }
            if hideNext, let colon = argument.firstIndex(of: ":") {
                return String(argument[..<colon]) + ": " + hidden
            }
            if argument.lowercased().contains("bearer ") { return hidden }
            if argument.hasPrefix("http://") || argument.hasPrefix("https://") { return hidingSecrets(inURL: argument) }
            return argument
        }
        return shown.commandLine
    }

    static func hidingSecrets(inURL text: String) -> String {
        guard var components = URLComponents(string: text), let items = components.queryItems, !items.isEmpty else { return text }
        let secretWords = ["key", "token", "secret", "auth", "password", "sig"]
        components.queryItems = items.map { item in
            secretWords.contains(where: { item.name.lowercased().contains($0) }) ? URLQueryItem(name: item.name, value: hidden) : item
        }
        return components.string ?? text
    }
}
