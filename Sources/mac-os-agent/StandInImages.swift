import AppKit
import CoreGraphics
import ImageIO
import MacOSAgentCore
import UniformTypeIdentifiers

/// Made-up pictures drawn in code, for previews and renders: never a real screenshot, never a
/// real name. Each goes through `ImagePreparation`, as a pasted image does.
enum StandInImages {
    enum Kind: CaseIterable {
        /// A window with an alert in it, as a screenshot of an error looks.
        case errorDialog
        /// A bar chart on a light page.
        case chart
        /// A sky over hills, as a photo.
        case landscape
    }

    static func prepared(_ kind: Kind) -> PreparedImage {
        // Drawn from fixed shapes, so preparing cannot fail.
        try! ImagePreparation.prepare(png(kind))
    }

    /// The picture as PNG bytes, at a screenshot's size.
    static func png(_ kind: Kind, width: Int = 1280, height: Int = 800) -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let size = CGSize(width: width, height: height)
        switch kind {
        case .errorDialog: drawErrorDialog(context, size)
        case .chart: drawChart(context, size)
        case .landscape: drawLandscape(context, size)
        }
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    private static func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    private static func text(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, at point: CGPoint, in context: CGContext) {
        let attributed = NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = point
        CTLineDraw(line, context)
    }

    private static func drawErrorDialog(_ context: CGContext, _ size: CGSize) {
        context.setFillColor(color(0.36, 0.42, 0.58))
        context.fill(CGRect(origin: .zero, size: size))
        let window = CGRect(x: size.width * 0.15, y: size.height * 0.18, width: size.width * 0.7, height: size.height * 0.64)
        context.setFillColor(color(0.96, 0.96, 0.97))
        context.addPath(CGPath(roundedRect: window, cornerWidth: 18, cornerHeight: 18, transform: nil))
        context.fillPath()
        // The title bar and its three buttons.
        for (index, fill) in [color(1, 0.37, 0.34), color(1, 0.74, 0.18), color(0.16, 0.79, 0.25)].enumerated() {
            context.setFillColor(fill)
            context.fillEllipse(in: CGRect(x: window.minX + 24 + CGFloat(index) * 26, y: window.maxY - 38, width: 16, height: 16))
        }
        // A warning sign.
        let sign = CGMutablePath()
        let center = CGPoint(x: window.minX + 110, y: window.midY + 40)
        sign.move(to: CGPoint(x: center.x, y: center.y + 50))
        sign.addLine(to: CGPoint(x: center.x + 55, y: center.y - 45))
        sign.addLine(to: CGPoint(x: center.x - 55, y: center.y - 45))
        sign.closeSubpath()
        context.setFillColor(color(1, 0.76, 0.1))
        context.addPath(sign)
        context.fillPath()
        text("!", size: 64, weight: .bold, color: .black, at: CGPoint(x: center.x - 9, y: center.y - 38), in: context)
        text("The backup disk is full.", size: 34, weight: .semibold, color: .black,
             at: CGPoint(x: window.minX + 200, y: window.midY + 60), in: context)
        text("Time Machine could not finish backing up to “Backup”.", size: 22, color: .darkGray,
             at: CGPoint(x: window.minX + 200, y: window.midY + 18), in: context)
        text("Error code 45", size: 18, color: .gray, at: CGPoint(x: window.minX + 200, y: window.midY - 18), in: context)
        let button = CGRect(x: window.maxX - 190, y: window.minY + 36, width: 150, height: 44)
        context.setFillColor(color(0.0, 0.48, 1))
        context.addPath(CGPath(roundedRect: button, cornerWidth: 10, cornerHeight: 10, transform: nil))
        context.fillPath()
        text("OK", size: 22, weight: .medium, color: .white, at: CGPoint(x: button.midX - 16, y: button.minY + 13), in: context)
    }

    private static func drawChart(_ context: CGContext, _ size: CGSize) {
        context.setFillColor(color(1, 1, 1))
        context.fill(CGRect(origin: .zero, size: size))
        text("Visitors by month", size: 36, weight: .semibold, color: .black, at: CGPoint(x: 80, y: size.height - 100), in: context)
        let values: [CGFloat] = [0.35, 0.5, 0.42, 0.66, 0.8, 0.58, 0.9]
        let width = (size.width - 200) / CGFloat(values.count)
        for (index, value) in values.enumerated() {
            context.setFillColor(color(0.2, 0.47, 0.85))
            context.fill(CGRect(x: 100 + CGFloat(index) * width + 12, y: 100, width: width - 24, height: (size.height - 280) * value))
        }
        context.setFillColor(color(0.8, 0.8, 0.82))
        context.fill(CGRect(x: 90, y: 96, width: size.width - 180, height: 3))
    }

    private static func drawLandscape(_ context: CGContext, _ size: CGSize) {
        let sky = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0.98, 0.72, 0.45), color(0.42, 0.62, 0.92)] as CFArray,
            locations: [0, 1])!
        context.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        context.setFillColor(color(1, 0.93, 0.7))
        context.fillEllipse(in: CGRect(x: size.width * 0.65, y: size.height * 0.45, width: 140, height: 140))
        for (index, shade) in [color(0.3, 0.5, 0.35), color(0.2, 0.38, 0.27)].enumerated() {
            let hills = CGMutablePath()
            let base = size.height * (0.38 - CGFloat(index) * 0.14)
            hills.move(to: CGPoint(x: 0, y: 0))
            hills.addLine(to: CGPoint(x: 0, y: base))
            hills.addCurve(
                to: CGPoint(x: size.width, y: base - 30), control1: CGPoint(x: size.width * 0.3, y: base + 140),
                control2: CGPoint(x: size.width * 0.6, y: base - 120))
            hills.addLine(to: CGPoint(x: size.width, y: 0))
            hills.closeSubpath()
            context.setFillColor(shade)
            context.addPath(hills)
            context.fillPath()
        }
    }
}
