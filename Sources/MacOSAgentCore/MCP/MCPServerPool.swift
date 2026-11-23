import Foundation
import Synchronization

/// One server as Settings shows it.
public struct MCPServerStatus: Sendable, Equatable, Identifiable {
    public enum State: Sendable, Equatable {
        /// The owner turned it off.
        case off
        case starting
        case connected
        case failed(String)
        /// Its entry in `mcp-servers.json` is wrong, so it is never started.
        case invalid(String)

        public var label: String {
            switch self {
            case .off: "Off"
            case .starting: "Starting"
            case .connected: "Connected"
            case .failed: "Failed"
            case .invalid: "Not Valid"
            }
        }
    }

    public var id: String { entry.name }
    public var entry: MCPServerEntry
    public var state: State
    public var isEnabled: Bool
    /// Its tools: the list it gave this run, or the cached one until it connects.
    public var tools: [MCPToolInfo]
    /// The tools the model was given at launch. Nil when none joined.
    public var toolsAtLaunch: [MCPToolInfo]?
    /// The list it gave this run, once it has connected.
    public var liveTools: [MCPToolInfo]?

    /// What changes at the next launch, or nil when nothing does.
    public var nextLaunchNote: String? {
        if !isEnabled {
            return toolsAtLaunch == nil ? nil : "Its tools leave the tool list at the next launch."
        }
        guard let liveTools else { return nil }
        if toolsAtLaunch == nil {
            return liveTools.isEmpty ? nil : "Its tools join the tool list at the next launch."
        }
        return liveTools == toolsAtLaunch ? nil : "Its tools changed. The new list is used from the next launch."
    }
}

/// Why a server could not be reached for a call.
public enum MCPPoolError: Error, Equatable, LocalizedError {
    case off
    case unknown
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .off: "The server is turned off in Settings."
        case .unknown: "The server is no longer in mcp-servers.json."
        case .invalid(let problem): problem
        }
    }
}

/// The MCP servers for this run: what the files said at launch, and a connection to each
/// server that is on.
///
/// The tool list is built once, at launch, from `mcp-servers.json` and the cached lists in
/// `mcp-tools-cache.json`, without waiting for any server. The servers are then started in the
/// background. A call to a tool whose server is still starting waits for it, up to the connect
/// timeout. A server that fails is tried again at the next call to one of its tools.
public actor MCPServerPool {
    public nonisolated let config: MCPServerConfig
    public nonisolated let settings: MCPSettingsStore
    /// Each server's tools as the model was given them at launch.
    public nonisolated let launchLists: [String: [MCPToolInfo]]
    public nonisolated let connectTimeout: Duration
    public nonisolated let callTimeout: Duration
    nonisolated let cacheFile: URL?
    nonisolated let factory: MCPConnectionFactory
    nonisolated let problems: ProblemLog?
    private nonisolated let observers = Mutex<[@Sendable () -> Void]>([])

    private var cache: MCPToolCache
    private var servers: [String: Server] = [:]

    private struct Server {
        var state: MCPServerStatus.State
        var connection: (any MCPServerConnection)?
        var attempt: Task<any MCPServerConnection, Error>?
        /// Counts attempts, so one that finishes after the server was turned off is ignored.
        var generation = 0
        var liveTools: [MCPToolInfo]?
    }

    /// - Parameters:
    ///   - cacheFile: Where a changed tool list is written. Nil writes nothing, for previews.
    ///   - problems: Where a server that fails is reported.
    public init(
        config: MCPServerConfig, settings: MCPSettingsStore, cache: MCPToolCache, cacheFile: URL?,
        problems: ProblemLog? = nil, connectTimeout: Duration = .seconds(60), callTimeout: Duration = .seconds(120),
        factory: @escaping MCPConnectionFactory
    ) {
        self.config = config
        self.settings = settings
        self.cache = cache
        self.cacheFile = cacheFile
        self.problems = problems
        self.connectTimeout = connectTimeout
        self.callTimeout = callTimeout
        self.factory = factory
        launchLists = cache.launchLists(config: config, settings: settings)
        for entry in config.servers {
            let state: MCPServerStatus.State = if let problem = entry.problem {
                .invalid(problem)
            } else if !settings.isEnabled(entry.name) {
                .off
            } else {
                .starting
            }
            servers[entry.name] = Server(state: state)
        }
    }

    /// The pool for this run, from the files in the data folder, with the SDK's client. Reports
    /// what is wrong with the servers file to the problems list.
    public static func fromDataFolder(problems: ProblemLog?) -> MCPServerPool {
        let config = MCPServerConfig.read()
        for problem in config.problems { problems?.record("MCP servers", problem) }
        return MCPServerPool(
            config: config, settings: MCPSettingsStore(), cache: MCPToolCache.read(),
            cacheFile: AgentPaths.mcpToolsCacheFile, problems: problems,
            factory: { MCPSDKConnection(entry: $0) })
    }

    /// No servers, for tests and for a preview without a data folder of its own.
    public static var empty: MCPServerPool {
        MCPServerPool(
            config: MCPServerConfig(fileExists: false), settings: MCPSettingsStore(file: FileManager.default.temporaryDirectory.appending(path: "mac-os-agent-no-mcp-settings.json")),
            cache: MCPToolCache(), cacheFile: nil, factory: { _ in UnusedConnection() })
    }

    private struct UnusedConnection: MCPServerConnection {
        func connect() async throws { throw MCPConnectionError.notConnected }
        func listTools() async throws -> [MCPToolInfo] { [] }
        func callTool(name: String, arguments: JSONValue) async throws -> MCPCallResult { throw MCPConnectionError.notConnected }
        func stop() async {}
    }

    /// The tools that join the list at launch, one per tool in each server's cached list.
    public nonisolated func makeTools() -> [any AgentTool] {
        var tools: [any AgentTool] = []
        for (server, list) in launchLists {
            let names = MCPToolNaming.names(server: server, tools: list.map(\.name))
            var seen = Set<String>()
            for info in list where seen.insert(info.name).inserted {
                tools.append(MCPTool(server: server, info: info, name: names[info.name] ?? "\(server)__\(info.name)", pool: self))
            }
        }
        return tools
    }

    /// Calls `handler` after any server's state changes. It is called on no particular thread.
    public nonisolated func onChange(_ handler: @escaping @Sendable () -> Void) {
        observers.withLock { $0.append(handler) }
    }

    private func notify() {
        for handler in observers.withLock({ $0 }) { handler() }
    }

    /// Starts every server that is on and can be used, in the background. Returns at once.
    public func start() {
        for entry in config.usableServers where settings.isEnabled(entry.name) && servers[entry.name]?.attempt == nil {
            begin(entry)
        }
    }

    public func statuses() -> [MCPServerStatus] {
        config.servers.map { entry in
            let server = servers[entry.name]
            let live = server?.liveTools
            return MCPServerStatus(
                entry: entry, state: server?.state ?? .off, isEnabled: settings.isEnabled(entry.name),
                tools: live ?? cache.servers[entry.name]?.tools ?? [],
                toolsAtLaunch: launchLists[entry.name], liveTools: live)
        }
    }

    /// The server's connection, once it has connected. Waits while it starts, and starts it
    /// again if it failed. Throws when it is off, wrong, or does not connect in time.
    public func connection(to name: String) async throws -> any MCPServerConnection {
        guard let entry = config.servers.first(where: { $0.name == name }) else { throw MCPPoolError.unknown }
        if let problem = entry.problem { throw MCPPoolError.invalid(problem) }
        guard settings.isEnabled(name) else { throw MCPPoolError.off }
        if let connection = servers[name]?.connection { return connection }
        let attempt = servers[name]?.attempt ?? begin(entry)
        // Answers the task being stopped at once, even while the attempt goes on.
        return try await MCPRace.first([{ try await attempt.value }])
    }

    @discardableResult
    private func begin(_ entry: MCPServerEntry) -> Task<any MCPServerConnection, Error> {
        let name = entry.name
        var server = servers[name] ?? Server(state: .starting)
        server.generation += 1
        let generation = server.generation
        server.state = .starting
        let connection = factory(entry)
        let timeout = connectTimeout
        let attempt = Task<any MCPServerConnection, Error> {
            do {
                let tools = try await MCPRace.withTimeout(timeout) {
                    try await connection.connect()
                    return try await connection.listTools()
                }
                await self.didConnect(name, generation: generation, connection: connection, tools: tools)
                return connection
            } catch {
                await connection.stop()
                self.didFail(name, generation: generation, error: error)
                throw error
            }
        }
        server.attempt = attempt
        servers[name] = server
        notify()
        return attempt
    }

    private func didConnect(_ name: String, generation: Int, connection: any MCPServerConnection, tools: [MCPToolInfo]) async {
        guard servers[name]?.generation == generation, settings.isEnabled(name) else {
            await connection.stop()
            return
        }
        servers[name]?.state = .connected
        servers[name]?.connection = connection
        servers[name]?.attempt = nil
        servers[name]?.liveTools = tools
        if cache.servers[name]?.tools != tools {
            cache.servers[name] = MCPToolCache.Entry(tools: tools)
            if let cacheFile {
                do {
                    try cache.write(to: cacheFile)
                } catch {
                    problems?.record("MCP servers", "Could not save the tool list of \(name): \(error.localizedDescription)")
                }
            }
        }
        notify()
    }

    private func didFail(_ name: String, generation: Int, error: Error) {
        guard servers[name]?.generation == generation else { return }
        servers[name]?.attempt = nil
        servers[name]?.connection = nil
        guard settings.isEnabled(name) else { return }
        let message = Self.describe(error)
        servers[name]?.state = .failed(message)
        problems?.record("MCP server \(name)", message)
        notify()
    }

    /// The connection was lost during a call, such as when the server exited. The next call
    /// starts it again.
    public func connectionLost(_ name: String, error: Error) async {
        guard let connection = servers[name]?.connection else { return }
        servers[name]?.connection = nil
        servers[name]?.generation += 1
        let message = Self.describe(error)
        servers[name]?.state = .failed(message)
        problems?.record("MCP server \(name)", message)
        notify()
        await connection.stop()
    }

    /// Turns a server on or off. Off stops it now, and on starts it now. Its tools join or leave
    /// the tool list at the next launch.
    public func setEnabled(_ enabled: Bool, server name: String) async throws {
        try settings.setEnabled(enabled, server: name)
        guard let entry = config.servers.first(where: { $0.name == name }), entry.problem == nil else {
            notify()
            return
        }
        if enabled {
            if servers[name]?.connection == nil, servers[name]?.attempt == nil { begin(entry) }
        } else {
            let connection = servers[name]?.connection
            servers[name]?.attempt?.cancel()
            servers[name]?.attempt = nil
            servers[name]?.connection = nil
            servers[name]?.generation += 1
            servers[name]?.state = .off
            notify()
            await connection?.stop()
        }
        notify()
    }

    /// Stops every server.
    public func stopAll() async {
        let connections = servers.values.compactMap(\.connection)
        for name in servers.keys {
            servers[name]?.attempt?.cancel()
            servers[name]?.generation += 1
            servers[name]?.connection = nil
        }
        for connection in connections { await connection.stop() }
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? LocalizedError, let text = error.errorDescription { return text }
        return String(describing: error)
    }
}
