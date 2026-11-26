import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reduces and encodes an image once, when the owner attaches it. What it returns is what every
/// request sends, so it is never done again for the same attachment.
///
/// - The long edge is brought down to `maximumEdge` pixels. A smaller image keeps its size: it
///   is never scaled up.
/// - A JPEG or HEIC source, which is a photo, is encoded as JPEG. Anything else, which is
///   mostly screenshots, is encoded as PNG, which keeps text sharp.
/// - Only the pixels are kept. Metadata such as the place a photo was taken is left behind.
/// - An animated image keeps its first frame.
public enum ImagePreparation {
    public static let maximumEdge = 2048
    /// The JPEG quality for photos. High enough that a photo of a screen stays readable.
    public static let jpegQuality = 0.85
    /// The largest file the app reads to attach, before reducing. Larger is refused.
    public static let maximumSourceBytes = 64 * 1024 * 1024

    public enum PreparationError: Error, Equatable, LocalizedError {
        case notAnImage
        case tooLarge
        case couldNotEncode

        public var errorDescription: String? {
            switch self {
            case .notAnImage: "That is not an image the app can read."
            case .tooLarge: "That image is too large to attach."
            case .couldNotEncode: "The image could not be prepared for sending."
            }
        }
    }

    /// Reduces and encodes the image in these bytes, which can be any type ImageIO reads, such
    /// as PNG, TIFF from the clipboard, JPEG, HEIC, or GIF.
    public static func prepare(_ data: Data) throws -> PreparedImage {
        guard data.count <= maximumSourceBytes else { throw PreparationError.tooLarge }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let sourceWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let sourceHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              sourceWidth > 0, sourceHeight > 0
        else { throw PreparationError.notAnImage }

        let longEdge = max(sourceWidth, sourceHeight)
        // The thumbnail call reduces, applies the orientation a photo was taken in, and never
        // scales up past the size it is given, which is never more than the image's own.
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(longEdge, maximumEdge),
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            throw PreparationError.notAnImage
        }

        let sourceType = CGImageSourceGetType(source).flatMap { UTType($0 as String) }
        let isPhoto = sourceType.map { $0.conforms(to: .jpeg) || $0.conforms(to: .heic) || $0.conforms(to: .heif) } ?? false
        let (encoded, type) = try encode(image, asJPEG: isPhoto)
        let attachment = ImageAttachment(
            id: ImageAttachment.contentID(of: encoded), type: type, bytes: encoded.count,
            width: image.width, height: image.height)
        return PreparedImage(attachment: attachment, data: encoded)
    }

    /// Prepares the image in a file, such as one dropped on the panel.
    public static func prepare(contentsOf url: URL) throws -> PreparedImage {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maximumSourceBytes else { throw PreparationError.tooLarge }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw PreparationError.notAnImage }
        return try prepare(data)
    }

    /// Whether a file looks like an image the app can attach, by its type.
    public static func isImageFile(_ url: URL) -> Bool {
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        else { return false }
        return type.conforms(to: .image)
    }

    private static func encode(_ image: CGImage, asJPEG: Bool) throws -> (Data, String) {
        let output = NSMutableData()
        let type: UTType = asJPEG ? .jpeg : .png
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            throw PreparationError.couldNotEncode
        }
        let properties: [CFString: Any] = asJPEG ? [kCGImageDestinationLossyCompressionQuality: jpegQuality] : [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PreparationError.couldNotEncode }
        return (output as Data, asJPEG ? ImageAttachment.jpeg : ImageAttachment.png)
    }
}
