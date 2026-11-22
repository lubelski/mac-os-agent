import Foundation

/// The themes that ship in the app, in the order Settings lists them. They are written in the
/// theme file format, so they double as examples of it. Glass is the default and draws the
/// panel exactly as it looked before themes.
public enum BuiltInThemes {
    public static let defaultID = "glass"

    /// Each built-in theme's id and file text.
    static let files: [(id: String, text: String)] = [
        ("glass", """
            {
              "format": 1,
              "name": "Glass",
              "light": {
                "surface": { "kind": "glass", "fill": "#F2F2F4" },
                "text": { "primary": "system-label", "secondary": "system-secondary-label", "tertiary": "system-tertiary-label" },
                "accent": "system-accent",
                "ownerMessage": { "fill": "system-accent 30%", "edge": "#00000000" },
                "agentReply": { "fill": "system-label 13%", "edge": "system-label 10%" },
                "divider": "system-label 14%",
                "code": "system-tertiary-label",
                "goAhead": { "fill": "system-label 8%", "edge": "system-label 16%" },
                "incognito": { "tint": "#5856D624", "badge": "system-label 7%" }
              },
              "dark": {
                "surface": { "kind": "glass", "fill": "#202022" },
                "text": { "primary": "system-label", "secondary": "system-secondary-label", "tertiary": "system-tertiary-label" },
                "accent": "system-accent",
                "ownerMessage": { "fill": "system-accent 30%", "edge": "#00000000" },
                "agentReply": { "fill": "system-label 13%", "edge": "system-label 10%" },
                "divider": "system-label 14%",
                "code": "system-tertiary-label",
                "goAhead": { "fill": "system-label 8%", "edge": "system-label 16%" },
                "incognito": { "tint": "#5E5CE624", "badge": "system-label 7%" }
              }
            }
            """),
        ("tidewater", """
            {
              "format": 1,
              "name": "Tidewater",
              "dark": {
                "surface": { "kind": "blur", "tint": "#0A3B44E8", "fill": "#0C3A42" },
                "text": { "primary": "#EEF8F7", "secondary": "#BBDCDB", "tertiary": "#7FA8A8" },
                "accent": "#5CCFC0",
                "ownerMessage": { "fill": "#5CCFC030", "edge": "#5CCFC04D" },
                "agentReply": { "fill": "#FFFFFF12", "edge": "#FFFFFF1F" },
                "divider": "#FFFFFF26",
                "code": "#7FA8A8",
                "goAhead": { "fill": "#FFFFFF10", "edge": "#FFFFFF2E" },
                "incognito": { "tint": "#6B5BD626", "badge": "#FFFFFF12" }
              }
            }
            """),
        ("graphite", """
            {
              "format": 1,
              "name": "Graphite",
              "dark": {
                "surface": { "kind": "solid", "fill": "#1C1E21" },
                "text": { "primary": "#ECEDEE", "secondary": "#A9AEB4", "tertiary": "#757B82" },
                "accent": "#8AB4F8",
                "ownerMessage": { "fill": "#2E4363", "edge": "#40597D" },
                "agentReply": { "fill": "#272A2E", "edge": "#33373C" },
                "divider": "#33373C",
                "code": "#757B82",
                "goAhead": { "fill": "#24272B", "edge": "#3A3F45" },
                "incognito": { "tint": "#7A66E02E", "badge": "#FFFFFF12" }
              }
            }
            """),
        ("paper", """
            {
              "format": 1,
              "name": "Paper",
              "light": {
                "surface": { "kind": "solid", "fill": "#F6F1E7" },
                "text": { "primary": "#24201A", "secondary": "#5C5548", "tertiary": "#8C8577" },
                "accent": "#2F5D8A",
                "ownerMessage": { "fill": "#DCE4EC", "edge": "#C5D2DF" },
                "agentReply": { "fill": "#ECE5D6", "edge": "#DDD3BF" },
                "divider": "#DDD3BF",
                "code": "#A09886",
                "goAhead": { "fill": "#EEE7D8", "edge": "#D3C8B0" },
                "incognito": { "tint": "#5B4FA81A", "badge": "#24201A0F" }
              }
            }
            """),
        ("high-contrast", """
            {
              "format": 1,
              "name": "High Contrast",
              "light": {
                "surface": { "kind": "solid", "fill": "#FFFFFF" },
                "text": { "primary": "#000000", "secondary": "#2E2E2E", "tertiary": "#595959" },
                "accent": "#0037C8",
                "ownerMessage": { "fill": "#E6ECFF", "edge": "#0037C8" },
                "agentReply": { "fill": "#F2F2F2", "edge": "#000000" },
                "divider": "#6E6E6E",
                "code": "#595959",
                "goAhead": { "fill": "#F2F2F2", "edge": "#0037C8" },
                "incognito": { "tint": "#4B2FD61F", "badge": "#0000001A" }
              },
              "dark": {
                "surface": { "kind": "solid", "fill": "#000000" },
                "text": { "primary": "#FFFFFF", "secondary": "#D6D6D6", "tertiary": "#A8A8A8" },
                "accent": "#FFD60A",
                "ownerMessage": { "fill": "#1A1A1A", "edge": "#FFD60A" },
                "agentReply": { "fill": "#111111", "edge": "#FFFFFF" },
                "divider": "#8A8A8A",
                "code": "#A8A8A8",
                "goAhead": { "fill": "#111111", "edge": "#FFD60A" },
                "incognito": { "tint": "#8E7CFF33", "badge": "#FFFFFF24" }
              }
            }
            """),
        ("ember", """
            {
              "format": 1,
              "name": "Ember",
              "dark": {
                "surface": { "kind": "glass", "tint": "#3B2014DB", "fill": "#341D13" },
                "text": { "primary": "#FBEFE4", "secondary": "#E8CBB0", "tertiary": "#B08E72" },
                "accent": "#F0A05A",
                "ownerMessage": { "fill": "#F0A05A33", "edge": "#F0A05A52" },
                "agentReply": { "fill": "#FFFFFF12", "edge": "#FFFFFF1F" },
                "divider": "#FFE6D026",
                "code": "#B08E72",
                "goAhead": { "fill": "#FFFFFF10", "edge": "#F0A05A4D" },
                "incognito": { "tint": "#7A5BD626", "badge": "#FFFFFF12" }
              }
            }
            """),
    ]

    /// The built-in themes, parsed once. A built-in theme that did not parse would be a bug,
    /// which the tests catch.
    public static let all: [ThemeEntry] = files.map { file in
        do {
            let theme = try Theme.parse(file.text)
            return ThemeEntry(id: file.id, name: theme.name, theme: theme, problem: nil, isBuiltIn: true, fileURL: nil)
        } catch {
            return ThemeEntry(id: file.id, name: file.id, theme: nil, problem: String(describing: error), isBuiltIn: true, fileURL: nil)
        }
    }

    public static var ids: [String] { files.map(\.id) }

    /// The default theme, Glass.
    public static var glass: Theme { all[0].theme! }
}
