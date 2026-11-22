import Foundation

/// Checks an action's steps against the tools the app runs them with: each step names a real
/// tool, and its arguments fit that tool's JSON Schema as far as the schema says. The tools'
/// schemas use a small part of JSON Schema (types, properties, required, enum, items, and
/// `additionalProperties: false`), and that is the part checked here. What a tool checks for
/// itself when it runs, such as whether an app exists at a path, is left to the run.
public enum ActionValidation {
    /// Tools an action cannot call. An action that changed actions would be a surprise to
    /// run from a list.
    public static let excludedTools: Set<String> = [ReadActionsTool.name, ChangeActionTool.name]

    /// What is wrong with the steps, one line each, or none.
    public static func problems(_ action: SavedAction, tools: [ToolDefinition]) -> [String] {
        var problems: [String] = []
        let byName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        for (index, step) in action.steps.enumerated() {
            let label = "Step \(index + 1) (\(step.tool))"
            if excludedTools.contains(step.tool) {
                problems.append("\(label): an action cannot call \(step.tool).")
                continue
            }
            guard let tool = byName[step.tool] else {
                problems.append("\(label): there is no tool named \(step.tool).")
                continue
            }
            problems += check(step.arguments, against: tool.parameters, at: "arguments").map { "\(label): \($0)" }
        }
        return problems
    }

    /// Where the value does not fit the schema, one line each.
    static func check(_ value: JSONValue, against schema: JSONValue, at path: String) -> [String] {
        let types = typeNames(of: schema)
        if !types.isEmpty, !types.contains(where: { matches(value, type: $0) }) {
            return ["\(path) should be \(types.joined(separator: " or ")), not \(describe(value))."]
        }
        if let allowed = schema["enum"]?.arrayValue, !allowed.isEmpty, !allowed.contains(value) {
            let list = allowed.map { $0 == .null ? "null" : $0.encodedString() }.joined(separator: ", ")
            return ["\(path) should be one of \(list)."]
        }
        var problems: [String] = []
        switch value {
        case .object(let object):
            let properties: [String: JSONValue]
            if case .object(let declared)? = schema["properties"] { properties = declared } else { properties = [:] }
            for key in (schema["required"]?.arrayValue ?? []).compactMap(\.stringValue) where object[key] == nil {
                problems.append("\(path) is missing \(key).")
            }
            for key in object.keys.sorted() {
                if let property = properties[key] {
                    problems += check(object[key]!, against: property, at: "\(path).\(key)")
                } else if schema["additionalProperties"] == .bool(false) {
                    problems.append("\(path) has \(key), which the tool does not take.")
                }
            }
        case .array(let items):
            if let itemSchema = schema["items"] {
                for (index, item) in items.enumerated() {
                    problems += check(item, against: itemSchema, at: "\(path)[\(index)]")
                }
            }
        default:
            break
        }
        return problems
    }

    private static func typeNames(of schema: JSONValue) -> [String] {
        switch schema["type"] {
        case .string(let name)?: [name]
        case .array(let names)?: names.compactMap(\.stringValue)
        default: []
        }
    }

    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("string", .string), ("boolean", .bool), ("null", .null), ("object", .object), ("array", .array): true
        case ("number", .number): true
        case ("integer", .number(let number)): number.rounded() == number
        default: false
        }
    }

    private static func describe(_ value: JSONValue) -> String {
        switch value {
        case .null: "null"
        case .bool: "a boolean"
        case .number: "a number"
        case .string: "a string"
        case .array: "a list"
        case .object: "an object"
        }
    }

    /// The reason a step would ask for a go-ahead if the agent made the same call, when it is
    /// plain from the arguments alone, such as "deletes files" for a shell command. An action
    /// runs without asking, since the owner chose it from a list. This is said in Settings and
    /// when the action is saved, so the owner knows what they chose.
    public static func goAheadNote(_ step: SavedAction.Step) -> String? {
        switch step.tool {
        case ShellCommandTool.name:
            guard let command = step.arguments["command"]?.stringValue else { return nil }
            return DestructiveCommandCheck.reasonToConfirm(
                command: command, markedDestructive: step.arguments["destructive"]?.boolValue ?? true)
        case QuitOrHideApplicationTool.name:
            return step.arguments["action"]?.stringValue == "hide" ? nil : "quits an app"
        case ChangeRemindersTool.name, ChangeEventsTool.name:
            let changes = step.arguments["changes"]?.arrayValue ?? []
            if changes.contains(where: { $0["delete"]?.boolValue == true }) { return "deletes an item" }
            return changes.count > 1 ? "changes more than one item" : nil
        case ChangeThemeTool.name:
            return step.arguments["action"]?.stringValue == "delete" ? "deletes a theme" : nil
        default:
            return nil
        }
    }
}
