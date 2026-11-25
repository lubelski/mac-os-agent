import CryptoKit
import Foundation

/// One change to a memory file, as the journal keeps it.
public struct MemoryJournalEntry: Codable, Sendable, Equatable, Identifiable {
    public enum Operation: String, Codable, Sendable {
        case create
        case replace
        case remove
        case append
        case setDescription = "set_description"
        case rename
        /// A topic file moved into the archive. The entry for the topic file's path has no
        /// content and names where it went. A second entry holds the archived copy's content.
        case archive
        /// An archived file moved back. As with `archive`, one entry for each path.
        case unarchive
        /// The whole file written from Settings.
        case edit
        /// An earlier revision written back. `restoredFrom` names it.
        case restore
        /// A file found changed, or new, with a hash the journal did not have.
        case outsideEdit = "outside_edit"
        /// A file found gone without the app removing it.
        case outsideRemoval = "outside_removal"

        /// As Settings shows it.
        public var title: String {
            switch self {
            case .create: "Created"
            case .replace: "Replaced text"
            case .remove: "Removed text"
            case .append: "Added"
            case .setDescription: "Changed description"
            case .rename: "Renamed"
            case .archive: "Archived"
            case .unarchive: "Moved out of the archive"
            case .edit: "Edited"
            case .restore: "Restored"
            case .outsideEdit: "Changed"
            case .outsideRemoval: "Removed"
            }
        }
    }

    public var id: UUID
    public var date: Date
    /// The file's path inside the memory folder: `core.md`, `travel-plans.md`, or
    /// `archive/travel-plans.md`.
    public var file: String
    public var operation: Operation
    /// The file's whole text after the change. Nil when the file is gone from this path.
    public var content: String?
    /// A hash of `content`, to tell when the file on disk is no longer what was recorded.
    public var hash: String?
    /// "episode", "settings", or "outside".
    public var cause: String
    /// The episode the agent made the change in, when it did.
    public var episode: UUID?
    /// For a rename, the path it had before.
    public var renamedFrom: String?
    /// For an archive, where the file went.
    public var archivedAs: String?
    /// For a move out of the archive, where the file went.
    public var restoredAs: String?
    /// For a restore, the entry whose content was written back.
    public var restoredFrom: UUID?

    public init(id: UUID = UUID(), date: Date, file: String, operation: Operation, content: String?, cause: MemoryCause) {
        self.id = id
        self.date = date
        self.file = file
        self.operation = operation
        self.content = content
        self.hash = content.map(MemoryJournal.hash)
        switch cause {
        case .episode(let episode):
            self.cause = "episode"
            self.episode = episode
        case .settings: self.cause = "settings"
        case .outside: self.cause = "outside"
        }
    }

    public var memoryCause: MemoryCause {
        switch cause {
        case "settings": .settings
        case "outside": .outside
        default: .episode(episode)
        }
    }

    /// The file's name without the folder or `.md`, as the notice says it.
    public var displayName: String {
        var name = file
        if name.hasPrefix(MemoryLayout.archiveFolderName + "/") { name.removeFirst(MemoryLayout.archiveFolderName.count + 1) }
        if name.hasSuffix(".md") { name.removeLast(3) }
        return name
    }
}

/// The memory folder's history: `journal.jsonl`, one `MemoryJournalEntry` per line, only ever
/// added to. It is written the way the thread file is, so a line cut short by a crash leaves
/// the rest readable. Nothing is ever removed from it. A restore is a new entry.
///
/// Reading is plain: the whole file is read each time. It holds a full copy of a file per
/// change, which stays small for a long time. `planning/decided.md` says what to do if it grows.
public struct MemoryJournal: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Every entry, oldest first. A line that cannot be read is skipped.
    public func entries() -> [MemoryJournalEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(MemoryJournalEntry.self, from: Data($0)) }
    }

    /// The entries for the file now at this path, oldest first. The history follows the file
    /// back through a rename, an archive, or a move out of the archive, and starts at the
    /// entry that created it.
    public func history(of path: String) -> [MemoryJournalEntry] {
        let all = entries()
        var current = path
        var collected: [MemoryJournalEntry] = []
        for entry in all.reversed() {
            if entry.file == current {
                collected.append(entry)
                if entry.operation == .create { break }
                if entry.operation == .rename, let from = entry.renamedFrom { current = from }
            } else if entry.archivedAs == current || entry.restoredAs == current {
                collected.append(entry)
                current = entry.file
            }
        }
        return collected.reversed()
    }

    /// The hash the journal last recorded for each path it knows, or nil for a path whose file
    /// is gone: archived, renamed away, or removed.
    func latestHashes() -> [String: String?] {
        var hashes: [String: String?] = [:]
        for entry in entries() {
            hashes[entry.file] = .some(entry.hash)
            if let from = entry.renamedFrom { hashes[from] = .some(nil) }
        }
        return hashes
    }

    /// Adds an entry at the end and writes it to disk before returning.
    public func append(_ entry: MemoryJournalEntry) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var line = try encoder.encode(entry)
        line.append(0x0A)
        let manager = FileManager.default
        try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: fileURL.plainPath) {
            manager.createFile(atPath: fileURL.plainPath, contents: nil)
        }
        let handle = try FileHandle(forUpdating: fileURL)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        // A line cut short by a crash has no newline. Start a fresh line so this one stays readable.
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1) != Data([0x0A]) { line.insert(0x0A, at: 0) }
            try handle.seekToEnd()
        }
        try handle.write(contentsOf: line)
        try handle.synchronize()
    }
}
