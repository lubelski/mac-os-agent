import Foundation

/// Where the agent keeps what it owns: `~/Library/Application Support/mac-os-agent/`.
public enum AgentPaths {
    public static let folderName = "mac-os-agent"

    /// The launch argument that points the app at another folder, for checking a build by hand
    /// without touching the real thread: `--data-folder /tmp/somewhere`.
    public static let dataFolderArgument = "--data-folder"

    public static var applicationSupport: URL {
        if let folder = dataFolder(from: CommandLine.arguments) { return folder }
        return URL.applicationSupportDirectory.appending(path: folderName, directoryHint: .isDirectory)
    }

    static func dataFolder(from arguments: [String]) -> URL? {
        guard let index = arguments.firstIndex(of: dataFolderArgument), index + 1 < arguments.count else { return nil }
        return URL(filePath: (arguments[index + 1] as NSString).expandingTildeInPath, directoryHint: .isDirectory)
    }

    public static var threadFile: URL {
        applicationSupport.appending(path: "thread.jsonl")
    }

    /// The full text index that search over past episodes reads. A copy of the thread that is
    /// rebuilt from it whenever it is missing or out of step, so it is always safe to delete.
    public static var historyIndexFile: URL {
        applicationSupport.appending(path: "history-index.sqlite")
    }

    /// The agent's standing instructions as the person edited them. Missing until the first edit.
    public static var instructionsFile: URL {
        applicationSupport.appending(path: "instructions.md")
    }

    /// The agent's memory: `core.md`, topic files, `archive/`, and `journal.jsonl`. See
    /// `MemoryLayout`. Missing until the first change. Private: never logged, and Debugging
    /// shows only counts and sizes.
    public static var memoryFolder: URL {
        applicationSupport.appending(path: "memory", directoryHint: .isDirectory)
    }

    /// One folder per skill, each with a `SKILL.md`.
    public static var skillsFolder: URL {
        applicationSupport.appending(path: "skills", directoryHint: .isDirectory)
    }

    /// One JSON file per theme the owner or the agent made. Built-in themes are not here.
    public static var themesFolder: URL {
        applicationSupport.appending(path: "themes", directoryHint: .isDirectory)
    }

    /// One JSON file per quick action: a stored tool call, or a few, that the instant row runs.
    public static var quickActionsFolder: URL {
        applicationSupport.appending(path: quickActionsFolderName, directoryHint: .isDirectory)
    }

    public static let quickActionsFolderName = "quick-actions"
    /// What the quick actions folder was called before. See `QuickActionLibrary.moveFolderFromOldName`.
    public static let oldActionsFolderName = "actions"

    /// Token counts for each model request, one JSON line per request. No message content.
    public static var usageLogFile: URL {
        applicationSupport.appending(path: "usage.jsonl")
    }

    /// Which skills are turned off.
    public static var skillSettingsFile: URL {
        applicationSupport.appending(path: "skill-settings.json")
    }

    /// The MCP servers the owner listed, in the `mcpServers` shape. The owner edits it. It can
    /// hold tokens, so the app keeps it readable only by the owner. See `MCPServerConfig`.
    public static var mcpServersFile: URL {
        applicationSupport.appending(path: "mcp-servers.json")
    }

    /// What the app decides about each MCP server: whether it is on, and each tool's go-ahead.
    public static var mcpSettingsFile: URL {
        applicationSupport.appending(path: "mcp-settings.json")
    }

    /// Each MCP server's last tool list, which the tool list is built from at launch.
    public static var mcpToolsCacheFile: URL {
        applicationSupport.appending(path: "mcp-tools-cache.json")
    }

    /// What the owner has opened through instant actions, for ranking. Never written from an
    /// incognito window.
    public static var instantActionHistoryFile: URL {
        applicationSupport.appending(path: "instant-actions.json")
    }

    public static var installationIDFile: URL {
        applicationSupport.appending(path: "installation-id")
    }

    /// A random UUID made the first time the app runs on this Mac and kept afterwards.
    /// OpenAI uses it to tell installations apart at sign-in.
    public static func installationID(file: URL = installationIDFile) -> UUID {
        if let text = try? String(contentsOf: file, encoding: .utf8),
           let id = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines))
        {
            return id
        }
        let id = UUID()
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? id.uuidString.lowercased().write(to: file, atomically: true, encoding: .utf8)
        return id
    }
}
