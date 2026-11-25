import Foundation

/// Checks that a theme's primary and secondary text can be read, by the WCAG 2 contrast ratio.
///
/// Each appearance is checked where its text sits: on the surface, on the bars (the top bar and
/// the band with the text field), in the text field drawn as a pill on the bars, in the owner's message box, in the agent's reply box, in the
/// go-ahead card, and on the incognito line over the incognito tint. A box's or a bar's fill is
/// drawn over the surface first, and the pill's over the bars' fill.
///
/// The surface is the backdrop:
/// - A solid surface is its fill.
/// - A glass or blur surface lets what is behind the panel through, which can be anything
///   from black to white. It is checked three times: over its fallback fill, and with its tint
///   over pure black and over pure white, the two extremes the backdrop can be.
///
/// Text in hex colors needs 4.5:1, the WCAG AA level for normal text. Text in a system label
/// color needs 3:1. macOS draws those colors itself, with vibrancy on glass and stronger in
/// Increase Contrast, and its own secondary label is about 4:1 on white, so the stricter bar
/// would refuse the system's own text. On a glass surface, a system label color is checked
/// over the fallback fill only, since vibrancy adapts it to whatever is behind the glass.
public enum ThemeContrast {
    public static let required: Double = 4.5
    public static let requiredForSystemText: Double = 3

    public enum Level: String, Sendable, CaseIterable {
        case primary
        case secondary
    }

    /// One pair of colors and how they did.
    public struct Check: Sendable, Equatable {
        public var appearance: ThemeAppearanceKind
        public var level: Level
        public var text: ThemeColor
        /// Where the text sits, such as "in the agent's reply box".
        public var place: String
        /// What is behind it, such as "over a white backdrop".
        public var backdrop: String
        /// The background the text is drawn on, as an opaque color.
        public var background: RGBA
        public var ratio: Double
        public var required: Double

        public var passes: Bool { ratio >= required }

        /// One sentence that names the pair and says by how much it falls short.
        public var failureText: String {
            let short = max(0.1, ((required - ratio) * 10).rounded(.up) / 10)
            return "\(appearance.rawValue): \(level.rawValue) text \(text) \(place) \(backdrop) is \(Self.ratioText(ratio)). It needs \(Self.ratioText(required)), so it is \(String(format: "%.1f", short)) short."
        }

        public static func ratioText(_ ratio: Double) -> String {
            String(format: "%.2f:1", (ratio * 100).rounded(.down) / 100)
        }
    }

    /// Every pair checked in the theme, in a fixed order.
    public static func checks(_ theme: Theme) -> [Check] {
        theme.appearances.flatMap { checks($0.appearance, kind: $0.kind) }
    }

    /// The pairs that do not pass.
    public static func failures(_ theme: Theme) -> [Check] {
        checks(theme).filter { !$0.passes }
    }

    /// The lowest ratio for each level in each appearance.
    public static func worst(_ theme: Theme) -> [(appearance: ThemeAppearanceKind, level: Level, check: Check)] {
        let all = checks(theme)
        var result: [(ThemeAppearanceKind, Level, Check)] = []
        for (kind, _) in theme.appearances {
            for level in Level.allCases {
                let worst = all.filter { $0.appearance == kind && $0.level == level }.min { $0.ratio < $1.ratio }
                if let worst { result.append((kind, level, worst)) }
            }
        }
        return result.map { (appearance: $0.0, level: $0.1, check: $0.2) }
    }

    static func checks(_ appearance: ThemeAppearance, kind: ThemeAppearanceKind) -> [Check] {
        let dark = kind.isDark
        let surface = appearance.surface
        let fill = surface.fill.resolved(dark: dark)
        var backdrops: [(label: String, color: RGBA, isFallback: Bool)] = [("over the fallback fill", fill, true)]
        if surface.kind != .solid {
            let tint = surface.tint?.resolved(dark: dark) ?? RGBA(red: 0, green: 0, blue: 0, alpha: 0)
            backdrops.append(("with the tint over a black backdrop", tint.over(.black), false))
            backdrops.append(("with the tint over a white backdrop", tint.over(.white), false))
        }
        if surface.kind == .solid { backdrops[0].label = "on the solid fill" }

        // Each place's fills, from the surface up.
        let places: [(label: String, fills: [ThemeColor], levels: [Level], incognito: Bool)] = [
            ("on the surface", [], [.primary, .secondary], false),
            ("on the bars", [appearance.barFill], [.primary, .secondary], false),
            ("in the text field", [appearance.barFill, appearance.fieldBox.fill], [.primary, .secondary], false),
            ("in the owner's message box", [appearance.ownerMessage.fill], [.primary], false),
            ("in the agent's reply box", [appearance.agentReply.fill], [.primary, .secondary], false),
            ("in the go-ahead card", [appearance.goAhead.fill], [.primary, .secondary], false),
            ("on the incognito line", [appearance.incognito.badge], [.secondary], true),
        ]

        var checks: [Check] = []
        for place in places {
            for level in place.levels {
                let text = level == .primary ? appearance.text.primary : appearance.text.secondary
                let vibrant = surface.kind == .glass && text.isSystem
                for backdrop in backdrops where !vibrant || backdrop.isFallback {
                    var background = backdrop.color
                    if place.incognito { background = appearance.incognito.tint.resolved(dark: dark).over(background) }
                    for fill in place.fills { background = fill.resolved(dark: dark).over(background) }
                    let ratio = text.resolved(dark: dark).contrast(over: background)
                    checks.append(Check(
                        appearance: kind, level: level, text: text, place: place.label, backdrop: backdrop.label,
                        background: background, ratio: ratio,
                        required: text.isSystem ? requiredForSystemText : required))
                }
            }
        }
        return checks
    }
}
