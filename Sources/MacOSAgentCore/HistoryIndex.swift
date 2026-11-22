import Foundation
import SQLite3

/// What search reads from each entry: the owner's messages, the agent's replies, and the
/// commands that ran. Command output is left out, since it is long and mostly noise.
enum HistorySearchText {
    enum Kind: String {
        case owner
        case agent
        case command
    }

    static func of(_ item: ThreadItem) -> (kind: Kind, text: String)? {
        switch item {
        case .userMessage(let text):
            return (.owner, text)
        case .assistantMessage(let message):
            return message.text.isEmpty ? nil : (.agent, message.text)
        case .toolCall(let call):
            return (.command, command(of: call))
        case .toolResult, .providerItem, .episodeStart:
            return nil
        }
    }

    /// The command a call ran, or the tool's name and arguments for a tool that is not the shell.
    static func command(of call: ThreadItem.ToolCall) -> String {
        if let command = JSONValue.parse(call.arguments)?["command"]?.stringValue { return command }
        return "\(call.name) \(call.arguments)"
    }

    /// The words of a query, lowercased, at most twelve of them.
    static func words(_ query: String) -> [String] {
        Array(query.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .prefix(12))
    }

    /// Search without an index: newest first, every word must appear.
    static func scan(_ entries: [ThreadEntry], for query: String, limit: Int, excluding excluded: Range<Int>?) -> [Int] {
        let words = words(query)
        guard !words.isEmpty, limit > 0 else { return [] }
        var found: [Int] = []
        for position in entries.indices.reversed() {
            if let excluded, excluded.contains(position) { continue }
            guard let text = of(entries[position].item)?.text.lowercased() else { continue }
            if words.allSatisfy({ text.contains($0) }) {
                found.append(position)
                if found.count == limit { break }
            }
        }
        return found
    }
}

/// A full text index of the thread, in an SQLite file beside it in Application Support.
///
/// The thread file is the record and the index is only a copy for fast search. It notes how
/// many entries it covers and the id of the last one, so on open it adds what it is missing,
/// or starts over when it does not match the thread. Deleting the file is always safe.
///
/// It belongs to one `ThreadStore` and is only used from inside that actor.
final class HistoryIndex {
    static let formatVersion = "1"

    private var database: OpaquePointer?

    init(fileURL: URL, syncingWith entries: [ThreadEntry]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(fileURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(database)
            throw IndexError.cannotOpen
        }
        try execute("""
            CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE VIRTUAL TABLE IF NOT EXISTS passages USING fts5(
                body, kind UNINDEXED, position UNINDEXED,
                tokenize = 'porter unicode61 remove_diacritics 2');
            """)
        try sync(with: entries)
    }

    deinit {
        sqlite3_close(database)
    }

    enum IndexError: Error {
        case cannotOpen
        case statement(String)
    }

    /// The number of entries the index covers.
    private(set) var coveredCount = 0

    /// Adds what the index is missing, or rebuilds it when it does not match the thread.
    private func sync(with entries: [ThreadEntry]) throws {
        let version = try value(for: "version")
        let count = Int(try value(for: "count") ?? "") ?? 0
        let lastID = try value(for: "last_id")
        var start = count
        let matches = version == Self.formatVersion
            && count <= entries.count
            && (count == 0 || entries[count - 1].id.uuidString == lastID)
        if !matches {
            try execute("DELETE FROM passages;")
            start = 0
        }
        try execute("BEGIN;")
        do {
            for position in start..<entries.count {
                try insert(entries[position], position: position)
            }
            try setState(count: entries.count, lastID: entries.last?.id)
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
        coveredCount = entries.count
    }

    /// Adds one new entry at the end of the thread. A failure leaves the index behind the
    /// thread, and the next open catches it up.
    func add(_ entry: ThreadEntry, position: Int) {
        guard position == coveredCount else { return }
        do {
            try execute("BEGIN;")
            try insert(entry, position: position)
            try setState(count: position + 1, lastID: entry.id)
            try execute("COMMIT;")
            coveredCount = position + 1
        } catch {
            try? execute("ROLLBACK;")
        }
    }

    /// The positions of the best matches, best first. Every word must match, as a word or the
    /// start of one. When that finds nothing, any word may match. Nil when the search failed.
    func search(_ query: String, limit: Int, excluding excluded: Range<Int>?) -> [Int]? {
        let words = HistorySearchText.words(query)
        guard !words.isEmpty, limit > 0 else { return [] }
        let terms = words.map { "\"\($0)\"*" }
        guard let all = run(match: terms.joined(separator: " "), limit: limit, excluding: excluded) else { return nil }
        if !all.isEmpty || words.count == 1 { return all }
        return run(match: terms.joined(separator: " OR "), limit: limit, excluding: excluded)
    }

    private func run(match: String, limit: Int, excluding excluded: Range<Int>?) -> [Int]? {
        let sql = """
            SELECT position FROM passages
            WHERE passages MATCH ?1 AND NOT (position >= ?2 AND position < ?3)
            ORDER BY bm25(passages), position DESC LIMIT ?4;
            """
        guard let statement = try? prepare(sql) else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, match, -1, Self.transient)
        sqlite3_bind_int64(statement, 2, Int64(excluded?.lowerBound ?? -1))
        sqlite3_bind_int64(statement, 3, Int64(excluded?.upperBound ?? -1))
        sqlite3_bind_int64(statement, 4, Int64(limit))
        var positions: [Int] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                positions.append(Int(sqlite3_column_int64(statement, 0)))
            } else if step == SQLITE_DONE {
                return positions
            } else {
                return nil
            }
        }
    }

    // MARK: - SQLite

    private static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    private func insert(_ entry: ThreadEntry, position: Int) throws {
        guard let (kind, text) = HistorySearchText.of(entry.item) else { return }
        let statement = try prepare("INSERT INTO passages (body, kind, position) VALUES (?1, ?2, ?3);")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, text, -1, Self.transient)
        sqlite3_bind_text(statement, 2, kind.rawValue, -1, Self.transient)
        sqlite3_bind_int64(statement, 3, Int64(position))
        guard sqlite3_step(statement) == SQLITE_DONE else { throw IndexError.statement(message) }
    }

    private func setState(count: Int, lastID: UUID?) throws {
        try setValue(Self.formatVersion, for: "version")
        try setValue(String(count), for: "count")
        try setValue(lastID?.uuidString ?? "", for: "last_id")
    }

    private func value(for key: String) throws -> String? {
        let statement = try prepare("SELECT value FROM state WHERE key = ?1;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    private func setValue(_ value: String, for key: String) throws {
        let statement = try prepare("INSERT OR REPLACE INTO state (key, value) VALUES (?1, ?2);")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, Self.transient)
        sqlite3_bind_text(statement, 2, value, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw IndexError.statement(message) }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            throw IndexError.statement(message)
        }
        return statement
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw IndexError.statement(message) }
    }

    private var message: String {
        database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown"
    }
}
