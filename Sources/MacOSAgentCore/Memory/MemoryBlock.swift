import Foundation
import Synchronization

/// The memory block at the very end of the main panel's instructions: `core.md`, then an index
/// of the topic files that the app makes from their front matter. The agent never writes the
/// index.
///
/// It is capped at `MemoryLayout.blockCap` characters. Over it, the index is cut first, keeping
/// the topic files changed most recently, and then core is cut at a line, keeping its start. A
/// line says what was left out and that `read_memory` reads the rest.
public enum MemoryBlock {
    public static let opening = "<memory>"
    public static let closing = "</memory>"

    static let introduction = """
        Your memory, as it was when this episode began. A change you make in this episode shows \
        here from the next one.
        """

    /// One line of the index.
    public struct IndexLine: Sendable, Equatable {
        public var name: String
        public var description: String
        /// The day the file last changed, as `yyyy-MM-dd`.
        public var changed: String

        var text: String { "- \(name) (changed \(changed)): \(description)" }
    }

    public struct Contents: Sendable, Equatable {
        public var text: String
        /// How many characters of `core.md` are in the block, and how many it has.
        public var coreIncluded: Int
        public var coreTotal: Int
        /// How many topic files the index lists, and how many there are.
        public var topicsListed: Int
        public var topicsTotal: Int

        public var characters: Int { text.count }
        public var isCut: Bool { coreIncluded < coreTotal || topicsListed < topicsTotal }
    }

    /// The block for the memory folder as it is now.
    public static func contents(_ library: MemoryLibrary, calendar: Calendar = .current) -> Contents {
        let index = library.topics().map { file in
            IndexLine(
                name: file.id,
                description: file.problem.map { "(Its front matter cannot be read: \($0))" } ?? file.description ?? "",
                changed: file.modified.map { day($0, calendar: calendar) } ?? "unknown")
        }
        // Most recently changed first, for choosing what fits. Listed by name either way.
        let recency = Dictionary(uniqueKeysWithValues: library.topics().map { ($0.id, $0.modified ?? .distantPast) })
        return contents(core: library.core().text, index: index, recency: recency)
    }

    /// The block for this core and index. `recency` orders the index for cutting.
    public static func contents(core: String, index: [IndexLine], recency: [String: Date] = [:], cap: Int = MemoryLayout.blockCap) -> Contents {
        let core = core.trimmingCharacters(in: .whitespacesAndNewlines)
        let sorted = index.sorted { $0.name < $1.name }

        func render(core shown: String, coreCut: Bool, listed: [IndexLine]) -> String {
            var lines = [opening, introduction, "", "<core>"]
            lines.append(shown.isEmpty && !coreCut ? "core.md is empty." : shown)
            if coreCut {
                lines.append("[The rest of core.md, \((core.count - shown.count).formatted()) characters, is left out to keep this block under its cap. Read it with \(ReadMemoryTool.name) with file \"core\".]")
            }
            lines.append("</core>")
            lines.append("")
            lines.append("<topic_files>")
            if sorted.isEmpty {
                lines.append("There are no topic files yet.")
            } else {
                lines.append("Read one with \(ReadMemoryTool.name) when its description matches the request.")
                lines += listed.map(\.text)
                if listed.count < sorted.count {
                    let left = sorted.count - listed.count
                    lines.append("[\(left) more topic \(left == 1 ? "file is" : "files are") left out to keep this block under its cap. \(ReadMemoryTool.name) with file null lists them all.]")
                }
            }
            lines.append("</topic_files>")
            lines.append(closing)
            return lines.joined(separator: "\n")
        }

        let whole = render(core: core, coreCut: false, listed: sorted)
        if whole.count <= cap {
            return Contents(text: whole, coreIncluded: core.count, coreTotal: core.count, topicsListed: sorted.count, topicsTotal: sorted.count)
        }

        // The index gives way first, keeping the files changed most recently.
        let byRecency = sorted.sorted { (recency[$0.name] ?? .distantPast) > (recency[$1.name] ?? .distantPast) }
        var listed: [IndexLine] = []
        for line in byRecency {
            let trial = (listed + [line]).sorted { $0.name < $1.name }
            if render(core: core, coreCut: false, listed: trial).count > cap { break }
            listed = trial
        }
        let withCore = render(core: core, coreCut: false, listed: listed)
        if withCore.count <= cap {
            return Contents(text: withCore, coreIncluded: core.count, coreTotal: core.count, topicsListed: listed.count, topicsTotal: sorted.count)
        }

        // Then core is cut at a line, keeping its start, where standing rules usually are.
        let budget = cap - render(core: "", coreCut: true, listed: []).count
        var shown = ""
        for line in core.split(separator: "\n", omittingEmptySubsequences: false) {
            let next = shown.isEmpty ? String(line) : shown + "\n" + line
            if next.count > budget { break }
            shown = next
        }
        if shown.isEmpty { shown = String(core.prefix(max(budget, 0))) }
        return Contents(
            text: render(core: shown, coreCut: true, listed: []), coreIncluded: shown.count, coreTotal: core.count,
            topicsListed: 0, topicsTotal: sorted.count)
    }

    static func day(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// What Debugging and the Instructions section show in place of the block: its size, never
    /// what it says.
    public static func placeholder(_ contents: Contents) -> String {
        "\(opening)\n[The memory block: core.md and an index of \(contents.topicsTotal == 1 ? "1 topic file" : "\(contents.topicsTotal) topic files"), \(contents.characters.formatted()) characters. Not shown here. See Settings, Memory.]\n\(closing)"
    }
}

/// The memory block as it was when an episode's first request was built. The instructions at
/// the head of every request have to stay byte for byte the same through an episode for the
/// prompt cache to hold, so the block is read once per episode and kept. A change made partway
/// through is already in the conversation as the tool call that made it, and joins the block
/// at the next episode.
public final class MemorySnapshot: Sendable {
    public struct Taken: Sendable, Equatable {
        public var episodeID: UUID?
        public var date: Date
        public var contents: MemoryBlock.Contents
    }

    private let taken = Mutex<Taken?>(nil)

    public init() {}

    /// The block for this episode: the one taken earlier in it, or a fresh one when the episode
    /// is new.
    public func contents(for episodeID: UUID?, now: Date = Date(), read: () -> MemoryBlock.Contents) -> MemoryBlock.Contents {
        taken.withLock { taken in
            if let taken, taken.episodeID == episodeID { return taken.contents }
            let contents = read()
            taken = Taken(episodeID: episodeID, date: now, contents: contents)
            return contents
        }
    }

    /// The block sent with the most recent request, and when it was taken, if any request has
    /// been made since the app started.
    public var latest: Taken? { taken.withLock { $0 } }
}
