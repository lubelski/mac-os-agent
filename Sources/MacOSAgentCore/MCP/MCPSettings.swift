import Foundation
import Synchronization

/// What a tool from an MCP server does about the owner's go-ahead: ask before each call, run
/// without asking, or never run.
public enum MCPGoAhead: String, Sendable, Codable, Equatable, CaseIterable {
    case ask
    /// Runs without asking. Written as `dont-ask`, its name before Always Deny existed, so
    /// files from older builds read the same and older builds read this one.
    case allow = "dont-ask"
    /// Never runs and never asks. The model is told the owner set it that way.
    case deny

    /// The default: ask, except for a tool its server marks read-only.
    public static func defaultValue(readOnly: Bool) -> MCPGoAhead { readOnly ? .allow : .ask }

    public var toolGoAhead: ToolGoAhead {
        switch self {
        case .ask: .always
        case .allow: .never
        case .deny: .denied
        }
    }

    /// The choice's name in Settings > Tools.
    public var title: String {
        switch self {
        case .ask: "Ask each time"
        case .allow: "Always allow"
        case .deny: "Always deny"
        }
    }
}

/// What the app decides about MCP servers, kept in `mcp-settings.json` apart from the servers
/// file the owner edits, as `skill-settings.json` is for skills: which servers are off (each is
/// on unless it is listed), and each tool's go-ahead where the owner has set one.
///
/// ```json
/// {"disabled": ["notes"], "goAhead": {"weather": {"get_forecast": "dont-ask", "add_alert": "deny"}}}
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
            // Read value by value, so one this build does not know leaves the rest in place.
            let raw = (try? container.decodeIfPresent([String: [String: String]].self, forKey: .goAhead)) ?? [:]
            goAhead = raw.compactMapValues { tools in
                let known = tools.compactMapValues(MCPGoAhead.init(rawValue:))
                return known.isEmpty ? nil : known
            }
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

    /// Posted with the store as its object after a tool's go-ahead changes, from any thread, so
    /// Settings can show a change made from the go-ahead card.
    public static let goAheadDidChange = Notification.Name("MCPSettingsStore.goAheadDidChange")

    /// Sets a tool's go-ahead. Setting it to its default removes the override, so a later
    /// change in the server's read-only mark is followed.
    public func setGoAhead(_ value: MCPGoAhead, server: String, tool: String, readOnly: Bool) throws {
        // Posted even when the file could not be written, since the change holds in memory.
        defer { NotificationCenter.default.post(name: Self.goAheadDidChange, object: self) }
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
