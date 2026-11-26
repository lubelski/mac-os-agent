import Foundation

/// What a paste or a drop on the panel does with what it carries: attach images, or leave it to
/// the text field as text. The app target reads the pasteboard; the rule is here.
///
/// - Image files, as Finder copies or drags them, are attached, even though Finder puts their
///   names on the pasteboard as text too.
/// - Otherwise text is pasted as text, even when an image comes with it, as when a web page or
///   a document is copied with a picture in it. A paste of text still pastes text.
/// - Otherwise image data, as a screenshot copied to the clipboard is, is attached. So is image
///   data whose only text is one web address, as a browser's Copy Image may give.
/// - Anything else goes to the text field as before.
public enum ImagePaste {
    public enum Source: Equatable, Sendable {
        case file(URL)
        case data(Data)
    }

    public enum Choice: Equatable, Sendable {
        /// Leave it to the text field.
        case text
        /// Attach these, in order.
        case images([Source])
    }

    /// - Parameters:
    ///   - files: The file URLs carried, of any kind.
    ///   - imageData: The image data carried, such as PNG or TIFF, when there is any.
    ///   - text: The plain text carried, if any.
    ///   - isImageFile: Whether a file is an image. `ImagePreparation.isImageFile` outside tests.
    public static func choose(
        files: [URL], imageData: Data?, text: String?, isImageFile: (URL) -> Bool = ImagePreparation.isImageFile
    ) -> Choice {
        let imageFiles = files.filter(isImageFile)
        if !imageFiles.isEmpty { return .images(imageFiles.map(Source.file)) }
        if let imageData, text.map({ $0.isEmpty || isOnlyAWebAddress($0) }) ?? true { return .images([.data(imageData)]) }
        return .text
    }

    static func isOnlyAWebAddress(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed) else { return false }
        return url.scheme == "http" || url.scheme == "https"
    }

    /// How many of `count` new images fit beside `attached`, under `ImageAttachment.limit`.
    public static func room(attached: Int, adding count: Int) -> Int {
        max(0, min(count, ImageAttachment.limit - attached))
    }

    /// What the panel says when some images did not fit.
    public static func limitNotice(leftOut: Int) -> String {
        "A message can have \(ImageAttachment.limit) images. \(ImageAttachment.count(leftOut).capitalizedFirst) left out."
    }
}

extension String {
    fileprivate var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
