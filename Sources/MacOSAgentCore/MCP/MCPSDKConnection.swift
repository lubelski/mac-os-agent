import Foundation
import MCP
import Synchronization
import System

/// The app's connection to a server, through the official MCP Swift SDK over stdio.
///
/// This is the only file that imports the SDK. The rest of the app sees `MCPServerConnection`
/// and the app's own types. The app starts the server's process itself, with `MCPServerProcess`,
/// and hands its pipes to the SDK's stdio transport.
public final class MCPSDKConnection: MCPServerConnection {
    public let entry: MCPServerEntry
    private let state = Mutex<(process: MCPServerProcess?, client: Client?, transport: StdioTransport?)>((nil, nil, nil))

    public init(entry: MCPServerEntry) {
        self.entry = entry
    }

    private static var clientVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }

    public func connect() async throws {
        let process = try MCPServerProcess.launch(entry)
        let transport = StdioTransport(
            input: FileDescriptor(rawValue: process.outputDescriptor),
            output: FileDescriptor(rawValue: process.inputDescriptor))
        let client = Client(name: "mac-os-agent", version: Self.clientVersion)
        state.withLock { $0 = (process, client, transport) }
        do {
            _ = try await whileRunning(process) { try await client.connect(transport: transport) }
        } catch {
            await stop()
            throw error
        }
    }

    public func listTools() async throws -> [MCPToolInfo] {
        let (process, client) = try connected()
        var tools: [MCPToolInfo] = []
        var cursor: String?
        // A server that keeps handing back a cursor stops being asked after this many pages.
        for _ in 0..<50 {
            let current = cursor
            let page = try await whileRunning(process) { try await client.listTools(cursor: current) }
            tools += page.tools.map(Self.info)
            guard let next = page.nextCursor, !next.isEmpty, next != cursor else { break }
            cursor = next
        }
        return tools
    }

    public func callTool(name: String, arguments: JSONValue) async throws -> MCPCallResult {
        let (process, client) = try connected()
        let values: [String: Value]? = if case .object = arguments { try Self.convert(arguments) } else { nil }
        let result = try await whileRunning(process) { try await client.callTool(name: name, arguments: values) }
        return MCPCallResult(content: result.content.map(Self.content), isError: result.isError == true)
    }

    public func stop() async {
        let (process, client, transport) = state.withLock { state in
            defer { state = (nil, nil, nil) }
            return state
        }
        await client?.disconnect()
        await transport?.disconnect()
        await process?.stop()
    }

    private func connected() throws -> (MCPServerProcess, Client) {
        let (process, client, _) = state.withLock { $0 }
        guard let process, let client, process.exitStatus == nil else { throw MCPConnectionError.notConnected }
        return (process, client)
    }

    /// The operation, or the server's exit with what it last wrote to standard error, whichever
    /// comes first. A server that exits never answers, and the SDK would wait for it.
    private func whileRunning<T: Sendable>(_ process: MCPServerProcess, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await MCPRace.first([
            operation,
            {
                let status = await process.waitForExit()
                // Lets the last of standard error arrive before it is read.
                try? await Task.sleep(for: .milliseconds(100))
                throw MCPConnectionError.exited(status: status, message: process.errorText)
            },
        ])
    }

    // MARK: - Converting to the app's types

    static func info(_ tool: Tool) -> MCPToolInfo {
        MCPToolInfo(
            name: tool.name,
            title: tool.title ?? tool.annotations.title,
            description: tool.description ?? "",
            inputSchema: (try? convert(tool.inputSchema)) ?? ["type": "object"],
            readOnly: tool.annotations.readOnlyHint == true)
    }

    static func content(_ item: Tool.Content) -> MCPContent {
        switch item {
        case .text(let text, _, _): .text(text)
        case .image(_, let mimeType, _, _): .image(mimeType: mimeType)
        case .audio(_, let mimeType, _, _): .audio(mimeType: mimeType)
        case .resource(let resource, _, _): .resource(uri: resource.uri, mimeType: resource.mimeType)
        case .resourceLink(let uri, let name, _, _, _, _): .resourceLink(uri: uri, name: name)
        }
    }

    /// Between the SDK's `Value` and `JSONValue`, through their JSON encodings.
    static func convert(_ value: Value) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    static func convert(_ value: JSONValue) throws -> [String: Value] {
        try JSONDecoder().decode([String: Value].self, from: JSONEncoder().encode(value))
    }
}
