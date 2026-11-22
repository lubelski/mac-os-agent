import Foundation

extension ToolSource {
    public static let actions = ToolSource(id: "actions", title: "Actions")
}

/// Lists the owner's saved actions and the file format, or shows one action's whole file.
public struct ReadActionsTool: AgentTool {
    public static let name = "read_actions"

    public let library: SavedActionLibrary

    public init(library: SavedActionLibrary) {
        self.library = library
    }

    public var source: ToolSource { .actions }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: Self.name,
            description: "List the saved actions and the action file format, or show one action's whole file.",
            parameters: Schema.object([
                "action_id": Schema.nullableString("An action's id, for its whole file. Null for the list."),
            ]))
    }

    public func summary(arguments: JSONValue) -> String {
        arguments["action_id"]?.trimmedString.flatMap { $0.isEmpty ? nil : "Read the action \($0)" } ?? "List the actions"
    }

    /// How the format reads, for the agent.
    static let formatGuide = """
        An action file is JSON with "format": 1, a "name" of up to \(SavedAction.maximumNameLength) characters \
        that the person types to find it, a one-line "description", optional "phrases" (other things they \
        might type for it), "enabled" (true or false), and "steps": a list of up to \(SavedAction.maximumSteps) \
        objects, each with "tool", a tool's name, and "arguments", the whole arguments object for that tool, \
        exactly as you would call it. Steps run in order and stop at the first that fails. Arguments are \
        fixed: there are no parameters.
        """

    public func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        if let id = arguments["action_id"]?.trimmedString, !id.isEmpty {
            guard let entry = library.find(id) else {
                let ids = library.entries().map(\.id)
                return "Error: there is no action \(id). " + (ids.isEmpty ? "There are no actions." : "The actions are \(ids.joined(separator: ", ")).")
            }
            guard let action = entry.action else {
                return "Error: the file for \(entry.id) cannot be read. \(entry.problem ?? "")"
            }
            return "\(entry.id) is at \(entry.fileURL.plainPath). Its file:\n\(action.fileText)"
        }
        let entries = library.entries()
        var lines = [entries.isEmpty
            ? "There are no saved actions yet. They are files in \(library.folder.plainPath)."
            : "Saved actions in \(library.folder.plainPath), as id: name, on or off, description:"]
        for entry in entries {
            if let action = entry.action {
                let phrases = action.phrases.isEmpty ? "" : " Also typed as: \(action.phrases.joined(separator: ", "))."
                lines.append("- \(entry.id): \(action.name), \(action.isEnabled ? "on" : "off"), \(action.description)\(phrases)")
            } else {
                lines.append("- \(entry.id): cannot be read. \(entry.problem ?? "")")
            }
        }
        lines.append("")
        lines.append(Self.formatGuide)
        return lines.joined(separator: "\n")
    }
}

/// Saves or deletes a saved action. A save is checked in full: the file's shape, and each step
/// against its tool's schema, so nothing the app cannot run reaches the folder. Saving needs
/// no go-ahead, since nothing runs until the owner picks the action. Deleting asks first.
public struct ChangeActionTool: AgentTool {
    public static let name = "change_action"
    public static let operations = ["save", "delete"]

    public let library: SavedActionLibrary
    /// The tools a step may call, for checking a save. Read when a save is checked.
    public let tools: @Sendable () -> [ToolDefinition]

    public init(library: SavedActionLibrary, tools: @escaping @Sendable () -> [ToolDefinition]) {
        self.library = library
        self.tools = tools
    }

    public var source: ToolSource { .actions }
    public var goAhead: ToolGoAhead { .sometimes("Asks for a go-ahead before deleting an action.") }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: Self.name,
            description: """
                Save a saved action from a whole action file, or delete one. A save is refused, with the \
                reasons, when the file is malformed or a step does not fit its tool.
                """,
            parameters: Schema.object([
                "operation": ["type": "string", "enum": .array(Self.operations.map { .string($0) })],
                "action_id": Schema.nullableString("The action to replace or delete. Null to save a new action under an id made from its name."),
                "file": Schema.nullableString("For a save, the whole action file as JSON text. Null otherwise."),
            ]))
    }

    public func summary(arguments: JSONValue) -> String {
        let id = arguments["action_id"]?.trimmedString.flatMap { $0.isEmpty ? nil : $0 }
        if arguments["operation"]?.stringValue == "delete" { return id.map { "Delete the action \($0)" } ?? "Delete an action" }
        let name = arguments["file"]?.stringValue.flatMap(JSONValue.parse)?["name"]?.trimmedString
        guard let named = [name, id].compactMap({ $0 }).first(where: { !$0.isEmpty }) else { return "Save an action" }
        return "Save the action \(named)"
    }

    public func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        guard let operation = arguments["operation"]?.stringValue, Self.operations.contains(operation) else {
            return "Error: operation must be one of \(Self.operations.joined(separator: ", "))."
        }
        let id = arguments["action_id"]?.trimmedString.flatMap { $0.isEmpty ? nil : $0 }
        if operation == "save" { return save(file: arguments["file"]?.stringValue, id: id) }

        guard let id else { return "Error: delete needs an action_id." }
        guard let entry = library.find(id) else { return "Error: there is no action \(id). Call \(ReadActionsTool.name) for the list." }
        let approved = await context.confirm(ConfirmationRequest(
            callID: context.callID, kind: .deleteAction, body: .item(name: entry.name, detail: "actions/\(entry.id).json"),
            reason: "removes its file from the actions folder"))
        guard approved else { return "The owner declined. \(entry.name) is still there." }
        if Task.isCancelled { return "The task was stopped before \(entry.name) was deleted." }
        do {
            try library.delete(id: entry.id)
        } catch {
            return "Error: \(String(describing: error))"
        }
        return "Deleted \(entry.name)."
    }

    /// Checks and writes a file. The result says what typing offers it, and which steps run
    /// without the go-ahead they would ask for from the agent.
    func save(file: String?, id: String?) -> String {
        guard let file, !file.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: a save needs the whole action file in file."
        }
        let target: String
        if let id {
            guard library.entry(id: id) != nil else {
                return "Error: there is no action \(id) to replace. Use action_id null to save a new action."
            }
            target = id
        } else {
            let name = JSONValue.parse(file)?["name"]?.trimmedString ?? ""
            target = SavedActionLibrary.identifier(for: name)
        }
        let action: SavedAction
        do {
            action = try SavedAction.parse(file, id: target)
        } catch {
            return "Error: the action was not saved. \(String(describing: error))"
        }
        if id == nil, library.entry(id: target) != nil {
            return "Error: an action with the id \(target) already exists. Pass action_id \(target) to replace it, or choose another name."
        }
        let problems = ActionValidation.problems(action, tools: tools())
        if !problems.isEmpty {
            return (["Error: the action was not saved."] + problems.map { "- \($0)" } + ["Fix those and save again."])
                .joined(separator: "\n")
        }
        do {
            try library.save(action)
        } catch {
            return "Error: \(String(describing: error))"
        }
        var lines = ["Saved \(action.name) as \(action.id). Typing \"\(action.name)\" in the panel offers it, and Return runs it."]
        if !action.isEnabled { lines = ["Saved \(action.name) as \(action.id). It is off, so the panel does not offer it until it is turned on."] }
        for (index, step) in action.steps.enumerated() {
            if let reason = ActionValidation.goAheadNote(step) {
                lines.append("Step \(index + 1) \(reason). It runs without asking when the owner runs the action, since choosing it is the go-ahead.")
            }
        }
        return lines.joined(separator: "\n")
    }
}
