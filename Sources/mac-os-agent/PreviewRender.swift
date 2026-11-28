import AppKit

/// Draws a preview window to a PNG without ever putting it on screen.
///
/// `--render-to <file.png>` with `--preview-panel` or `--preview-settings` builds the same
/// window with the same stand-in data, but never orders it in: no window appears, nothing takes
/// focus, and no Screen Recording permission is needed. That makes it safe to run from an agent
/// session without asking the owner, which is what pull request evidence needs.
/// `scripts/render-previews.sh` runs it for a list of states.
///
/// It draws what AppKit draws into a bitmap. Liquid Glass, blur, and the vibrant colors drawn on
/// them need the window server, so boxes and lines on glass come out missing, most of all in
/// light mode. `scripts/render-previews.sh` passes `--preview-glass off`, which draws the theme's
/// opaque fallback instead. For the
/// glass itself, capture a real window with `scripts/capture-panel-previews.sh --backdrop`,
/// which puts a window on screen and so needs the owner's go-ahead.
@MainActor
enum PreviewRender {
    static let argument = "--render-to"

    /// Where to write the PNG, when this run renders instead of showing a window.
    static let target: URL? = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: argument), index + 1 < arguments.count else { return nil }
        return URL(filePath: arguments[index + 1])
    }()

    static var isRendering: Bool { target != nil }

    /// Waits for SwiftUI to lay out and for stand-in state to arrive, draws the window, writes
    /// the PNG, and quits: 0 when written, 1 when not.
    ///
    /// `alongside` gives windows drawn with it, such as the part of the match card below the
    /// panel, which is a child window of its own. They are asked for once the window has laid
    /// out, each sized and placed but never ordered in, and drawn where they are on screen
    /// relative to it, so the image is their union. Around the window, where only they are, the
    /// image is clear.
    ///
    /// `screenBottom`, the bottom of the screen's visible area on screen, draws a band below
    /// that line, where the Dock or the screen's edge is, so the image shows how close the
    /// windows come to it.
    static func render(
        _ window: NSWindow, after delay: Duration = .milliseconds(900), screenBottom: CGFloat? = nil,
        alongside: @escaping @MainActor () -> [NSWindow] = { [] }
    ) {
        guard let target else { return }
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            // The frame view holds the title bar and the content, so the image is the whole window.
            guard let view = window.contentView?.superview ?? window.contentView else { exit(1) }
            guard let content = cache(view) else {
                FileHandle.standardError.write(Data("render: the window has no size\n".utf8))
                exit(1)
            }
            let bounds = view.bounds
            let others = alongside().compactMap { other in
                other.contentView.flatMap(cache).map { (frame: other.frame, image: $0) }
            }
            var union = others.reduce(window.frame) { $0.union($1.frame) }
            if let screenBottom {
                union = union.union(CGRect(x: union.minX, y: screenBottom - bandHeight, width: union.width, height: bandHeight))
            }
            // Where each window is in the image, from where it is on screen.
            func place(_ frame: CGRect) -> CGRect {
                frame.offsetBy(dx: -union.minX, dy: -union.minY)
            }
            let scale = CGFloat(content.pixelsWide) / max(1, bounds.width)

            let output = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int((union.width * scale).rounded()),
                pixelsHigh: Int((union.height * scale).rounded()),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            output.size = union.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: output)
            // Lay the drawing over the window's background, so glass that drew nothing reads
            // as a surface rather than a hole, then round the corners as the window does.
            let rect = place(window.frame)
            NSGraphicsContext.saveGraphicsState()
            let shape = NSBezierPath(roundedRect: rect, xRadius: cornerRadius(of: window), yRadius: cornerRadius(of: window))
            shape.addClip()
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                (window.backgroundColor ?? .windowBackgroundColor).setFill()
                if window.backgroundColor == .clear { NSColor.windowBackgroundColor.setFill() }
                rect.fill()
            }
            image(content, size: bounds.size).draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
            // The windows alongside draw their own fill and corners.
            for other in others {
                image(other.image, size: other.frame.size).draw(in: place(other.frame))
            }
            if let screenBottom {
                drawScreenBottom(in: place(CGRect(x: union.minX, y: screenBottom - bandHeight, width: union.width, height: bandHeight)))
            }
            NSGraphicsContext.restoreGraphicsState()

            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard let png = output.representation(using: .png, properties: [:]) else { exit(1) }
                try png.write(to: target)
                print("rendered \(target.path) \(Int(union.width))x\(Int(union.height))")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("render: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
    }

    /// How tall the band below the screen's visible area is drawn.
    private static let bandHeight: CGFloat = 28

    /// The band below the screen's visible area: a gray stripe with a caption, under a line at
    /// its top edge.
    private static func drawScreenBottom(in rect: CGRect) {
        NSColor(white: 0.5, alpha: 0.35).setFill()
        rect.fill()
        NSColor(white: 0.5, alpha: 0.9).setFill()
        CGRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1).fill()
        let caption = NSAttributedString(string: "Bottom of the screen's visible area", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 0.5, alpha: 1),
        ])
        let size = caption.size()
        caption.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2 - 1))
    }

    /// Lays out a view and draws it into a bitmap, or nil when it has no size.
    private static func cache(_ view: NSView) -> NSBitmapImageRep? {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0, let content = view.bitmapImageRepForCachingDisplay(in: bounds)
        else { return nil }
        view.cacheDisplay(in: bounds, to: content)
        return content
    }

    private static func image(_ rep: NSBitmapImageRep, size: CGSize) -> NSImage {
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    private static func cornerRadius(of window: NSWindow) -> CGFloat {
        window is NSPanel ? 16 : 12
    }
}
