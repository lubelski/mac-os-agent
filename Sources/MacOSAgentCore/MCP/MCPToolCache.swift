import CryptoKit
import Foundation

/// Each MCP server's last tool list, kept in `mcp-tools-cache.json`. The tool list the model
/// sees is built from it at launch, so launch never waits for a server. A server that connects
/// with a list that differs from it writes its new list here, and those tools join at the next
/// launch.
public struct MCPToolCache: Sendable, Equatable, Codable {
    public struct Entry: Sendable, Equatable, Codable {
        public var tools: [MCPToolInfo]
        public var updated: Date
        /// What the server said about itself when it last connected. Missing in files from
        /// before it was kept, and for a server that said nothing.
        public var server: MCPServerInfo?

        public init(tools: [MCPToolInfo], updated: Date = Date(), server: MCPServerInfo? = nil) {
            self.tools = tools
            self.updated = updated
            self.server = server
        }
    }

    public var servers: [String: Entry]

    public init(servers: [String: Entry] = [:]) {
        self.servers = servers
    }

    /// A missing or unreadable file is an empty cache. The servers refill it when they connect.
    public static func read(from file: URL = AgentPaths.mcpToolsCacheFile) -> MCPToolCache {
        guard let data = try? Data(contentsOf: file) else { return MCPToolCache() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(MCPToolCache.self, from: data)) ?? MCPToolCache()
    }

    public func write(to file: URL = AgentPaths.mcpToolsCacheFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: file, options: .atomic)
    }

    /// The tool lists that join at launch: each server in the file that can be used, is on, and
    /// has a cached list. A server that is new, or has never connected, has none yet.
    public func launchLists(config: MCPServerConfig, settings: MCPSettingsStore) -> [String: [MCPToolInfo]] {
        var lists: [String: [MCPToolInfo]] = [:]
        for entry in config.usableServers where settings.isEnabled(entry.name) {
            if let cached = servers[entry.name] { lists[entry.name] = cached.tools }
        }
        return lists
    }
}

/// How a server's tools are named for the model: `<server>__<tool>`.
///
/// The Responses API takes a function name of letters, digits, underscores, and hyphens, at
/// most 64 characters. A server's name is checked against `MCPServerConfig.problem(withName:)`,
/// which keeps it to 32 of those. A tool's own name is used as it is when it fits. A character
/// outside those becomes an underscore, and a name that is then too long or the same as
/// another's is shortened and given a short hash of the tool's own name, so it stays the same
/// from launch to launch.
public enum MCPToolNaming {
    public static let separator = "__"
    public static let limit = 64

    /// The full name for each tool, by the tool's name on its server. Tools whose names fit as
    /// they are keep them first, so another tool's odd name never takes one of theirs.
    public static func names(server: String, tools: [String]) -> [String: String] {
        let prefix = server + separator
        var used = Set<String>()
        var result: [String: String] = [:]
        let unique = Array(Set(tools)).sorted()
        for tool in unique where sanitized(tool) == tool && prefix.count + tool.count <= limit {
            let name = prefix + tool
            used.insert(name)
            result[tool] = name
        }
        for tool in unique where result[tool] == nil {
            let hash = shortHash(tool)
            let room = max(1, limit - prefix.count - hash.count - 1)
            var name = prefix + String(sanitized(tool).prefix(room)) + "_" + hash
            var counter = 2
            while used.contains(name) {
                name = prefix + String(sanitized(tool).prefix(room - 2)) + "_" + hash + String(counter)
                counter += 1
            }
            used.insert(name)
            result[tool] = name
        }
        return result
    }

    static func sanitized(_ name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let text = String(name.map { allowed.contains($0) ? $0 : "_" })
        return text.isEmpty ? "tool" : text
    }

    static func shortHash(_ name: String) -> String {
        SHA256.hash(data: Data(name.utf8)).prefix(3).map { String(format: "%02x", $0) }.joined()
    }

    /// True when a name could have been made here: within the limit and of allowed characters.
    public static func isValidModelName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= limit && sanitized(name) == name
    }
}
