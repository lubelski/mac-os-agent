import Foundation
import Synchronization

/// Whether a tool from an MCP server asks for the owner's go-ahead before each call.
public enum MCPGoAhead: String, Sendable, Codable, Equatable {
    case ask
    case dontAsk = "dont-ask"

    /// The default: ask, except for a tool its server marks read-only.
    public static func defaultValue(readOnly: Bool) -> MCPGoAhead { readOnly ? .dontAsk : .ask }

    public var toolGoAhead: ToolGoAhead { self == .ask ? .always : .never }
}

/// What the app decides about MCP servers, kept in `mcp-settings.json` apart from the servers
/// file the owner edits, as `skill-settings.json` is for skills: which servers are off (each is
/// on unless it is listed), and each tool's go-ahead where the owner has set one.
///
/// ```json
/// {"disabled": ["notes"], "goAhead": {"weather": {"get_forecast": "dont-ask"}}}
/// ```
///
/// It is read once and kept in memory, so a tool reads its go-ahead at each call without
/// touching the disk. A change is written at once and applies to the next call.
public final class MCPSettingsStore: Sendable {
    public let file: URL
    private let state: Mutex<Settings>

    struct Settings: Codable, Equatable {
        var disabled: [String] = []
        /// By server, then by the tool's name on its server.
        var goAhead: [String: [String: MCPGoAhead]] = [:]

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            disabled = (try? container.decodeIfPresent([String].self, forKey: .disabled)) ?? []
            goAhead = (try? container.decodeIfPresent([String: [String: MCPGoAhead]].self, forKey: .goAhead)) ?? [:]
        }
    }

    public init(file: URL = AgentPaths.mcpSettingsFile) {
        self.file = file
        let settings = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
        state = Mutex(settings)
    }

    public func isEnabled(_ server: String) -> Bool {
        state.withLock { !$0.disabled.contains(server) }
    }

    public func setEnabled(_ enabled: Bool, server: String) throws {
        try change { settings in
            var disabled = Set(settings.disabled)
            if enabled { disabled.remove(server) } else { disabled.insert(server) }
            settings.disabled = disabled.sorted()
        }
    }

    /// The go-ahead the owner set for a tool, or nil when they have not.
    public func goAheadOverride(server: String, tool: String) -> MCPGoAhead? {
        state.withLock { $0.goAhead[server]?[tool] }
    }

    /// The tool's go-ahead: the owner's choice, or the default.
    public func goAhead(server: String, tool: String, readOnly: Bool) -> MCPGoAhead {
        goAheadOverride(server: server, tool: tool) ?? .defaultValue(readOnly: readOnly)
    }

    /// Sets a tool's go-ahead. Setting it to its default removes the override, so a later
    /// change in the server's read-only mark is followed.
    public func setGoAhead(_ value: MCPGoAhead, server: String, tool: String, readOnly: Bool) throws {
        try change { settings in
            var tools = settings.goAhead[server] ?? [:]
            tools[tool] = value == .defaultValue(readOnly: readOnly) ? nil : value
            settings.goAhead[server] = tools.isEmpty ? nil : tools
        }
    }

    private func change(_ body: (inout Settings) -> Void) throws {
        let settings = state.withLock { settings in
            body(&settings)
            return settings
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(settings).write(to: file, options: .atomic)
    }
}
