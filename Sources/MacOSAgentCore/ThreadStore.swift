import Foundation

/// The one thread, kept as an append-only JSON Lines file. Each line is a `ThreadEntry`.
///
/// Entries are only ever added at the end. Nothing rewrites earlier lines, so the request
/// prefix the model sees stays the same from one turn to the next.
public actor ThreadStore {
    public let fileURL: URL
    public private(set) var entries: [ThreadEntry]
    /// Lines that could not be read on load, such as a line cut short by a crash. They are
    /// left in the file and skipped.
    public private(set) var unreadableLineCount: Int

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let (entries, unreadable) = try Self.load(fileURL)
        self.entries = entries
        self.unreadableLineCount = unreadable
    }

    /// Appends an item and writes it to disk before returning.
    @discardableResult
    public func append(_ item: ThreadItem, date: Date = Date()) throws -> ThreadEntry {
        let entry = ThreadEntry(date: date, item: item)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var line = try encoder.encode(entry)
        line.append(0x0A)

        let manager = FileManager.default
        if !manager.fileExists(atPath: fileURL.path) {
            manager.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try FileHandle(forUpdating: fileURL)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        // A line cut short by a crash has no newline. Start a fresh line so this one stays readable.
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1) != Data([0x0A]) {
                line.insert(0x0A, at: 0)
            }
            try handle.seekToEnd()
        }
        try handle.write(contentsOf: line)
        try handle.synchronize()
        entries.append(entry)
        return entry
    }

    /// Calls that have no result yet, oldest first. This happens when the app quit or the task
    /// was stopped while a tool was running.
    public func unansweredToolCalls() -> [ThreadItem.ToolCall] {
        var answered = Set<String>()
        for entry in entries {
            if case .toolResult(let result) = entry.item { answered.insert(result.callID) }
        }
        return entries.compactMap { entry in
            if case .toolCall(let call) = entry.item, !answered.contains(call.callID) { return call }
            return nil
        }
    }

    private static func load(_ url: URL) throws -> ([ThreadEntry], Int) {
        guard FileManager.default.fileExists(atPath: url.path) else { return ([], 0) }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var entries: [ThreadEntry] = []
        var unreadable = 0
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let entry = try? decoder.decode(ThreadEntry.self, from: Data(line)) {
                entries.append(entry)
            } else {
                unreadable += 1
            }
        }
        return (entries, unreadable)
    }
}
