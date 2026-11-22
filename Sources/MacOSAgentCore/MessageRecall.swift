import Foundation

/// Up and Down Arrow through the owner's earlier messages, as in a shell or a terminal coding
/// agent. Up goes back one message at a time. Down comes forward, and past the newest brings
/// back the draft that was being typed when recall started.
///
/// The list is read once when recall starts, most recent first. An edit to a recalled message
/// is kept while the owner moves through the others, as readline does, so coming back to it
/// shows the edit. Sending ends recall, so an edited message goes out as a new one and the
/// history it came from is unchanged.
public struct MessageRecall: Sendable, Equatable {
    /// The most messages recall goes back through.
    public static let limit = 200

    /// The messages to recall from the owner's messages, newest first: blank ones left out,
    /// consecutive repeats collapsed into one, and at most `limit`.
    public static func history(newestFirst messages: some Sequence<String>, limit: Int = limit) -> [String] {
        var result: [String] = []
        for message in messages {
            guard result.count < limit else { break }
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if result.last == message { continue }
            result.append(message)
        }
        return result
    }

    private var entries: [String] = []
    /// Which entry the field shows, 0 for the newest. Nil while the field shows the draft.
    public private(set) var position: Int?
    /// What was in the field when recall started.
    private var draft = ""
    /// Edits to recalled entries, by position, kept until recall ends.
    private var edits: [Int: String] = [:]

    public init() {}

    public var isRecalling: Bool { position != nil }

    /// Up: the next older message, or nil when there is none, so the key does what it always does.
    /// - Parameters:
    ///   - current: The field's text now.
    ///   - history: The messages, newest first, read only when recall starts.
    public mutating func older(current: String, history: () -> [String]) -> String? {
        guard let position else {
            let entries = history()
            guard !entries.isEmpty else { return nil }
            self.entries = entries
            draft = current
            edits = [:]
            self.position = 0
            return entries[0]
        }
        guard position + 1 < entries.count else { return nil }
        keep(current, at: position)
        self.position = position + 1
        return text(at: position + 1)
    }

    /// Down: the next newer message, or past the newest the draft from before recall. Nil when
    /// recall is not under way, so the key does what it always does.
    public mutating func newer(current: String) -> String? {
        guard let position else { return nil }
        keep(current, at: position)
        if position == 0 {
            let draft = draft
            reset()
            return draft
        }
        self.position = position - 1
        return text(at: position - 1)
    }

    /// Ends recall, as sending or clearing the field does.
    public mutating func reset() {
        entries = []
        position = nil
        draft = ""
        edits = [:]
    }

    private func text(at position: Int) -> String {
        edits[position] ?? entries[position]
    }

    private mutating func keep(_ current: String, at position: Int) {
        if current == entries[position] {
            edits[position] = nil
        } else {
            edits[position] = current
        }
    }
}
