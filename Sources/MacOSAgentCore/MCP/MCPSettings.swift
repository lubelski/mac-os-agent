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
/// on unless it is listed), each tool's go-ahead where the owner has set one, and the names
/// Settings shows for a server or a tool where the owner has set one in place of the default.
///
/// ```json
/// {"disabled": ["notes"], "goAhead": {"weather": {"get_forecast": "dont-ask", "add_alert": "deny"}},
///  "serverNames": {"weather": "Forecasts"}, "toolNames": {"weather": {"get_forecast": "Forecast"}}}
/// ```
///
/// The names are for people only. The model is always sent the server's and the tool's literal
/// names, so a change to one changes nothing in a request.
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
        /// A server's display name by its name, where the owner set one.
        var serverNames: [String: String] = [:]
        /// By server, then by the tool's name on its server.
        var toolNames: [String: [String: String]] = [:]

        init() {}

        enum CodingKeys: String, CodingKey {
            case disabled, goAhead, serverNames, toolNames
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            disabled = (try? container.decodeIfPresent([String].self, forKey: .disabled)) ?? []
            // Read value by value, so one this build does not know leaves the rest in place.
            let raw = (try? container.decodeIfPresent([String: [String: String]].self, forKey: .goAhead)) ?? [:]
            goAhead = raw.compactMapValues { tools in
                let known = tools.compactMapValues(MCPGoAhead.init(rawValue:))
                return known.isEmpty ? nil : known
            }
            // Files from before display names have neither key, and read as no names set.
            serverNames = (try? container.decodeIfPresent([String: String].self, forKey: .serverNames)) ?? [:]
            toolNames = (try? container.decodeIfPresent([String: [String: String]].self, forKey: .toolNames)) ?? [:]
        }

        /// The names are written only once one is set, so a file with none stays as it was.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(disabled, forKey: .disabled)
            try container.encode(goAhead, forKey: .goAhead)
            if !serverNames.isEmpty { try container.encode(serverNames, forKey: .serverNames) }
            if !toolNames.isEmpty { try container.encode(toolNames, forKey: .toolNames) }
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

    // MARK: - Display names

    /// Posted with the store as its object after a server's or a tool's display name changes.
    public static let namesDidChange = Notification.Name("MCPSettingsStore.namesDidChange")

    /// The name the owner set for a server, or nil when they have not.
    public func serverNameOverride(_ server: String) -> String? {
        state.withLock { $0.serverNames[server] }
    }

    /// The server's name in Settings: the owner's, or its name in the file made readable.
    public func serverDisplayName(_ server: String) -> String {
        serverNameOverride(server) ?? HumanizedName.from(server)
    }

    /// Sets the server's display name. An empty name, or the default, removes the override,
    /// so the default shows again.
    public func setServerDisplayName(_ name: String?, server: String) throws {
        defer { NotificationCenter.default.post(name: Self.namesDidChange, object: self) }
        let value = Self.override(name, defaultName: HumanizedName.from(server))
        try change { $0.serverNames[server] = value }
    }

    /// The name the owner set for a tool, by its name on its server, or nil when they have not.
    public func toolNameOverride(server: String, tool: String) -> String? {
        state.withLock { $0.toolNames[server]?[tool] }
    }

    /// The tool's name in Settings: the owner's, or its name on its server made readable.
    public func toolDisplayName(server: String, tool: String) -> String {
        toolNameOverride(server: server, tool: tool) ?? HumanizedName.from(tool)
    }

    /// Sets a tool's display name. An empty name, or the default, removes the override.
    public func setToolDisplayName(_ name: String?, server: String, tool: String) throws {
        defer { NotificationCenter.default.post(name: Self.namesDidChange, object: self) }
        let value = Self.override(name, defaultName: HumanizedName.from(tool))
        try change { settings in
            var tools = settings.toolNames[server] ?? [:]
            tools[tool] = value
            settings.toolNames[server] = tools.isEmpty ? nil : tools
        }
    }

    /// The override to keep for a name typed in Settings: nil for an empty one, or for the
    /// default itself, so a later change in the default is followed.
    static func override(_ name: String?, defaultName: String) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name != defaultName else { return nil }
        return name
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
