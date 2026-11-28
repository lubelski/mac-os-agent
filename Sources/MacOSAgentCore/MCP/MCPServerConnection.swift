import Foundation

/// A connection to one MCP server, in the app's own types.
///
/// This is the seam between the app and the MCP client. The app talks to a server only
/// through it, so nothing outside `MCPSDKConnection.swift` sees the SDK's types, and the client
/// can be swapped. Tests and previews use stand-ins that start no process.
public protocol MCPServerConnection: Sendable {
    /// Starts the server and completes the MCP handshake. Throws `MCPConnectionError` or the
    /// client's own error when the server cannot be started or does not answer.
    func connect() async throws
    /// Every tool the server offers, all pages of them, in the server's order.
    func listTools() async throws -> [MCPToolInfo]
    /// Calls one tool by the name the server gave it.
    func callTool(name: String, arguments: JSONValue) async throws -> MCPCallResult
    /// Ends the connection and the server's process. Safe to call more than once.
    func stop() async
    /// What the server said about itself when it connected, or nil before it has or when the
    /// connection does not know.
    var serverInfo: MCPServerInfo? { get }
}

extension MCPServerConnection {
    public var serverInfo: MCPServerInfo? { nil }
}

/// Makes the connection for one server entry. The app's is `MCPSDKConnection.init`.
public typealias MCPConnectionFactory = @Sendable (MCPServerEntry) -> any MCPServerConnection

/// One tool as a server describes it.
public struct MCPToolInfo: Sendable, Equatable, Codable {
    /// The name the server knows it by, which may not be a valid model tool name.
    public var name: String
    public var title: String?
    public var description: String
    /// The JSON Schema for the arguments, as the server gave it.
    public var inputSchema: JSONValue
    /// The server marks the tool as one that changes nothing (`annotations.readOnlyHint`).
    public var readOnly: Bool

    public init(name: String, title: String? = nil, description: String, inputSchema: JSONValue, readOnly: Bool = false) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.readOnly = readOnly
    }
}

/// What a tool call returned.
public struct MCPCallResult: Sendable, Equatable {
    public var content: [MCPContent]
    /// The server says the call failed. The content then says why.
    public var isError: Bool

    public init(content: [MCPContent], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }
}

/// One piece of a tool call's result. Only text reaches the model. The rest is named.
public enum MCPContent: Sendable, Equatable {
    case text(String)
    case image(mimeType: String)
    case audio(mimeType: String)
    /// An embedded resource. Its text, when it has some, is not passed on in this version.
    case resource(uri: String, mimeType: String?)
    case resourceLink(uri: String, name: String)
}

/// Why a connection failed, in words for Settings and the model.
public enum MCPConnectionError: Error, Equatable, LocalizedError {
    case commandNotFound(String)
    case couldNotStart(String)
    /// The server exited. The text is the end of what it wrote to standard error, if anything.
    case exited(status: Int32, message: String)
    case timedOut(seconds: Int)
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .commandNotFound(let command):
            "Could not find \(command). Use its full path in mcp-servers.json, or install it where a login shell finds it."
        case .couldNotStart(let reason):
            "Could not start the server: \(reason)"
        case .exited(let status, let message):
            message.isEmpty ? "The server exited with status \(status)." : "The server exited with status \(status): \(message)"
        case .timedOut(let seconds):
            "The server did not answer within \(seconds) seconds."
        case .notConnected:
            "The server is not connected."
        }
    }
}
