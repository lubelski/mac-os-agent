import Foundation

/// Messages the owner sent while a task was running, waiting to go out one per turn. An
/// experiment, behind `Experiment.queueMessagesWhileRunning`.
///
/// It is held in memory only, one per window. A queued message is an ordinary message when it
/// is sent, so nothing about the request changes. When a task is stopped or ends with an error,
/// the queue pauses: it keeps its messages and sends none until the owner says to.
public struct MessageQueue: Sendable, Equatable {
    public struct Item: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var text: String
        /// The images attached to it, already reduced and encoded, which go with it when it is sent.
        public var images: [PreparedImage]

        public init(id: UUID = UUID(), text: String, images: [PreparedImage] = []) {
            self.id = id
            self.text = text
            self.images = images
        }
    }

    /// Why the queue stopped sending.
    public enum Pause: Sendable, Equatable {
        /// The owner stopped the task.
        case stopped
        /// The task ended with an error.
        case failed
    }

    /// Oldest first, the order they will be sent in.
    public private(set) var items: [Item] = []
    public private(set) var pauseReason: Pause?

    public init() {}

    public var isEmpty: Bool { items.isEmpty }

    public mutating func append(_ text: String, images: [PreparedImage] = []) {
        items.append(Item(text: text, images: images))
    }

    /// Puts a message back at the front, such as one that could not be sent.
    public mutating func putBack(_ item: Item) {
        items.insert(item, at: 0)
    }

    public mutating func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        if items.isEmpty { pauseReason = nil }
    }

    /// Takes a message out of the queue to edit it in the field: the one with this id, or
    /// without one the newest, as Up Arrow does.
    public mutating func pullBack(_ id: UUID? = nil) -> String? {
        pullBackItem(id)?.text
    }

    /// The same, with the message's images.
    public mutating func pullBackItem(_ id: UUID? = nil) -> Item? {
        guard let index = id.map({ id in items.firstIndex { $0.id == id } }) ?? items.indices.last else { return nil }
        let item = items.remove(at: index)
        if items.isEmpty { pauseReason = nil }
        return item
    }

    /// The next message to send when a turn finishes normally, or nil when the queue is empty or paused.
    public mutating func next() -> Item? {
        guard pauseReason == nil, !items.isEmpty else { return nil }
        return items.removeFirst()
    }

    /// Takes the next message even when paused, and resumes. The owner's Send.
    public mutating func resume() -> Item? {
        pauseReason = nil
        return items.isEmpty ? nil : items.removeFirst()
    }

    public mutating func pause(_ reason: Pause) {
        guard !items.isEmpty else { return }
        pauseReason = reason
    }

    public mutating func clear() {
        items = []
        pauseReason = nil
    }
}
