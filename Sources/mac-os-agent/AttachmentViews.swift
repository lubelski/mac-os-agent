import AppKit
import ImageIO
import MacOSAgentCore
import SwiftUI

extension EnvironmentValues {
    /// Reads the bytes of an image the conversation shows, for its thumbnail. Nil when they are gone.
    @Entry var imageData: (ImageAttachment) -> Data? = { _ in nil }
}

/// Small images drawn from attached images' bytes, made once per image and size and kept, so a
/// conversation with images does not read, hash, and decode a 2,048 pixel PNG on every redraw.
@MainActor
enum ImageThumbnails {
    private static let cache = NSCache<NSString, NSImage>()

    /// A thumbnail whose long edge is `points` at the screen's scale, or nil when the bytes are
    /// gone or cannot be read. `data` is asked only when no thumbnail is kept, so a kept one costs
    /// no file read. An image's id is the hash of its bytes, so a kept thumbnail is never stale.
    /// A missing image is not kept: pasting the same picture again writes its file back under the
    /// same name, and its thumbnails should then show it. Asking again costs a failed file open.
    static func image(for attachment: ImageAttachment, points: CGFloat, data: () -> Data?) -> NSImage? {
        let key = "\(attachment.id)-\(Int(points))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let data = data() else { return nil }
        let pixels = Int(points * 2)
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let thumbnail = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2))
        cache.setObject(thumbnail, forKey: key)
        return thumbnail
    }

    /// The whole image, for the larger view a click opens.
    static func fullImage(data: Data) -> NSImage? {
        NSImage(data: data)
    }
}

/// One image as a small square, filled edge to edge, with the message box's corners. An image
/// whose bytes are gone shows a quiet placeholder that says so.
struct ImageThumbnail: View {
    let attachment: ImageAttachment
    var size: CGFloat = 48
    @Environment(\.imageData) private var imageData
    @Environment(\.panelPalette) private var palette

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PanelShape.messageCornerRadius, style: .continuous)
        Group {
            if let image = ImageThumbnails.image(for: attachment, points: size, data: { imageData(attachment) }) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    shape.fill(palette.textTint(0.06))
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: size * 0.32))
                        .foregroundStyle(.tertiary)
                }
                .help("This image is no longer on this Mac.")
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(palette.textTint(0.12), lineWidth: 1))
    }

    /// What VoiceOver says for it, such as "Image, 1280 by 800".
    static func spokenText(_ attachment: ImageAttachment) -> String {
        "Image, \(attachment.width) by \(attachment.height)"
    }
}

/// The images attached to the next message, as a row of thumbnails above the text field, each
/// with a control to remove it. They are not in the field: it holds one icon and the text. The
/// row sits where the task links row and the suggestions do, and is not drawn when nothing is
/// attached. A line under the thumbnails says why an image was left out, or that the model
/// cannot read images.
struct AttachmentRow: View {
    let attachments: [PreparedImage]
    let notice: String?
    var remove: (String) -> Void = { _ in }
    var revealsControls = false

    static let thumbnailSize: CGFloat = 48

    var body: some View {
        if !attachments.isEmpty || notice != nil {
            VStack(alignment: .leading, spacing: 6) {
                if !attachments.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(attachments.enumerated()), id: \.element.id) { index, image in
                            AttachedThumbnail(
                                image: image, index: index, count: attachments.count, remove: remove,
                                revealsControl: revealsControls)
                        }
                        Spacer(minLength: 0)
                    }
                }
                if let notice {
                    Text(verbatim: notice)
                        .font(InputFooter.font)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(ImageAttachment.count(attachments.count) + " attached")
        }
    }
}

/// An attached image's thumbnail, with its remove control in the corner, which shows under the
/// pointer and always to VoiceOver.
private struct AttachedThumbnail: View {
    let image: PreparedImage
    let index: Int
    let count: Int
    let remove: (String) -> Void
    let revealsControl: Bool
    @State private var hovering = false

    var body: some View {
        ImageThumbnail(attachment: image.attachment, size: AttachmentRow.thumbnailSize)
            .environment(\.imageData) { $0.id == image.id ? image.data : nil }
            .overlay(alignment: .topTrailing) {
                Button { remove(image.id) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.65))
                }
                .buttonStyle(.plain)
                .help("Remove this image")
                .offset(x: 5, y: -5)
                .opacity(hovering || revealsControl ? 1 : 0)
                .accessibilityLabel("Remove image \(index + 1)")
            }
            .padding(.top, 5)
            .padding(.trailing, 5)
            .onHover { hovering = $0 }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(ImageThumbnail.spokenText(image.attachment)), \(index + 1) of \(count)")
            .accessibilityAction(named: "Remove") { remove(image.id) }
    }
}

/// The images sent with one of the owner's messages, as thumbnails on the message's side. A
/// click shows one larger in a popover beside it.
struct MessageImages: View {
    let images: [ImageAttachment]
    static let thumbnailSize: CGFloat = 72
    @Environment(\.messageLayout) private var layout

    var body: some View {
        HStack(spacing: 6) {
            // On the owner's side, or at the left with the full width layout.
            if !layout.boxesFillWidth { Spacer(minLength: MessageStyle.farSideInset) }
            ForEach(images, id: \.self) { image in
                MessageImage(image: image)
            }
            if layout.boxesFillWidth { Spacer(minLength: 0) }
        }
    }
}

private struct MessageImage: View {
    let image: ImageAttachment
    @State private var showsLarger = false
    @Environment(\.imageData) private var imageData

    var body: some View {
        Button { showsLarger = true } label: {
            ImageThumbnail(attachment: image, size: MessageImages.thumbnailSize)
        }
        .buttonStyle(.plain)
        .help("Show this image larger")
        .accessibilityLabel(ImageThumbnail.spokenText(image))
        .accessibilityHint("Shows the image larger")
        .popover(isPresented: $showsLarger, arrowEdge: .leading) {
            LargerImage(image: image, data: imageData(image))
        }
    }
}

/// An image at up to 640 points, in a popover. Esc or a click elsewhere closes it.
private struct LargerImage: View {
    let image: ImageAttachment
    let data: Data?

    var body: some View {
        Group {
            if let data, let full = ImageThumbnails.fullImage(data: data) {
                let scale = min(1, 640 / CGFloat(max(image.width, image.height, 1)) * 2)
                Image(nsImage: full)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(
                        maxWidth: CGFloat(image.width) / 2 * scale,
                        maxHeight: CGFloat(image.height) / 2 * scale)
            } else {
                Text("This image is no longer on this Mac.")
                    .foregroundStyle(.secondary)
                    .padding(20)
            }
        }
        .padding(8)
    }
}
