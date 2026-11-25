import Foundation

/// A color in sRGB with an alpha, as math works on it. Components run from 0 to 1.
public struct RGBA: Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let black = RGBA(red: 0, green: 0, blue: 0)
    public static let white = RGBA(red: 1, green: 1, blue: 1)

    /// This color drawn over another, by ordinary alpha compositing.
    public func over(_ base: RGBA) -> RGBA {
        let alpha = self.alpha + base.alpha * (1 - self.alpha)
        guard alpha > 0 else { return RGBA(red: 0, green: 0, blue: 0, alpha: 0) }
        func mix(_ top: Double, _ bottom: Double) -> Double {
            (top * self.alpha + bottom * base.alpha * (1 - self.alpha)) / alpha
        }
        return RGBA(red: mix(red, base.red), green: mix(green, base.green), blue: mix(blue, base.blue), alpha: alpha)
    }

    /// The same color at a fraction of its alpha.
    public func scaled(alpha factor: Double) -> RGBA {
        RGBA(red: red, green: green, blue: blue, alpha: min(1, max(0, alpha * factor)))
    }

    /// Relative luminance as WCAG 2 defines it, ignoring alpha.
    public var relativeLuminance: Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// The WCAG 2 contrast ratio between two opaque colors, from 1 to 21.
    public static func contrast(_ first: RGBA, _ second: RGBA) -> Double {
        let lighter = max(first.relativeLuminance, second.relativeLuminance)
        let darker = min(first.relativeLuminance, second.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// The contrast of text in this color, drawn over an opaque background.
    public func contrast(over background: RGBA) -> Double {
        RGBA.contrast(over(background), background)
    }
}

/// A color the system defines, which follows the owner's accent color and the appearance. The
/// Glass theme uses these, so it looks exactly like the panel did before themes.
public enum SystemThemeColor: String, Sendable, CaseIterable {
    /// The label color: the primary text level.
    case label = "system-label"
    case secondaryLabel = "system-secondary-label"
    case tertiaryLabel = "system-tertiary-label"
    /// The accent color the owner picked in System Settings.
    case accent = "system-accent"

    /// What the color is close to, for contrast checks. macOS draws the label colors over
    /// glass with vibrancy, and the accent is the owner's to pick, so these are estimates:
    /// the label colors as macOS defines them away from vibrancy, and the default blue accent.
    public func approximation(dark: Bool) -> RGBA {
        switch (self, dark) {
        case (.label, false): RGBA(red: 0, green: 0, blue: 0, alpha: 0.85)
        case (.label, true): RGBA(red: 1, green: 1, blue: 1, alpha: 0.85)
        case (.secondaryLabel, false): RGBA(red: 0, green: 0, blue: 0, alpha: 0.5)
        case (.secondaryLabel, true): RGBA(red: 1, green: 1, blue: 1, alpha: 0.55)
        case (.tertiaryLabel, false): RGBA(red: 0, green: 0, blue: 0, alpha: 0.26)
        case (.tertiaryLabel, true): RGBA(red: 1, green: 1, blue: 1, alpha: 0.25)
        case (.accent, false): RGBA(red: 0, green: 122.0 / 255, blue: 1)
        case (.accent, true): RGBA(red: 10.0 / 255, green: 132.0 / 255, blue: 1)
        }
    }
}

/// One color in a theme file. It is written as text in one of two ways:
///
/// - Hex, `#RRGGBB` or `#RRGGBBAA`, where the last pair is the alpha. `#0B3D45E6` is a deep
///   teal at 90 percent.
/// - A system color name, alone or with an opacity in percent: `system-label`,
///   `system-accent 30%`. See `SystemThemeColor`.
public enum ThemeColor: Sendable, Hashable, CustomStringConvertible {
    case hex(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)
    /// A system color at an opacity from 0 to 100 percent.
    case system(SystemThemeColor, percent: Int)

    public static let clear = ThemeColor.hex(red: 0, green: 0, blue: 0, alpha: 0)

    /// Reads the text of a color, or returns nil when it is neither form.
    public init?(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") {
            let digits = text.dropFirst()
            guard digits.count == 6 || digits.count == 8, digits.allSatisfy(\.isHexDigit) else { return nil }
            var bytes: [UInt8] = []
            var index = digits.startIndex
            while index < digits.endIndex {
                let next = digits.index(index, offsetBy: 2)
                guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }
                bytes.append(byte)
                index = next
            }
            self = .hex(red: bytes[0], green: bytes[1], blue: bytes[2], alpha: bytes.count == 4 ? bytes[3] : 255)
            return
        }
        let parts = text.split(separator: " ", omittingEmptySubsequences: true)
        guard let first = parts.first, let system = SystemThemeColor(rawValue: String(first)) else { return nil }
        switch parts.count {
        case 1:
            self = .system(system, percent: 100)
        case 2:
            let opacity = parts[1]
            guard opacity.hasSuffix("%"), let percent = Int(opacity.dropLast()), (0...100).contains(percent) else { return nil }
            self = .system(system, percent: percent)
        default:
            return nil
        }
    }

    /// The color as a theme file writes it. Reading it back gives the same color.
    public var description: String {
        switch self {
        case .hex(let red, let green, let blue, let alpha):
            let rgb = String(format: "#%02X%02X%02X", red, green, blue)
            return alpha == 255 ? rgb : rgb + String(format: "%02X", alpha)
        case .system(let color, let percent):
            return percent == 100 ? color.rawValue : "\(color.rawValue) \(percent)%"
        }
    }

    public var isSystem: Bool {
        if case .system = self { true } else { false }
    }

    /// True for a color that hides what is behind it completely.
    public var isOpaque: Bool {
        switch self {
        case .hex(_, _, _, let alpha): alpha == 255
        case .system(let color, let percent): percent == 100 && color == .accent
        }
    }

    /// The color as math works on it. A system color is its approximation.
    public func resolved(dark: Bool) -> RGBA {
        switch self {
        case .hex(let red, let green, let blue, let alpha):
            RGBA(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255, alpha: Double(alpha) / 255)
        case .system(let color, let percent):
            color.approximation(dark: dark).scaled(alpha: Double(percent) / 100)
        }
    }

    /// The alpha from 0 to 1, as written.
    public var opacity: Double {
        switch self {
        case .hex(_, _, _, let alpha): Double(alpha) / 255
        case .system(_, let percent): Double(percent) / 100
        }
    }

    /// The same color at another alpha, from 0 to 1, rounded to what a file can write.
    public func scaled(toOpacity opacity: Double) -> ThemeColor {
        let opacity = min(1, max(0, opacity))
        return switch self {
        case .hex(let red, let green, let blue, _):
            .hex(red: red, green: green, blue: blue, alpha: UInt8((opacity * 255).rounded()))
        case .system(let system, _):
            .system(system, percent: Int((opacity * 100).rounded()))
        }
    }
}
