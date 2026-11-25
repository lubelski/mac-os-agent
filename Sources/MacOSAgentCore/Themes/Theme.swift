import Foundation

/// How the panel looks: one theme file, in `themes/` in Application Support or built into the app.
///
/// A theme file is JSON:
///
/// ```json
/// {
///   "format": 1,
///   "name": "Tidewater",
///   "dark": {
///     "surface": { "kind": "blur", "tint": "#0A3B44E8", "fill": "#0C3A42" },
///     "text": { "primary": "#EEF8F7", "secondary": "#B2D4D3", "tertiary": "#7FA8A8" },
///     "accent": "#5CCFC0",
///     ...
///   }
/// }
/// ```
///
/// - `format` is 1. A later version of the app that changes the format raises it.
/// - `name` is what Settings shows, up to 40 characters.
/// - `light` and `dark` each hold one appearance. A theme defines one or both. A theme with
///   only one is inherently light or dark, and the panel uses that appearance whatever the
///   Mac is set to.
///
/// An appearance may also set `bar`, the fill of the panel's bars: the top bar, the band with
/// the text field, and the footer under it. It is optional. Without it the bars are the primary
/// text at 3 percent, a faint offset from the surface that suits any theme, and a file written
/// before the key existed reads exactly as before.
///
/// An appearance may also set `field`, a fill and an edge for the text field drawn as a pill in
/// the band, with the panel with bars and an input pill experiment on. It is optional too.
/// Without it the pill is the primary text at 6 percent with an edge at 12 percent. See
/// `derivedField`.
///
/// Fonts, layout, and corner radii are not part of a theme.
public struct Theme: Sendable, Hashable {
    public static let format = 1
    public static let maximumNameLength = 40

    public var name: String
    public var light: ThemeAppearance?
    public var dark: ThemeAppearance?

    public init(name: String, light: ThemeAppearance?, dark: ThemeAppearance?) {
        self.name = name
        self.light = light
        self.dark = dark
    }

    /// The appearance to draw with when the Mac is in dark mode or not. A theme with only one
    /// appearance always draws with it.
    public func appearance(dark wantsDark: Bool) -> ThemeAppearance {
        if wantsDark { return dark ?? light! }
        return light ?? dark!
    }

    /// The appearance the panel is held to, or nil when it follows the Mac.
    public var fixedAppearance: ThemeAppearanceKind? {
        switch (light, dark) {
        case (nil, _?): .dark
        case (_?, nil): .light
        default: nil
        }
    }

    /// The appearances the theme defines, light first.
    public var appearances: [(kind: ThemeAppearanceKind, appearance: ThemeAppearance)] {
        [(ThemeAppearanceKind.light, light), (.dark, dark)].compactMap { kind, appearance in
            appearance.map { (kind, $0) }
        }
    }

    /// A few words for a list, such as "light and dark" or "dark only".
    public var appearanceSummary: String {
        switch fixedAppearance {
        case .dark: "dark only"
        case .light: "light only"
        case nil: "light and dark"
        }
    }
}

public enum ThemeAppearanceKind: String, Sendable, CaseIterable {
    case light
    case dark

    public var isDark: Bool { self == .dark }
}

/// What the panel draws behind its content.
public enum ThemeSurfaceKind: String, Sendable, CaseIterable {
    /// Liquid Glass, with the tint, if any, laid into the glass.
    case glass
    /// A frosted blur of what is behind the panel, with the tint over it.
    case blur
    /// The fill alone.
    case solid
}

public struct ThemeSurface: Sendable, Hashable {
    public var kind: ThemeSurfaceKind
    /// Laid over or into the glass or blur. Its alpha is how strong it is. Optional, and a
    /// solid surface does not use it.
    public var tint: ThemeColor?
    /// An opaque hex color. A solid surface is this fill. A glass or blur surface falls back to
    /// it when Use Glass is off or the Mac is set to reduce transparency.
    public var fill: ThemeColor

    public init(kind: ThemeSurfaceKind, tint: ThemeColor?, fill: ThemeColor) {
        self.kind = kind
        self.tint = tint
        self.fill = fill
    }
}

/// The three levels of text the panel uses.
public struct ThemeText: Sendable, Hashable {
    /// Messages and replies.
    public var primary: ThemeColor
    /// Labels, list markers, quotes, the program in a command line, and command output.
    public var secondary: ThemeColor
    /// Marks, command arguments, hints, and the placeholder.
    public var tertiary: ThemeColor

    public init(primary: ThemeColor, secondary: ThemeColor, tertiary: ThemeColor) {
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
    }
}

/// A box: its fill and the edge drawn around it.
public struct ThemeBox: Sendable, Hashable {
    public var fill: ThemeColor
    public var edge: ThemeColor

    public init(fill: ThemeColor, edge: ThemeColor) {
        self.fill = fill
        self.edge = edge
    }
}

/// How an incognito episode marks the panel.
public struct ThemeIncognito: Sendable, Hashable {
    /// Laid over the whole surface while the episode is on.
    public var tint: ThemeColor
    /// The fill of the line at the top that says nothing is kept.
    public var badge: ThemeColor

    public init(tint: ThemeColor, badge: ThemeColor) {
        self.tint = tint
        self.badge = badge
    }
}

/// One appearance of a theme: everything the panel draws with when the Mac is light, or dark.
public struct ThemeAppearance: Sendable, Hashable {
    public var surface: ThemeSurface
    public var text: ThemeText
    /// Buttons, the progress indicator, and the text cursor.
    public var accent: ThemeColor
    /// The owner's messages, on the right.
    public var ownerMessage: ThemeBox
    /// The agent's replies, on the left.
    public var agentReply: ThemeBox
    /// The hairlines between episodes and above the text field.
    public var divider: ThemeColor
    /// The open bracket around code and command output: `┌──`, its rule, and `└──`.
    public var code: ThemeColor
    /// The card that asks for a go-ahead.
    public var goAhead: ThemeBox
    public var incognito: ThemeIncognito
    /// The fill of the panel's bars, laid over the surface: the top bar, the band with the text
    /// field, and the footer, and the inspector's bar. Nil takes `derivedBar`. Optional in a file.
    public var bar: ThemeColor?
    /// The text field drawn as a pill in the band, its fill laid over the bars' fill and its
    /// edge around it. Nil takes `derivedField`. Optional in a file.
    public var field: ThemeBox?

    public init(
        surface: ThemeSurface, text: ThemeText, accent: ThemeColor, ownerMessage: ThemeBox, agentReply: ThemeBox,
        divider: ThemeColor, code: ThemeColor, goAhead: ThemeBox, incognito: ThemeIncognito, bar: ThemeColor? = nil,
        field: ThemeBox? = nil
    ) {
        self.surface = surface
        self.text = text
        self.accent = accent
        self.ownerMessage = ownerMessage
        self.agentReply = agentReply
        self.divider = divider
        self.code = code
        self.goAhead = goAhead
        self.incognito = incognito
        self.bar = bar
        self.field = field
    }

    /// How strong the bars' fill is when a theme does not set one: the primary text at this
    /// fraction of its own strength. It is the fill the suggestions experiment's footer had.
    public static let derivedBarStrength = 0.03

    /// The bars' fill when the theme does not set one: the primary text at 3 percent. Over a
    /// dark surface that is a faint lightening and over a light one a faint darkening, and for
    /// a theme whose text is the system's it is `system-label 3%`, which keeps the vibrancy.
    public var derivedBar: ThemeColor {
        text.primary.scaled(toOpacity: text.primary.opacity * Self.derivedBarStrength)
    }

    /// The bars' fill as drawn: the theme's own, or the derived one.
    public var barFill: ThemeColor { bar ?? derivedBar }

    /// How strong the pill's fill and edge are when a theme does not set `field`: the primary
    /// text at these fractions of its own strength.
    public static let derivedFieldFillStrength = 0.06
    public static let derivedFieldEdgeStrength = 0.12

    /// The pill when the theme does not set one: the primary text at 6 percent, a step
    /// stronger than the bars' 3, with an edge at 12. Lighter than the band on a dark theme and
    /// darker on a light one, and `system-label` for a theme whose text is the system's.
    public var derivedField: ThemeBox {
        let primary = text.primary
        return ThemeBox(
            fill: primary.scaled(toOpacity: primary.opacity * Self.derivedFieldFillStrength),
            edge: primary.scaled(toOpacity: primary.opacity * Self.derivedFieldEdgeStrength))
    }

    /// The pill as drawn: the theme's own, or the derived one.
    public var fieldBox: ThemeBox { field ?? derivedField }
}

/// Why a theme file could not be read, with where in the file the problem is.
public struct ThemeFormatError: Error, Equatable, CustomStringConvertible, LocalizedError {
    public var description: String
    public init(_ description: String) { self.description = description }
    public var errorDescription: String? { description }
}

// MARK: - Reading

extension Theme {
    /// Reads a theme file. Everything is checked: unknown keys, missing keys, colors, the
    /// surface kind, and that the fill is opaque. The error says where the problem is.
    public static func parse(_ text: String) throws(ThemeFormatError) -> Theme {
        guard let value = JSONValue.parse(text) else {
            throw ThemeFormatError("The file is not valid JSON.")
        }
        return try parse(value)
    }

    public static func parse(_ value: JSONValue) throws(ThemeFormatError) -> Theme {
        let root = try Reader.object(value, at: "the file", keys: ["format", "name", "light", "dark"], optional: ["light", "dark"])
        guard let format = root["format"]?.numberValue, format.rounded() == format else {
            throw ThemeFormatError("format should be the number \(Self.format).")
        }
        if Int(format) > Self.format {
            throw ThemeFormatError("The file is format \(Int(format)), from a newer version of mac-os-agent. This version reads format \(Self.format).")
        }
        guard Int(format) == Self.format else { throw ThemeFormatError("format should be the number \(Self.format).") }
        guard let name = root["name"]?.stringValue else { throw ThemeFormatError("name should be text.") }
        try validate(name: name)
        let light = try root["light"].flatMap { value throws(ThemeFormatError) in value == .null ? nil : try Reader.appearance(value, at: "light") }
        let dark = try root["dark"].flatMap { value throws(ThemeFormatError) in value == .null ? nil : try Reader.appearance(value, at: "dark") }
        guard light != nil || dark != nil else {
            throw ThemeFormatError("The theme defines neither light nor dark. It needs at least one of them.")
        }
        return Theme(name: name.trimmingCharacters(in: .whitespaces), light: light, dark: dark)
    }

    static func validate(name: String) throws(ThemeFormatError) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { throw ThemeFormatError("name is empty.") }
        if trimmed.count > maximumNameLength { throw ThemeFormatError("name is longer than \(maximumNameLength) characters.") }
        if trimmed.contains(where: \.isNewline) { throw ThemeFormatError("name should be one line.") }
    }

    private enum Reader {
        static func object(_ value: JSONValue, at path: String, keys: [String], optional: Set<String> = []) throws(ThemeFormatError) -> [String: JSONValue] {
            guard case .object(let object) = value else { throw ThemeFormatError("\(path) should be an object.") }
            if let unknown = object.keys.sorted().first(where: { !keys.contains($0) }) {
                let place = path == "the file" ? "The file" : path
                throw ThemeFormatError("\(place) has a key it does not use, \"\(unknown)\". It takes \(keys.joined(separator: ", ")).")
            }
            if let missing = keys.first(where: { object[$0] == nil && !optional.contains($0) }) {
                let place = path == "the file" ? "The file" : path
                throw ThemeFormatError("\(place) has no \(missing).")
            }
            return object
        }

        static func color(_ object: [String: JSONValue], _ key: String, at path: String) throws(ThemeFormatError) -> ThemeColor {
            let place = "\(path).\(key)"
            guard let text = object[key]?.stringValue else { throw ThemeFormatError("\(place) should be a color as text, such as \"#1C1E21\".") }
            guard let color = ThemeColor(text) else {
                throw ThemeFormatError("\(place) is \"\(text)\", which is not a color. Use #RRGGBB or #RRGGBBAA, or a system color: \(SystemThemeColor.allCases.map(\.rawValue).joined(separator: ", ")), optionally followed by an opacity such as 30%.")
            }
            return color
        }

        static func box(_ value: JSONValue?, at path: String) throws(ThemeFormatError) -> ThemeBox {
            let object = try Self.object(value ?? .null, at: path, keys: ["fill", "edge"])
            return ThemeBox(fill: try color(object, "fill", at: path), edge: try color(object, "edge", at: path))
        }

        static func appearance(_ value: JSONValue, at path: String) throws(ThemeFormatError) -> ThemeAppearance {
            let object = try Self.object(value, at: path, keys: ThemeAppearance.keys, optional: ["bar", "field"])

            let surfacePath = "\(path).surface"
            let surface = try Self.object(object["surface"] ?? .null, at: surfacePath, keys: ["kind", "tint", "fill"], optional: ["tint"])
            guard let kindText = surface["kind"]?.stringValue, let kind = ThemeSurfaceKind(rawValue: kindText) else {
                throw ThemeFormatError("\(surfacePath).kind should be one of \(ThemeSurfaceKind.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            var tint: ThemeColor?
            if let value = surface["tint"], value != .null {
                tint = try color(surface, "tint", at: surfacePath)
            }
            let fill = try color(surface, "fill", at: surfacePath)
            guard case .hex = fill, fill.isOpaque else {
                throw ThemeFormatError("\(surfacePath).fill is \"\(fill)\". It has to be an opaque hex color, #RRGGBB, since it is what draws when glass and blur are off.")
            }

            let textPath = "\(path).text"
            let text = try Self.object(object["text"] ?? .null, at: textPath, keys: ["primary", "secondary", "tertiary"])
            let incognitoPath = "\(path).incognito"
            let incognito = try Self.object(object["incognito"] ?? .null, at: incognitoPath, keys: ["tint", "badge"])

            return ThemeAppearance(
                surface: ThemeSurface(kind: kind, tint: tint, fill: fill),
                text: ThemeText(
                    primary: try color(text, "primary", at: textPath),
                    secondary: try color(text, "secondary", at: textPath),
                    tertiary: try color(text, "tertiary", at: textPath)),
                accent: try color(object, "accent", at: path),
                ownerMessage: try box(object["ownerMessage"], at: "\(path).ownerMessage"),
                agentReply: try box(object["agentReply"], at: "\(path).agentReply"),
                divider: try color(object, "divider", at: path),
                code: try color(object, "code", at: path),
                goAhead: try box(object["goAhead"], at: "\(path).goAhead"),
                incognito: ThemeIncognito(
                    tint: try color(incognito, "tint", at: incognitoPath),
                    badge: try color(incognito, "badge", at: incognitoPath)),
                bar: try object["bar"].flatMap { value throws(ThemeFormatError) in
                    value == .null ? nil : try color(object, "bar", at: path)
                },
                field: try object["field"].flatMap { value throws(ThemeFormatError) in
                    value == .null ? nil : try box(value, at: "\(path).field")
                })
        }
    }
}

extension ThemeAppearance {
    /// The keys of an appearance, in the order a file writes them.
    static let keys = ["surface", "text", "accent", "ownerMessage", "agentReply", "divider", "code", "goAhead", "incognito", "bar", "field"]
}

// MARK: - Writing

extension Theme {
    /// The theme as a file, with its keys in a fixed order and two spaces of indent, so the
    /// same theme always writes the same bytes and reads back as itself.
    public var fileText: String {
        var lines = ["{", "  \"format\": \(Self.format),", "  \"name\": \(Self.quoted(name))\(appearances.isEmpty ? "" : ",")"]
        for (index, entry) in appearances.enumerated() {
            let appearance = entry.appearance
            let last = index == appearances.count - 1
            func color(_ color: ThemeColor) -> String { Self.quoted(color.description) }
            func box(_ key: String, _ box: ThemeBox) -> String {
                "    \"\(key)\": { \"fill\": \(color(box.fill)), \"edge\": \(color(box.edge)) },"
            }
            let surface = appearance.surface
            let tint = surface.tint.map { " \"tint\": \(color($0))," } ?? ""
            // The optional keys, each written only when the theme sets it, so a file without
            // them writes the same bytes as before they existed.
            var optional: [String] = []
            if let bar = appearance.bar { optional.append("    \"bar\": \(color(bar))") }
            if let field = appearance.field {
                optional.append("    \"field\": { \"fill\": \(color(field.fill)), \"edge\": \(color(field.edge)) }")
            }
            lines += [
                "  \"\(entry.kind.rawValue)\": {",
                "    \"surface\": { \"kind\": \"\(surface.kind.rawValue)\",\(tint) \"fill\": \(color(surface.fill)) },",
                "    \"text\": { \"primary\": \(color(appearance.text.primary)), \"secondary\": \(color(appearance.text.secondary)), \"tertiary\": \(color(appearance.text.tertiary)) },",
                "    \"accent\": \(color(appearance.accent)),",
                box("ownerMessage", appearance.ownerMessage),
                box("agentReply", appearance.agentReply),
                "    \"divider\": \(color(appearance.divider)),",
                "    \"code\": \(color(appearance.code)),",
                box("goAhead", appearance.goAhead),
                "    \"incognito\": { \"tint\": \(color(appearance.incognito.tint)), \"badge\": \(color(appearance.incognito.badge)) }\(optional.isEmpty ? "" : ",")",
            ]
            for (index, line) in optional.enumerated() {
                lines.append(index == optional.count - 1 ? line : line + ",")
            }
            lines.append(last ? "  }" : "  },")
        }
        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }

    static func quoted(_ text: String) -> String {
        JSONValue.string(text).encodedString()
    }
}
