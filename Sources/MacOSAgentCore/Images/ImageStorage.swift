import Foundation
import Synchronization

/// Where the bytes of attached images live. The thread entry holds an `ImageAttachment`, which
/// says which image; the store holds the bytes.
///
/// - `ImageFolder` is the main panel's: one file per image in `images/` in the data folder,
///   named by the hash of its bytes.
/// - `InMemoryImageStore` is an incognito window's. It writes nothing, and is gone with the
///   conversation.
public protocol ImageStorage: Sendable {
    /// Keeps the image's bytes. Keeping the same image twice keeps it once.
    func keep(_ image: PreparedImage) throws
    /// The bytes of an image, or nil when they are gone.
    func data(for attachment: ImageAttachment) -> Data?
}

/// The images folder in the data folder. Each file is named by the SHA-256 of its bytes and
/// never changes once written, since the same name always means the same bytes.
public struct ImageFolder: ImageStorage {
    public let folder: URL

    public init(folder: URL = AgentPaths.imagesFolder) {
        self.folder = folder
    }

    public func url(for attachment: ImageAttachment) -> URL {
        folder.appending(path: attachment.fileName)
    }

    public func keep(_ image: PreparedImage) throws {
        let url = url(for: image.attachment)
        if FileManager.default.fileExists(atPath: url.path) { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try image.data.write(to: url, options: .atomic)
    }

    public func data(for attachment: ImageAttachment) -> Data? {
        // A file whose bytes are not the ones named is as good as gone: sending other bytes
        // would break the cache and show the model a different picture.
        guard let data = try? Data(contentsOf: url(for: attachment)),
              ImageAttachment.contentID(of: data) == attachment.id
        else { return nil }
        return data
    }
}

/// An incognito conversation's images, held only in memory. Letting go of the store lets go of them.
public final class InMemoryImageStore: ImageStorage {
    private let images = Mutex<[String: Data]>([:])

    public init() {}

    public func keep(_ image: PreparedImage) {
        images.withLock { $0[image.attachment.id] = image.data }
    }

    public func data(for attachment: ImageAttachment) -> Data? {
        images.withLock { $0[attachment.id] }
    }
}

/// The bytes a loop sends for each image, read once per image and then kept for as long as the
/// image is in the episode being sent. An image read once is sent the same way until it leaves
/// the episode, and so is one that was already gone, even if its file comes back or goes away
/// in between. So a request never changes shape partway through an episode.
final class SentImages: Sendable {
    private let resolved = Mutex<[String: Data?]>([:])

    /// The bytes of each image these entries hold, by id. An image whose bytes are gone has no
    /// value. Images no longer in the entries are let go.
    func bytes(for entries: [ThreadEntry], from storage: any ImageStorage) -> [String: Data] {
        let attachments = entries.flatMap(\.item.images)
        return resolved.withLock { resolved in
            let wanted = Set(attachments.map(\.id))
            resolved = resolved.filter { wanted.contains($0.key) }
            var found: [String: Data] = [:]
            for attachment in attachments {
                if resolved[attachment.id] == nil {
                    resolved[attachment.id] = .some(storage.data(for: attachment))
                }
                if case .some(.some(let data)) = resolved[attachment.id] { found[attachment.id] = data }
            }
            return found
        }
    }
}

extension ThreadItem {
    /// The images on an owner's message. None for any other entry.
    public var images: [ImageAttachment] {
        if case .userMessage(_, _, _, let images) = self { return images }
        return []
    }
}
