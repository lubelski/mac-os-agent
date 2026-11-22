import Foundation
import Synchronization

/// Where a conversation's entries live. The agent loop works the same against either kind:
///
/// - `ThreadStore` is the one kept thread, a file in Application Support with a search index.
/// - `InMemoryThreadStore` is an incognito window's conversation. It has no file and no
///   index, so nothing in it can reach the disk, and it is gone when the app lets go of it.
public protocol ThreadStorage: Actor {
    var contents: ThreadContents { get }
    /// Adds an entry at the end, with the given id, and returns it.
    @discardableResult
    func append(_ item: ThreadItem, date: Date, id: UUID) throws -> ThreadEntry
}

extension ThreadStorage {
    public var entries: [ThreadEntry] { contents.entries }
    public var episodes: [Episode] { contents.episodes }
    public var currentEpisode: Episode? { contents.currentEpisode }

    @discardableResult
    public func append(_ item: ThreadItem) throws -> ThreadEntry {
        try append(item, date: Date(), id: UUID())
    }

    /// Adds an entry at the end and returns it.
    @discardableResult
    public func append(_ item: ThreadItem, date: Date) throws -> ThreadEntry {
        try append(item, date: date, id: UUID())
    }

    /// Calls in the current episode that have no result yet, oldest first. This happens when the
    /// app quit or the task was stopped while a tool was running. Calls in earlier episodes are
    /// left alone, since the model never sees them again.
    public func unansweredToolCalls() -> [ThreadItem.ToolCall] {
        let entries = contents.currentEpisodeEntries
        var answered = Set<String>()
        for entry in entries {
            if case .toolResult(let result) = entry.item { answered.insert(result.callID) }
        }
        return entries.compactMap { entry in
            if case .toolCall(let call) = entry.item, !answered.contains(call.callID) { return call }
            return nil
        }
    }
}

/// The one thread, kept as an append-only JSON Lines file. Each line is a `ThreadEntry`.
///
/// Entries are only ever added at the end. Nothing rewrites earlier lines, so the request
/// prefix the model sees stays the same from one turn to the next.
public actor ThreadStore: ThreadStorage {
    public nonisolated let fileURL: URL
    public private(set) var contents: ThreadContents
    /// Lines that could not be read on load, such as a line cut short by a crash. They are
    /// left in the file and skipped.
    public private(set) var unreadableLineCount: Int
    /// The full text index of the thread, once it is open and caught up. Nil before then, when
    /// the store was made without one, or when the index could not be opened. Search then
    /// reads the entries directly.
    private var index: HistoryIndex?
    /// Where the index is handed over when it has been opened and caught up off the actor.
    private let indexHandoff: HistoryIndexHandoff?
    /// Opens the index and catches it up with the thread as it was loaded, or rebuilds it.
    private let indexBuild: Task<Void, Never>?

    /// Loads the thread. The search index is opened and brought up to date in the background,
    /// so opening the store never waits on it.
    ///
    /// - Parameter searchIndexURL: Where to keep the search index. It is brought up to date
    ///   with the thread on open, and rebuilt from it when it is missing or does not match.
    ///   Until that is done, search reads the entries directly.
    public init(fileURL: URL, searchIndexURL: URL? = nil) throws {
        self.fileURL = fileURL
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let (entries, unreadable) = try Self.load(fileURL)
        let contents = ThreadContents(entries: entries)
        self.contents = contents
        self.unreadableLineCount = unreadable
        if let searchIndexURL {
            // The index covers the entries as they are now. Entries appended while it builds
            // are added when the store takes the index over, each exactly once.
            let handoff = HistoryIndexHandoff()
            let loaded = contents.entries
            indexHandoff = handoff
            indexBuild = Task.detached(priority: .utility) {
                handoff.deposit(try? HistoryIndex(fileURL: searchIndexURL, syncingWith: loaded))
            }
        } else {
            indexHandoff = nil
            indexBuild = nil
        }
    }

    /// Appends an item and writes it to disk before returning.
    @discardableResult
    public func append(_ item: ThreadItem, date: Date, id: UUID) throws -> ThreadEntry {
        let entry = ThreadEntry(id: id, date: date, item: item)
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
        contents.add(entry)
        // The thread file is the record. An index that fails to take the entry is rebuilt from
        // the thread on the next launch. One that is still building takes it when it is ready.
        adoptSearchIndexIfReady()
        index?.add(entry, position: contents.entries.count - 1)
        return entry
    }

    /// Whether search runs on the index rather than reading every entry. False while the index
    /// is still being brought up to date.
    public var hasSearchIndex: Bool {
        adoptSearchIndexIfReady()
        return index != nil
    }

    /// Waits until the index is ready, or has failed to open, and says whether search runs on it.
    @discardableResult
    public func waitForSearchIndex() async -> Bool {
        await indexBuild?.value
        return hasSearchIndex
    }

    /// Takes the index over once it has been built, and adds the entries appended meanwhile.
    private func adoptSearchIndexIfReady() {
        guard index == nil, let built = indexHandoff?.take() else { return }
        built.catchUp(with: contents.entries)
        index = built
    }

    /// Searches the whole thread for the words in `query`, best matches first.
    /// - Parameter excludedEpisode: An episode to leave out, such as the one the model already sees.
    public func search(_ query: String, limit: Int = 8, excludingEpisode excludedEpisode: UUID? = nil) -> [HistoryMatch] {
        let excluded = excludedEpisode.flatMap { id in contents.episodes.last { $0.id == id }?.range }
        let positions: [Int]
        adoptSearchIndexIfReady()
        if let index, let found = index.search(query, limit: limit, excluding: excluded) {
            positions = found
        } else {
            positions = HistorySearchText.scan(contents.entries, for: query, limit: limit, excluding: excluded)
        }
        return positions.compactMap { position in
            guard position < contents.entries.count, let episode = contents.episode(containing: position) else { return nil }
            return HistoryMatch(position: position, entry: contents.entries[position], episode: episode)
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

/// An incognito conversation: the same interface as the kept thread, held only in memory. It has
/// no file, no index, and no way to be given one, so nothing written to it reaches the disk.
/// Letting go of the store lets go of the conversation.
public actor InMemoryThreadStore: ThreadStorage {
    public private(set) var contents = ThreadContents()

    public init() {}

    @discardableResult
    public func append(_ item: ThreadItem, date: Date, id: UUID) -> ThreadEntry {
        let entry = ThreadEntry(id: id, date: date, item: item)
        contents.add(entry)
        return entry
    }
}

/// Hands a search index from the task that built it to the store that uses it. The index is
/// used by one side at a time: the builder until it deposits it, the store after it takes it.
final class HistoryIndexHandoff: Sendable {
    private let slot = Mutex<HistoryIndex?>(nil)

    func deposit(_ index: HistoryIndex?) {
        slot.withLock { $0 = index }
    }

    /// The index once it has been deposited, taken only once. Nil before then, and after.
    func take() -> HistoryIndex? {
        slot.withLock { slot in
            defer { slot = nil }
            return slot
        }
    }
}

/// An entry that matched a search of the thread.
public struct HistoryMatch: Sendable, Equatable {
    /// Where the entry sits in the thread.
    public var position: Int
    public var entry: ThreadEntry
    public var episode: Episode
}
