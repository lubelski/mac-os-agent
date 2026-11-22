import Foundation

/// Where the agent keeps what it owns: `~/Library/Application Support/mac-os-agent/`.
public enum AgentPaths {
    public static let folderName = "mac-os-agent"

    public static var applicationSupport: URL {
        URL.applicationSupportDirectory.appending(path: folderName, directoryHint: .isDirectory)
    }

    public static var threadFile: URL {
        applicationSupport.appending(path: "thread.jsonl")
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
