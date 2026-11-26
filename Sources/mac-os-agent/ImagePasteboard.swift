import AppKit
import MacOSAgentCore
import UniformTypeIdentifiers

/// What a paste or a drop carries, read from a pasteboard. `NSPasteboard` is the real one.
/// Tests use a stand-in, so they never read or write the clipboard. The rule for what to do
/// with it is `ImagePaste` in the core.
protocol ImagePasteboard {
    /// The file URLs on it, of any kind.
    var fileURLs: [URL] { get }
    /// Image data on it, such as a screenshot's PNG or TIFF.
    var imageData: Data? { get }
    var plainText: String? { get }
}

extension ImagePasteboard {
    /// What a paste or a drop of this does: attach images, or go to the text field as text.
    var imageChoice: ImagePaste.Choice {
        ImagePaste.choose(files: fileURLs, imageData: imageData, text: plainText)
    }

    var attachesImages: Bool {
        if case .images = imageChoice { true } else { false }
    }
}

extension NSPasteboard: ImagePasteboard {
    /// The image types read, most useful first. TIFF is what most apps put on the clipboard.
    static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier), NSPasteboard.PasteboardType(UTType.heic.identifier),
    ]

    var fileURLs: [URL] {
        (readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    var imageData: Data? {
        for type in Self.imageTypes {
            if let data = data(forType: type) { return data }
        }
        return nil
    }

    var plainText: String? { string(forType: .string) }
}

/// Images dropped on the panel outside the text field, from SwiftUI's drop providers.
@MainActor
enum ImageDrop {
    /// Reads the dropped files and image data and attaches the images among them. Returns
    /// false when nothing dropped can be an image, so the drop is refused.
    static func attach(_ providers: [NSItemProvider], to session: AgentSession) -> Bool {
        let usable = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }
        guard !usable.isEmpty else { return false }
        Task {
            var sources: [ImagePaste.Source] = []
            for provider in usable {
                if let source = await source(from: provider) { sources.append(source) }
            }
            if !sources.isEmpty { session.attach(sources) }
        }
        return true
    }

    private static func source(from provider: NSItemProvider) async -> ImagePaste.Source? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
            }
            if let url, ImagePreparation.isImageFile(url) { return .file(url) }
            return nil
        }
        let data: Data? = await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
        return data.map(ImagePaste.Source.data)
    }
}
