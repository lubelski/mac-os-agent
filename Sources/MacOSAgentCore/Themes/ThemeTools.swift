import Foundation

extension ToolSource {
    public static let appearance = ToolSource(id: "appearance", title: "Appearance")
}

/// Lists the panel's themes, or shows one theme's whole file.
public struct ReadThemesTool: AgentTool {
    public static let name = "read_themes"

    public let library: ThemeLibrary
    public let preferences: ThemePreferences

    public init(library: ThemeLibrary, preferences: ThemePreferences) {
        self.library = library
        self.preferences = preferences
    }

    public var source: ToolSource { .appearance }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: Self.name,
            description: "List the panel's themes and the theme file format, or show one theme's whole file.",
            parameters: Schema.object([
                "theme_id": Schema.nullableString("A theme's id, for its whole file. Null for the list."),
            ]))
    }

    public func summary(arguments: JSONValue) -> String {
        arguments["theme_id"]?.trimmedString.map { "Read the theme \($0)" } ?? "List the themes"
    }

    /// How the format reads, for the agent. Short, since the agent reads a whole file next.
    static let formatGuide = """
        A theme file is JSON with "format": 1, a "name" of up to \(Theme.maximumNameLength) characters, and \
        a "light" appearance, a "dark" one, or both. A theme with only one is always drawn in it. Every \
        appearance has all of these keys:
        - surface: kind (glass, blur, or solid), an optional tint laid over glass or blur whose alpha is \
        its strength, and fill, an opaque #RRGGBB drawn when glass is off.
        - text: primary, secondary, and tertiary.
        - accent, divider, and code (the bracket around code and command output).
        - ownerMessage, agentReply, and goAhead: each a fill and an edge.
        - incognito: tint, laid over the surface, and badge, the fill of the incognito line.
        Colors are #RRGGBB or #RRGGBBAA, where the last pair is the alpha. Primary and secondary text \
        must reach a contrast of \(ThemeContrast.Check.ratioText(ThemeContrast.required)) everywhere they \
        sit. On glass and blur that is checked with the tint over a black and over a white backdrop, so \
        light text needs a dark tint with a high alpha.
        """

    public func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        if let id = arguments["theme_id"]?.trimmedString, !id.isEmpty {
            guard let entry = library.find(id) else {
                return "Error: there is no theme \(id). The themes are \(library.entries().map(\.id).joined(separator: ", "))."
            }
            guard let theme = entry.theme else {
                return "Error: the file for \(entry.id) cannot be read. \(entry.problem ?? "")"
            }
            let kind = entry.isBuiltIn ? "a built-in theme, which cannot be changed" : "one of the owner's themes"
            return "\(entry.id) is \(kind). Its file:\n\(theme.fileText)"
        }
        let active = preferences.themeID
        let entries = library.entries()
        let activeName = entries.first { $0.id == active }?.name ?? active
        var lines = [
            "The panel uses \(activeName) (\(active)). Use glass is \(preferences.usesGlass ? "on" : "off") in Settings.",
            "Themes, as id: name, where from, appearances:",
        ]
        for entry in entries {
            if let theme = entry.theme {
                lines.append("- \(entry.id): \(theme.name), \(entry.isBuiltIn ? "built in" : "made by the owner or you"), \(theme.appearanceSummary)")
            } else {
                lines.append("- \(entry.id): cannot be read. \(entry.problem ?? "")")
            }
        }
        lines.append("")
        lines.append(Self.formatGuide)
        return lines.joined(separator: "\n")
    }
}

/// Saves, applies, or deletes a theme. Every save is checked in full, so a file the agent
/// writes is never malformed, and text that is hard to read is refused with the pairs of
/// colors that fail. Deleting asks the owner first.
public struct ChangeThemeTool: AgentTool {
    public static let name = "change_theme"
    public static let actions = ["save", "save_and_apply", "apply", "delete"]

    public let library: ThemeLibrary
    public let preferences: ThemePreferences

    public init(library: ThemeLibrary, preferences: ThemePreferences) {
        self.library = library
        self.preferences = preferences
    }

    public var source: ToolSource { .appearance }
    public var goAhead: ToolGoAhead { .sometimes("Asks for a go-ahead before deleting a theme.") }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: Self.name,
            description: """
                Save a theme from a whole theme file, apply one to the panel, or delete one. A save is \
                refused, with the reason, when the file is malformed or hard to read. Built-in themes \
                cannot be changed.
                """,
            parameters: Schema.object([
                "action": [
                    "type": "string", "enum": .array(Self.actions.map { .string($0) }),
                    "description": "save_and_apply also applies the saved theme.",
                ],
                "theme_id": Schema.nullableString("The theme to apply, delete, or replace. Null to save a new theme under an id made from its name."),
                "file": Schema.nullableString("For a save, the whole theme file as JSON text. Null otherwise."),
            ]))
    }

    public func summary(arguments: JSONValue) -> String {
        let id = arguments["theme_id"]?.trimmedString
        switch arguments["action"]?.stringValue {
        case "apply": return "Apply the theme \(id ?? "")"
        case "delete": return "Delete the theme \(id ?? "")"
        default:
            let name = arguments["file"]?.stringValue.flatMap(JSONValue.parse)?["name"]?.stringValue
            return "Save the theme \(name ?? id ?? "")"
        }
    }

    public func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        guard let action = arguments["action"]?.stringValue, Self.actions.contains(action) else {
            return "Error: action must be one of \(Self.actions.joined(separator: ", "))."
        }
        let id = arguments["theme_id"]?.trimmedString.flatMap { $0.isEmpty ? nil : $0 }
        switch action {
        case "save", "save_and_apply":
            return save(file: arguments["file"]?.stringValue, id: id, apply: action == "save_and_apply")
        case "apply":
            guard let id else { return "Error: apply needs a theme_id." }
            guard let entry = library.find(id) else { return missing(id) }
            guard entry.theme != nil else { return "Error: the file for \(entry.id) cannot be read, so it cannot be applied. \(entry.problem ?? "")" }
            preferences.setThemeID(entry.id)
            return "Applied \(entry.name) to the panel."
        default:
            guard let id else { return "Error: delete needs a theme_id." }
            guard let entry = library.find(id) else { return missing(id) }
            if entry.isBuiltIn { return "Error: \(entry.name) is a built-in theme, which cannot be deleted." }
            let approved = await context.confirm(ConfirmationRequest(
                callID: context.callID, kind: .deleteTheme, body: .item(name: entry.name, detail: "themes/\(entry.id).json"),
                reason: "removes its file from the themes folder"))
            guard approved else { return "The owner declined. \(entry.name) is still there." }
            if Task.isCancelled { return "The task was stopped before \(entry.name) was deleted." }
            do {
                try library.delete(id: entry.id)
            } catch {
                return "Error: \(String(describing: error))"
            }
            if preferences.themeID == entry.id {
                preferences.setThemeID(BuiltInThemes.defaultID)
                return "Deleted \(entry.name). It was the panel's theme, so the panel is back on Glass."
            }
            return "Deleted \(entry.name)."
        }
    }

    private func missing(_ id: String) -> String {
        "Error: there is no theme \(id). Call \(ReadThemesTool.name) for the list."
    }

    private func save(file: String?, id: String?, apply: Bool) -> String {
        guard let file, !file.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: a save needs the whole theme file in file."
        }
        let theme: Theme
        do {
            theme = try Theme.parse(file)
        } catch {
            return "Error: the theme was not saved. \(String(describing: error))"
        }
        let failures = ThemeContrast.failures(theme)
        if !failures.isEmpty {
            let count = failures.count == 1 ? "1 pair of colors is" : "\(failures.count) pairs of colors are"
            var lines = ["Error: the theme was not saved. \(count) too hard to read:"]
            lines += failures.prefix(12).map { "- \($0.failureText)" }
            if failures.count > 12 { lines.append("- and \(failures.count - 12) more like them.") }
            lines.append("Change those colors and save again.")
            return lines.joined(separator: "\n")
        }
        let target = id ?? ThemeLibrary.identifier(for: theme.name)
        if let existing = library.entry(id: target), existing.isBuiltIn {
            return "Error: \(existing.name) is a built-in theme, which cannot be changed. Save it under another name, with theme_id null."
        }
        if id != nil, library.entry(id: target) == nil {
            return "Error: there is no theme \(target) to replace. Use theme_id null to save a new theme."
        }
        let saved: String
        do {
            saved = try library.save(theme, id: target)
        } catch {
            return "Error: \(String(describing: error))"
        }
        guard apply else { return "Saved \(theme.name) as \(saved)." }
        preferences.setThemeID(saved)
        return "Saved \(theme.name) as \(saved) and applied it to the panel."
    }
}
