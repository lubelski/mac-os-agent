import CryptoKit
import Foundation

/// An image the owner attached to a message, as the thread keeps it: what it is and where its
/// bytes are, never the bytes. The bytes are a file in the images folder, named by `id`, or in
/// an incognito window a value held in memory. See `ImageStorage`.
///
/// The bytes are the image as it was reduced and encoded once, when it was attached, so every
/// request of the episode sends exactly the same bytes and the prompt cache holds.
public struct ImageAttachment: Sendable, Equatable, Hashable, Codable {
    /// The SHA-256 of the bytes, in lowercase hex. Two attachments of the same picture are one file.
    public var id: String
    /// The media type: `image/png` or `image/jpeg`.
    public var type: String
    /// The size of the bytes.
    public var bytes: Int
    /// The size in pixels, after reducing.
    public var width: Int
    public var height: Int

    public init(id: String, type: String, bytes: Int, width: Int, height: Int) {
        self.id = id
        self.type = type
        self.bytes = bytes
        self.width = width
        self.height = height
    }

    public static let png = "image/png"
    public static let jpeg = "image/jpeg"

    /// The file the bytes are kept in, such as `3f9a…c1.png`.
    public var fileName: String {
        "\(id).\(type == Self.jpeg ? "jpg" : "png")"
    }

    /// The most images that go with one message.
    public static let limit = 6

    /// The hex SHA-256 of some bytes, which names the file they are kept in.
    public static func contentID(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Words

    /// "1 image" or "3 images".
    public static func count(_ count: Int) -> String {
        count == 1 ? "1 image" : "\(count) images"
    }

    /// What History, search, and the agent's `read_episode` say about a message's images, such
    /// as "[with 2 images]". Empty for a message without any.
    public static func historyNote(_ images: [ImageAttachment]) -> String {
        images.isEmpty ? "" : "[with \(count(images.count))]"
    }

    /// A message's text as History reads it: what was typed, then the note on its images.
    public static func historyText(_ text: String, images: [ImageAttachment]) -> String {
        let note = historyNote(images)
        if note.isEmpty { return text }
        if text.isEmpty { return note }
        return "\(text) \(note)"
    }

    /// What the model is sent in place of an image whose bytes are gone, such as a file deleted
    /// from the images folder. It is fixed text, so a request that sends it sends the same every time.
    public static let missingNote = "[An image the owner attached here is no longer on this Mac.]"
}

/// An image reduced and encoded for sending, with its bytes, before it is kept. The session
/// holds these while the owner writes the message and while the message waits in the queue.
public struct PreparedImage: Sendable, Equatable, Identifiable {
    public var attachment: ImageAttachment
    public var data: Data

    public var id: String { attachment.id }

    public init(attachment: ImageAttachment, data: Data) {
        self.attachment = attachment
        self.data = data
    }
}
