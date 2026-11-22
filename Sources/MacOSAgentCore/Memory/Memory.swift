import CryptoKit
import Foundation
import Synchronization

/// A memory: a short fact in plain words that the agent knows in every episode, such as the
/// owner's home address or how they like a thing done.
///
/// Memories live in one Markdown file, `memory.md` in Application Support, one per list item,
/// with the day it was saved in front:
///
/// ```markdown
/// # Memory
///
/// <!-- What the agent knows in every episode. One fact per list item. Edit freely. -->
///
/// - 2026-11-20: The person's home address is 12 Example Lane, Springfield.
/// - 2026-11-21: They like temperatures in Celsius.
/// - Their backup drive is called Attic.
/// ```
///
/// The file is the owner's to open and fix in any editor. Reading it never fails and never
/// drops a line of theirs: every list item is a memory, the date is optional, an indented line
/// after an item continues it, and any other line of text that is not a heading or a comment
/// is a memory too. The app's own changes replace or remove only the lines of the memory they
/// touch and add new ones at the end, so headings, comments, and the rest stay as written.
public struct Memory: Sendable, Equatable, Hashable, Identifiable {
    /// Six hex digits made from the text, so a memory keeps its id while others are added or
    /// removed, and the ids in the instructions stay valid through an episode.
    public var id: String
    public var text: String
    /// The day it was saved, as `yyyy-MM-dd`, or nil when the line has none.
    public var saved: String?
    /// The lines of the file it was read from.
    public var lines: Range<Int>

    public init(id: String, text: String, saved: String?, lines: Range<Int>) {
        self.id = id
        self.text = text
        self.saved = saved
        self.lines = lines
    }

    /// The saved day as a date at the start of that day in the local calendar.
    public var savedDate: Date? { saved.flatMap(MemoryFile.date(from:)) }

    /// The memory as the file writes it: a list item, with its day when it has one.
    public var line: String {
        saved.map { "- \($0): \(text)" } ?? "- \(text)"
    }

    /// The memory as a short phrase for a notice: its first few words, with no closing period.
    public var shortText: String {
        var text = text
        if text.count > 60 {
            let cut = text.prefix(60)
            let words = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
            text = words.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) + "…"
        }
        while text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

/// The memory file as read: its lines exactly as they are, and the memories in them.
public struct MemoryFile: Sendable, Equatable {
    public var lines: [String]
    public var memories: [Memory]

    /// What a new file starts with.
    public static let header = """
        # Memory

        <!-- What the agent knows in every episode. One fact per list item, with the day it was \
        saved in front. Edit freely: the app reads this file again when it changes. -->

        """

    /// The longest memory, in characters. A memory is one sentence, not a document.
    public static let maximumLength = 500

    public init(text: String) {
        lines = text.isEmpty ? [] : text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        memories = Self.memories(in: lines)
    }

    /// The text of the file, with a newline at the end.
    public var text: String {
        lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    static func memories(in lines: [String]) -> [Memory] {
        struct Pending {
            var text: String
            var start: Int
            var end: Int
        }
        let itemMarker = /^\s{0,3}(?:[-*+]|\d{1,3}[.)])\s+(?:\[[ xX]\]\s+)?(.*)$/
        let datePrefix = /^(\d{4}-\d{2}-\d{2}):\s*(.*)$/
        var found: [Pending] = []
        var inComment = false
        var lastWasItem = false
        for (index, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if inComment {
                if trimmed.contains("-->") { inComment = false }
                lastWasItem = false
                continue
            }
            if trimmed.hasPrefix("<!--") {
                inComment = !trimmed.contains("-->")
                lastWasItem = false
                continue
            }
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) {
                lastWasItem = false
                continue
            }
            if let match = raw.wholeMatch(of: itemMarker) {
                let text = String(match.1).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else {
                    lastWasItem = false
                    continue
                }
                found.append(Pending(text: text, start: index, end: index + 1))
                lastWasItem = true
            } else if lastWasItem, raw.first?.isWhitespace == true, var last = found.popLast() {
                // An indented line under an item continues it.
                last.text += " " + trimmed
                last.end = index + 1
                found.append(last)
            } else {
                // A line of text with no list marker is kept as a memory, so nothing is lost.
                found.append(Pending(text: trimmed, start: index, end: index + 1))
                lastWasItem = true
            }
        }
        var seen: [String: Int] = [:]
        return found.map { pending in
            var text = AgentInstructions.singleLine(pending.text)
            var saved: String?
            if let match = text.wholeMatch(of: datePrefix), date(from: String(match.1)) != nil, !match.2.isEmpty {
                saved = String(match.1)
                text = String(match.2)
            }
            var id = identifier(for: text)
            seen[id, default: 0] += 1
            if let count = seen[id], count > 1 { id += "-\(count)" }
            return Memory(id: id, text: text, saved: saved, lines: pending.start..<pending.end)
        }
    }

    /// Six hex digits of a hash of the text, ignoring case and spacing.
    public static func identifier(for text: String) -> String {
        let normalized = AgentInstructions.singleLine(text).lowercased()
        return SHA256.hash(data: Data(normalized.utf8)).prefix(3).map { String(format: "%02x", $0) }.joined()
    }

    static func date(from text: String) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func day(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

public struct MemoryError: Error, Equatable, CustomStringConvertible, LocalizedError {
    public var description: String
    public init(_ description: String) { self.description = description }
    public var errorDescription: String? { description }
}

/// The memory file in Application Support, read and written whole. Reads never fail: a
/// missing or unreadable file is no memories.
public struct MemoryLibrary: Sendable {
    public static let didChangeNotification = Notification.Name("dev.lubelski.mac-os-agent.memoryDidChange")

    public let fileURL: URL
    /// Today, for the day a memory is saved. A parameter for tests.
    public let now: @Sendable () -> Date

    /// One change at a time, from the agent and from Settings, so neither writes over the other.
    private static let writing = Mutex(())

    public init(fileURL: URL = AgentPaths.memoryFile, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.now = now
    }

    public func file() -> MemoryFile {
        guard let data = try? Data(contentsOf: fileURL) else { return MemoryFile(text: "") }
        // A file that is not UTF-8 is read as Latin-1 rather than dropped.
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        return MemoryFile(text: text)
    }

    public func memories() -> [Memory] { file().memories }

    public func find(_ id: String) -> Memory? {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return memories().first { $0.id == id }
    }

    /// Adds a memory at the end of the file, saved today.
    @discardableResult
    public func add(_ text: String) throws -> Memory {
        let text = try Self.checked(text)
        return try Self.writing.withLock { _ in
            var file = file()
            if let existing = file.memories.first(where: { $0.id == MemoryFile.identifier(for: text) }) {
                throw MemoryError("That is already saved as \(existing.id).")
            }
            if file.lines.isEmpty {
                file.lines = MemoryFile.header.components(separatedBy: "\n")
                if file.lines.last == "" { file.lines.removeLast() }
                file.lines.append("")
            } else if file.lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == false,
                      file.memories.last?.lines.upperBound != file.lines.count
            {
                // Keep a new item from running into a paragraph or comment at the end.
                file.lines.append("")
            }
            file.lines.append(Memory(id: "", text: text, saved: MemoryFile.day(now()), lines: 0..<0).line)
            try write(file)
            return MemoryFile(text: file.text).memories.last!
        }
    }

    /// Replaces a memory's text in place and saves it as of today. Its id follows the new text.
    @discardableResult
    public func change(id: String, to text: String) throws -> (old: Memory, new: Memory) {
        let text = try Self.checked(text)
        return try Self.writing.withLock { _ in
            var file = file()
            guard let old = file.memories.first(where: { $0.id == id }) else { throw Self.missing(id) }
            let newID = MemoryFile.identifier(for: text)
            if newID != MemoryFile.identifier(for: old.text), let other = file.memories.first(where: { $0.id == newID }) {
                throw MemoryError("That is already saved as \(other.id). Remove \(old.id) instead.")
            }
            file.lines.replaceSubrange(old.lines, with: [Memory(id: "", text: text, saved: MemoryFile.day(now()), lines: 0..<0).line])
            try write(file)
            let new = MemoryFile(text: file.text).memories.first { $0.lines.lowerBound == old.lines.lowerBound }!
            return (old, new)
        }
    }

    /// Removes a memory's lines from the file.
    @discardableResult
    public func remove(id: String) throws -> Memory {
        try Self.writing.withLock { _ in
            var file = file()
            guard let memory = file.memories.first(where: { $0.id == id }) else { throw Self.missing(id) }
            file.lines.removeSubrange(memory.lines)
            try write(file)
            return memory
        }
    }

    private func write(_ file: MemoryFile) throws {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(file.text.utf8).write(to: fileURL, options: .atomic)
        } catch {
            throw MemoryError("Could not write the memory file: \(error.localizedDescription)")
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    private static func missing(_ id: String) -> MemoryError {
        MemoryError("There is no memory \(id). Call \(ReadMemoriesTool.name) for the list.")
    }

    /// The text as one line, or an error saying why it cannot be a memory.
    static func checked(_ text: String) throws -> String {
        let text = AgentInstructions.singleLine(text)
        if text.isEmpty { throw MemoryError("A memory needs some text.") }
        if text.count > MemoryFile.maximumLength {
            throw MemoryError("A memory is one sentence of at most \(MemoryFile.maximumLength) characters. This one has \(text.count).")
        }
        return text
    }
}

extension MemoryLibrary {
    /// The one line shown by the text field after a task that saved, changed, or removed a
    /// memory, such as "Remembered: The person's home address is 12 Example Lane.", or nil when
    /// none did. A memory whose text changed reads as one change, not a removal and an addition.
    public static func changeNotice(from before: [Memory], to after: [Memory]) -> String? {
        let oldIDs = Set(before.map(\.id))
        let newIDs = Set(after.map(\.id))
        var added = after.filter { !oldIDs.contains($0.id) }
        var removed = before.filter { !newIDs.contains($0.id) }
        // A change keeps the memory's place in the file, so it starts on the same line.
        var changed: [Memory] = []
        for memory in added {
            if let index = removed.firstIndex(where: { $0.lines.lowerBound == memory.lines.lowerBound }) {
                changed.append(memory)
                removed.remove(at: index)
            }
        }
        added.removeAll { memory in changed.contains(memory) }
        var sentences: [String] = []
        switch added.count {
        case 0: break
        case 1: sentences.append("Remembered: \(added[0].shortText).")
        default: sentences.append("Remembered \(added.count) things.")
        }
        switch changed.count {
        case 0: break
        case 1: sentences.append("Updated memory: \(changed[0].shortText).")
        default: sentences.append("Updated \(changed.count) memories.")
        }
        switch removed.count {
        case 0: break
        case 1: sentences.append("Forgot: \(removed[0].shortText).")
        default: sentences.append("Forgot \(removed.count) things.")
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }
}

/// The block of memories at the very end of the instructions.
public enum MemoryBlock {
    /// The most the block may hold, in characters. Over it, the most recently saved memories
    /// are kept and a line says how many are left out.
    public static let characterCap = 8_000

    public static let opening = "<memories>"
    public static let closing = "</memories>"

    static let introduction = """
        What the person asked you to remember, or told you about themselves, in earlier episodes. \
        Each line has the memory's id and the day it was saved. A memory saved, changed, or removed \
        in this episode shows here from the next one.
        """

    /// What goes into the block, and what is left out to keep it under the cap.
    public struct Contents: Sendable, Equatable {
        public var text: String
        public var included: [Memory]
        public var omitted: Int

        public var isOverCap: Bool { omitted > 0 }
    }

    public static func contents(_ memories: [Memory], cap: Int = characterCap) -> Contents {
        guard !memories.isEmpty else {
            return Contents(text: "\(opening)\nNo memories are saved yet.\n\(closing)", included: [], omitted: 0)
        }
        func line(_ memory: Memory) -> String {
            memory.saved.map { "- [\(memory.id)] \($0): \(memory.text)" } ?? "- [\(memory.id)] \(memory.text)"
        }
        func render(_ chosen: [Memory], omitted: Int) -> String {
            var lines = [opening, introduction] + chosen.map(line)
            if omitted > 0 {
                lines.append("\(omitted) older \(omitted == 1 ? "memory is" : "memories are") left out here to keep this short. Call \(ReadMemoriesTool.name) to see them all.")
            }
            lines.append(closing)
            return lines.joined(separator: "\n")
        }
        let all = render(memories, omitted: 0)
        if all.count <= cap { return Contents(text: all, included: memories, omitted: 0) }

        // Most recently saved first: by day, and within a day, or with no day, later in the file.
        let order = memories.indices.sorted { a, b in
            let left = memories[a].saved ?? "", right = memories[b].saved ?? ""
            return left != right ? left > right : a > b
        }
        let reserve = render([], omitted: memories.count).count
        var budget = cap - reserve
        var chosen = Set<Int>()
        for index in order {
            let cost = line(memories[index]).count + 1
            guard cost <= budget else { break }
            budget -= cost
            chosen.insert(index)
        }
        // Shown in the file's order, so the block reads the same way the file does.
        let included = memories.indices.filter(chosen.contains).map { memories[$0] }
        return Contents(
            text: render(included, omitted: memories.count - included.count), included: included,
            omitted: memories.count - included.count)
    }

    /// What Debugging and the Instructions section show in place of the block: its size, never
    /// what it says.
    public static func placeholder(count: Int, characters: Int) -> String {
        "\(opening)\n[\(count == 1 ? "1 memory" : "\(count) memories"), \(characters.formatted()) characters. Not shown here. See Settings, Memory.]\n\(closing)"
    }
}

/// The memory block as it was when an episode's first request was made. The instructions at
/// the head of every request have to stay byte for byte the same through an episode for the
/// prompt cache to hold, so the block is read once per episode and kept. A memory saved
/// partway through is already in the conversation as the tool call that saved it, and joins
/// the block at the next episode.
public final class MemorySnapshot: Sendable {
    private struct Taken {
        var episodeID: UUID?
        var contents: MemoryBlock.Contents
    }

    private let taken = Mutex<Taken?>(nil)

    public init() {}

    /// The block for this episode: the one taken earlier in it, or a fresh one when the
    /// episode is new.
    public func contents(for episodeID: UUID?, read: () -> MemoryBlock.Contents) -> MemoryBlock.Contents {
        taken.withLock { taken in
            if let taken, taken.episodeID == episodeID { return taken.contents }
            let contents = read()
            taken = Taken(episodeID: episodeID, contents: contents)
            return contents
        }
    }

    /// The block sent with the most recent request, if any request has been made.
    public var latest: MemoryBlock.Contents? { taken.withLock { $0?.contents } }
}
