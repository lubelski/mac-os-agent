import Foundation

/// One server from `mcp-servers.json`, in the `mcpServers` shape other apps use, so an entry
/// can be pasted from one:
///
/// ```json
/// {"mcpServers": {"weather": {"command": "npx", "args": ["-y", "weather-mcp"], "env": {"API_KEY": "…"}}}}
/// ```
public struct MCPServerEntry: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var command: String
    public var args: [String]
    /// Passed to the server's process on top of the app's own environment. Can hold tokens, so
    /// Settings shows only the names.
    public var env: [String: String]
    /// Why the entry cannot be used. Nil for an entry the app can start.
    public var problem: String?
    /// What the server is for, in the owner's words, from an optional `description` in the
    /// entry. Settings shows it under the server's name. Other apps ignore the key, so an entry
    /// with one can still be pasted into them.
    public var description: String?

    public init(
        name: String, command: String, args: [String] = [], env: [String: String] = [:], problem: String? = nil,
        description: String? = nil
    ) {
        self.name = name
        self.command = command
        self.args = args
        self.env = env
        self.problem = problem
        self.description = description
    }

    /// The command and its arguments as one line, for Settings.
    public var commandLine: String {
        ([command] + args).map { $0.contains(" ") || $0.isEmpty ? "\"\($0)\"" : $0 }.joined(separator: " ")
    }
}

/// What `mcp-servers.json` says, read once at launch.
public struct MCPServerConfig: Sendable, Equatable {
    /// Every entry, sorted by name, including the ones with a problem.
    public var servers: [MCPServerEntry]
    /// Why the file as a whole could not be read. Nil when it was read, or when it is missing.
    public var fileProblem: String?
    /// False when there is no file.
    public var fileExists: Bool

    public init(servers: [MCPServerEntry] = [], fileProblem: String? = nil, fileExists: Bool = true) {
        self.servers = servers
        self.fileProblem = fileProblem
        self.fileExists = fileExists
    }

    /// The entries the app can start.
    public var usableServers: [MCPServerEntry] { servers.filter { $0.problem == nil } }

    /// Every problem, one line each, for the problems list.
    public var problems: [String] {
        (fileProblem.map { [$0] } ?? []) + servers.compactMap { entry in entry.problem.map { "\(entry.name): \($0)" } }
    }

    // MARK: - Names

    /// The longest server name. A tool is named `<server>__<tool>` and the model takes 64
    /// characters, so this leaves at least 30 for the tool.
    public static let nameLimit = 32

    /// Why a server name cannot be used, or nil when it can. A name is 1 to 32 letters, digits,
    /// hyphens, and single underscores, and does not start or end with an underscore. The rule
    /// keeps `<server>__<tool>` inside the model's tool name rules, and keeps `__` meaning only
    /// the line between the server and the tool.
    public static func problem(withName name: String) -> String? {
        if name.isEmpty { return "The server needs a name." }
        if name.count > nameLimit { return "The name is longer than \(nameLimit) characters." }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        if !name.allSatisfy(allowed.contains) {
            return "The name can only have letters, digits, hyphens, and underscores, since it starts each of its tools' names."
        }
        if name.contains("__") || name.hasPrefix("_") || name.hasSuffix("_") {
            return "The name cannot have two underscores in a row or start or end with one, since two underscores separate it from a tool's name."
        }
        return nil
    }

    // MARK: - Reading

    /// Reads the file and makes it readable only by the owner if it was not. A missing file is
    /// no servers and no problem. A file that cannot be read is a `fileProblem`, and an entry
    /// that is wrong keeps its name and a problem, while the others still load.
    public static func read(from file: URL = AgentPaths.mcpServersFile) -> MCPServerConfig {
        let manager = FileManager.default
        guard manager.fileExists(atPath: file.path) else { return MCPServerConfig(fileExists: false) }
        makePrivate(file)
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            return MCPServerConfig(fileProblem: "Could not read mcp-servers.json: \(error.localizedDescription)")
        }
        return parse(data)
    }

    /// Owner read and write only, as the file can hold tokens.
    static func makePrivate(_ file: URL) {
        let manager = FileManager.default
        guard let permissions = (try? manager.attributesOfItem(atPath: file.path))?[.posixPermissions] as? Int,
              permissions & 0o077 != 0
        else { return }
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    public static func parse(_ data: Data) -> MCPServerConfig {
        if data.allSatisfy({ [0x20, 0x0a, 0x0d, 0x09].contains($0) }) { return MCPServerConfig() }
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return MCPServerConfig(fileProblem: "mcp-servers.json is not valid JSON.")
        }
        guard case .object(let top) = root else {
            return MCPServerConfig(fileProblem: "mcp-servers.json should be an object with an \"mcpServers\" object in it.")
        }
        guard let list = top["mcpServers"] else {
            return MCPServerConfig(fileProblem: "mcp-servers.json has no \"mcpServers\" object.")
        }
        guard case .object(let entries) = list else {
            return MCPServerConfig(fileProblem: "\"mcpServers\" in mcp-servers.json should be an object of servers by name.")
        }
        let servers = entries.keys.sorted().map { name in entry(named: name, entries[name] ?? .null) }
        return MCPServerConfig(servers: servers)
    }

    static func entry(named name: String, _ value: JSONValue) -> MCPServerEntry {
        func broken(_ problem: String) -> MCPServerEntry {
            MCPServerEntry(name: name, command: value["command"]?.stringValue ?? "", problem: problem)
        }
        if let problem = problem(withName: name) { return broken(problem) }
        guard case .object = value else { return broken("The entry should be an object with a \"command\".") }
        guard let command = value["command"]?.stringValue?.trimmingCharacters(in: .whitespaces), !command.isEmpty else {
            if value["url"] != nil || value["serverUrl"] != nil {
                return broken("Remote servers are not supported yet. Only servers started with a \"command\" are.")
            }
            return broken("The entry has no \"command\".")
        }
        if let type = value["type"]?.stringValue, type != "stdio" {
            return broken("Only \"stdio\" servers are supported, not \"\(type)\".")
        }
        var args: [String] = []
        if let raw = value["args"], raw != .null {
            guard let list = raw.arrayValue, list.allSatisfy({ $0.stringValue != nil }) else {
                return broken("\"args\" should be a list of strings.")
            }
            args = list.compactMap(\.stringValue)
        }
        var env: [String: String] = [:]
        if let raw = value["env"], raw != .null {
            guard case .object(let object) = raw, object.values.allSatisfy({ $0.stringValue != nil }) else {
                return broken("\"env\" should be an object of strings.")
            }
            env = object.compactMapValues(\.stringValue)
        }
        // A description that is not a string is left out rather than making the entry unusable.
        let description = value["description"]?.stringValue
        return MCPServerEntry(name: name, command: command, args: args, env: env, description: description)
    }

    /// What a new `mcp-servers.json` could hold, for the empty state in Settings.
    public static let example = """
        {
          "mcpServers": {
            "everything": {
              "command": "npx",
              "args": ["-y", "@modelcontextprotocol/server-everything"]
            }
          }
        }
        """
}
