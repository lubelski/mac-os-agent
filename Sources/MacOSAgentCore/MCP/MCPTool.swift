import Foundation

extension ToolSource {
    /// The source for an MCP server's tools, one group per server in Settings.
    public static func mcp(_ server: String) -> ToolSource {
        ToolSource(id: "mcp:\(server)", title: server)
    }

    public var isMCPServer: Bool { id.hasPrefix("mcp:") }
}

/// One tool from an MCP server, named `<server>__<tool>`, with the description and schema the
/// server gave it.
public struct MCPTool: AgentTool {
    public let server: String
    public let info: MCPToolInfo
    public let name: String
    let pool: MCPServerPool
    /// The most of a result passed to the model. A longer one is cut, with a note saying so.
    public var outputLimit: Int

    public init(server: String, info: MCPToolInfo, name: String, pool: MCPServerPool, outputLimit: Int = 16_000) {
        self.server = server
        self.info = info
        self.name = name
        self.pool = pool
        self.outputLimit = outputLimit
    }

    public var definition: ToolDefinition {
        ToolDefinition(name: name, description: info.description, parameters: Self.schema(info.inputSchema), strict: false)
    }

    public var source: ToolSource { .mcp(server) }

    /// Read at each call, so a change in Settings applies to the next one.
    public var currentGoAhead: MCPGoAhead {
        pool.settings.goAhead(server: server, tool: info.name, readOnly: info.readOnly)
    }

    public var goAhead: ToolGoAhead { currentGoAhead.toolGoAhead }

    /// The schema as the server gave it, with the two things the model's API needs of a
    /// function's parameters: an object type and a properties object.
    static func schema(_ schema: JSONValue) -> JSONValue {
        guard case .object(var object) = schema else { return ["type": "object", "properties": [:]] }
        if object["type"] == nil { object["type"] = "object" }
        if object["properties"] == nil, object["type"] == "object" { object["properties"] = [:] }
        return .object(object)
    }

    /// The tool and its server, then the arguments in brief, such as
    /// `get_forecast on weather: city Lisbon, days 3`.
    public func summary(arguments: JSONValue) -> String {
        let head = "\(info.name) on \(server)"
        guard case .object(let object) = arguments, !object.isEmpty else { return head }
        let parts = object.keys.sorted().map { key -> String in
            let value = object[key] ?? .null
            let text = value.stringValue ?? value.encodedString()
            return "\(key) \(AgentInstructions.singleLine(text))"
        }
        let line = parts.joined(separator: ", ")
        return "\(head): " + (line.count > 120 ? String(line.prefix(119)) + "…" : line)
    }

    public static let declinedOutput = "The person declined this call. It did not run."
    public static let stoppedOutput = "The task was stopped before the call finished."

    public func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        let connection: any MCPServerConnection
        do {
            connection = try await pool.connection(to: server)
        } catch is CancellationError {
            return Self.stoppedOutput
        } catch {
            return "The MCP server \(server) is not available, so \(info.name) did not run: \(MCPServerPool.describe(error))"
        }
        if currentGoAhead == .ask {
            let approved = await context.confirm(ConfirmationRequest(
                callID: context.callID, kind: .mcpToolCall,
                body: .toolCall(server: server, tool: info.name, arguments: arguments.prettyEncodedString()),
                reason: "comes from an MCP server and is set to ask before each call"))
            if Task.isCancelled { return Self.stoppedOutput }
            if !approved { return Self.declinedOutput }
        }
        let timeout = pool.callTimeout
        let tool = info.name
        do {
            let result = try await MCPRace.withTimeout(timeout) {
                try await connection.callTool(name: tool, arguments: arguments)
            }
            return MCPToolResultText.text(for: result, limit: outputLimit)
        } catch is CancellationError {
            return Self.stoppedOutput
        } catch MCPConnectionError.timedOut(let seconds) {
            return "The call to \(info.name) on \(server) was stopped after the \(seconds) second limit."
        } catch {
            if error is MCPConnectionError {
                await pool.connectionLost(server, error: error)
            }
            return "The call to \(info.name) on \(server) failed: \(MCPServerPool.describe(error))"
        }
    }
}

/// A tool call's result as the model reads it.
public enum MCPToolResultText {
    /// The text content joined, with a short note naming what was left out. A result the server
    /// marks as an error reads as one. A long result is cut at the limit, and says so.
    public static func text(for result: MCPCallResult, limit: Int = 16_000) -> String {
        var texts: [String] = []
        var leftOut: [String] = []
        for item in result.content {
            switch item {
            case .text(let text): texts.append(text)
            case .image(let mimeType): leftOut.append("an image (\(mimeType))")
            case .audio(let mimeType): leftOut.append("audio (\(mimeType))")
            case .resource(let uri, _): leftOut.append("a resource (\(uri))")
            case .resourceLink(let uri, _): leftOut.append("a link to \(uri)")
            }
        }
        var text = texts.joined(separator: "\n")
        if text.count > limit {
            let total = text.count
            text = String(text.prefix(limit)) + "\n[Cut at \(limit) of \(total) characters.]"
        }
        if !leftOut.isEmpty {
            let note = "[The result also had \(list(leftOut)), left out here since only text is passed on.]"
            text = text.isEmpty ? note : text + "\n" + note
        }
        if result.isError {
            return "Error: " + (text.isEmpty ? "the tool reported an error with no message." : text)
        }
        return text.isEmpty ? "(no output)" : text
    }

    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: items.dropLast().joined(separator: ", ") + ", and " + items[items.count - 1]
        }
    }
}
