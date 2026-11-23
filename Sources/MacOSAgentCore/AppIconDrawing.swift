import CoreGraphics
import Foundation

/// Draws the app icon's artwork: white shapes on a clear background, one image per layer of
/// the Icon Composer file. `scripts/render-icon.sh` turns them into `Resources/AppIcon.icon`,
/// and the system adds the background, the rounded shape, and the glass.
///
/// There are four designs to choose from. `shipped` is the one in the app.
public enum AppIconDrawing {
    /// The side of the square canvas, in pixels. Icon Composer's canvas for a Mac icon.
    public static let canvas: CGFloat = 1024

    /// The design in `Resources/AppIcon.icon`.
    public static let shipped = Design.promptSpark

    public enum Design: Int, CaseIterable, Sendable {
        /// The panel's own `›` prompt mark, with a spark where the answer will be.
        case promptSpark = 1
        /// The summoned panel as a bar with a text cursor in it, and a spark above.
        case summonBar = 2
        /// A pointer whose tip gives off a short burst, for acting on the system.
        case pointerBurst = 3
        /// Three keys of a shortcut, with a spark where a fourth would be.
        case keyChord = 4

        public var title: String {
            switch self {
            case .promptSpark: "Prompt and spark"
            case .summonBar: "Summoned bar"
            case .pointerBurst: "Pointer that acts"
            case .keyChord: "Key chord"
            }
        }

        /// The background gradient, top color first, as sRGB components.
        public var gradient: (top: [CGFloat], bottom: [CGFloat]) {
            switch self {
            case .promptSpark: ([0.12, 0.64, 0.68], [0.03, 0.30, 0.38])
            case .summonBar: ([0.26, 0.52, 0.98], [0.07, 0.20, 0.62])
            case .pointerBurst: ([0.93, 0.33, 0.48], [0.55, 0.08, 0.27])
            case .keyChord: ([0.30, 0.72, 0.45], [0.07, 0.36, 0.24])
            }
        }

        /// The layers, front first, as Icon Composer lists them.
        public var layers: [Layer] {
            switch self {
            case .promptSpark:
                [Layer(name: "spark", draw: { AppIconDrawing.spark(in: $0, center: CGPoint(x: 694, y: 610), radius: 168) }),
                 Layer(name: "prompt", draw: AppIconDrawing.promptChevron)]
            case .summonBar:
                [Layer(name: "spark", draw: { AppIconDrawing.spark(in: $0, center: CGPoint(x: 712, y: 668), radius: 140) }),
                 Layer(name: "bar", draw: AppIconDrawing.summonBar)]
            case .pointerBurst:
                [Layer(name: "burst", draw: AppIconDrawing.burst),
                 Layer(name: "pointer", draw: AppIconDrawing.pointer)]
            case .keyChord:
                [Layer(name: "spark", draw: { AppIconDrawing.spark(in: $0, center: CGPoint(x: 722, y: 638), radius: 128) }),
                 Layer(name: "keys", draw: AppIconDrawing.keys)]
            }
        }
    }

    /// One layer of the icon: a name for its image, and a routine that draws it in white on a
    /// clear, canvas-sized context with y pointing up.
    public struct Layer: Sendable {
        public let name: String
        public let draw: @Sendable (CGContext) -> Void
    }

    static let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

    // MARK: Shapes

    /// A four-pointed spark, taller than it is wide, with curved sides and softened tips.
    static func sparkPath(center c: CGPoint, radius r: CGFloat) -> CGPath {
        let w = r * 0.78
        let pinch = r * 0.14
        let path = CGMutablePath()
        path.move(to: CGPoint(x: c.x, y: c.y + r))
        path.addQuadCurve(to: CGPoint(x: c.x + w, y: c.y), control: CGPoint(x: c.x + pinch, y: c.y + pinch))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x + pinch, y: c.y - pinch))
        path.addQuadCurve(to: CGPoint(x: c.x - w, y: c.y), control: CGPoint(x: c.x - pinch, y: c.y - pinch))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x - pinch, y: c.y + pinch))
        path.closeSubpath()
        return path
    }

    /// Fills a spark, and strokes it with round joins so its tips are not needle sharp.
    static func spark(in context: CGContext, center: CGPoint, radius: CGFloat) {
        let path = sparkPath(center: center, radius: radius - 8)
        context.setFillColor(white)
        context.setStrokeColor(white)
        context.addPath(path)
        context.fillPath()
        context.setLineWidth(16)
        context.setLineJoin(.round)
        context.addPath(path)
        context.strokePath()
    }

    static func strokeRound(_ context: CGContext, width: CGFloat, points: [CGPoint]) {
        context.setStrokeColor(white)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addLines(between: points)
        context.strokePath()
    }

    @Sendable static func promptChevron(_ context: CGContext) {
        strokeRound(context, width: 124, points: [
            CGPoint(x: 270, y: 676), CGPoint(x: 462, y: 484), CGPoint(x: 270, y: 292),
        ])
    }

    @Sendable static func summonBar(_ context: CGContext) {
        let bar = CGRect(x: 192, y: 240, width: 640, height: 268)
        context.setFillColor(white)
        context.addPath(CGPath(roundedRect: bar, cornerWidth: 72, cornerHeight: 72, transform: nil))
        context.fillPath()
        // The text cursor, cut out of the bar.
        context.setBlendMode(.clear)
        let caret = CGRect(x: 280, y: 296, width: 52, height: 156)
        context.addPath(CGPath(roundedRect: caret, cornerWidth: 14, cornerHeight: 14, transform: nil))
        context.fillPath()
        context.setBlendMode(.normal)
    }

    /// The pointer's outline, with its tip at the origin and y pointing down.
    static let pointerOutline: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 420), CGPoint(x: 100, y: 330),
        CGPoint(x: 172, y: 492), CGPoint(x: 246, y: 460), CGPoint(x: 174, y: 300),
        CGPoint(x: 300, y: 296),
    ]
    static let pointerTip = CGPoint(x: 472, y: 639)
    static let pointerScale: CGFloat = 0.9

    @Sendable static func pointer(_ context: CGContext) {
        let path = CGMutablePath()
        path.addLines(between: pointerOutline.map { CGPoint(x: pointerTip.x + pointerScale * $0.x, y: pointerTip.y - pointerScale * $0.y) })
        path.closeSubpath()
        context.setFillColor(white)
        context.setStrokeColor(white)
        context.addPath(path)
        context.fillPath()
        context.setLineWidth(44)
        context.setLineJoin(.round)
        context.addPath(path)
        context.strokePath()
    }

    @Sendable static func burst(_ context: CGContext) {
        // Three short strokes around the tip, up, up and to the left, and to the left.
        for degrees: CGFloat in [94, 135, 176] {
            let a = degrees * .pi / 180
            let from = CGPoint(x: pointerTip.x - 12 + 80 * cos(a), y: pointerTip.y + 12 + 80 * sin(a))
            let to = CGPoint(x: pointerTip.x - 12 + 170 * cos(a), y: pointerTip.y + 12 + 170 * sin(a))
            strokeRound(context, width: 58, points: [from, to])
        }
    }

    /// Two modifier keys over a space bar, as the summon shortcut is pressed.
    @Sendable static func keys(_ context: CGContext) {
        context.setFillColor(white)
        let keys = [
            CGRect(x: 192, y: 540, width: 196, height: 196),
            CGRect(x: 412, y: 540, width: 196, height: 196),
            CGRect(x: 192, y: 300, width: 640, height: 196),
        ]
        for key in keys {
            context.addPath(CGPath(roundedRect: key, cornerWidth: 56, cornerHeight: 56, transform: nil))
        }
        context.fillPath()
    }

    // MARK: Output

    /// Draws one layer on a clear canvas.
    public static func image(of layer: Layer) -> CGImage? {
        let size = Int(canvas)
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        layer.draw(context)
        return context.makeImage()
    }

    /// The Icon Composer file's `icon.json` for a design, naming each layer's image as
    /// `<name>.png`.
    public static func iconJSON(for design: Design) -> String {
        func color(_ c: [CGFloat]) -> String {
            "srgb:" + (c + [1]).map { String(format: "%.5f", Double($0)) }.joined(separator: ",")
        }
        let layers = design.layers.map {
            """
                    {
                      "image-name" : "\($0.name).png",
                      "name" : "\($0.name)"
                    }
            """
        }.joined(separator: ",\n")
        return """
        {
          "fill" : {
            "linear-gradient" : [
              "\(color(design.gradient.top))",
              "\(color(design.gradient.bottom))"
            ]
          },
          "groups" : [
            {
              "layers" : [
        \(layers)
              ],
              "shadow" : {
                "kind" : "neutral",
                "opacity" : 0.5
              },
              "translucency" : {
                "enabled" : false,
                "value" : 0.5
              }
            }
          ],
          "supported-platforms" : {
            "squares" : [
              "macOS"
            ]
          }
        }

        """
    }
}
