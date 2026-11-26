import Foundation

/// Where a tool comes from. Tools are shown in Settings grouped by source.
///
/// An MCP server is a source of its own, `ToolSource.mcp("calendar")`, which is
/// `ToolSource(id: "mcp:calendar", title: "calendar")`, set by its tools' `source`.
public struct ToolSource: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    public static let builtIn = ToolSource(id: "built-in", title: "Built In")
}

/// When a tool waits for the owner's go-ahead before it acts.
public enum ToolGoAhead: Sendable, Equatable {
    /// It never asks.
    case never
    /// It asks for some calls. The text says which ones.
    case sometimes(String)
    /// It asks before every call.
    case always
    /// It never runs, since the owner set it to always deny.
    case denied

    /// A short label for a list.
    public var label: String {
        switch self {
        case .never: "No"
        case .sometimes: "Sometimes"
        case .always: "Always"
        case .denied: "Denied"
        }
    }

    /// One sentence for the tool's detail.
    public var explanation: String {
        switch self {
        case .never: "Runs without asking."
        case .sometimes(let text): text
        case .always: "Asks for a go-ahead before every call."
        case .denied: "Never runs. Each call is denied without asking."
        }
    }
}

extension AgentTool {
    public var source: ToolSource { .builtIn }
    public var goAhead: ToolGoAhead { .never }
}

/// One argument of a tool, read from its JSON Schema.
public struct ToolParameter: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    /// The JSON Schema type, such as string or boolean. Several types are joined with "or".
    public var type: String
    public var description: String
    public var isRequired: Bool
    /// The allowed values, when the schema lists them, for the value or for an array's items.
    public var allowedValues: [String]
    /// The value the tool uses when the parameter is left out, when the schema gives one.
    public var defaultValue: String?

    public init(
        name: String, type: String, description: String, isRequired: Bool, allowedValues: [String] = [],
        defaultValue: String? = nil
    ) {
        self.name = name
        self.type = type
        self.description = description
        self.isRequired = isRequired
        self.allowedValues = allowedValues
        self.defaultValue = defaultValue
    }

    /// The top-level properties of an object schema, in the order the model sees them. Requests
    /// encode the schema with sorted keys, so that order is by name.
    public static func list(from schema: JSONValue) -> [ToolParameter] {
        guard case .object(let properties)? = schema["properties"] else { return [] }
        let required = Set((schema["required"]?.arrayValue ?? []).compactMap(\.stringValue))
        return properties.keys.sorted().map { name in
            let property = properties[name] ?? .null
            return ToolParameter(
                name: name,
                type: typeName(of: property),
                description: property["description"]?.stringValue ?? "",
                isRequired: required.contains(name),
                allowedValues: (property["enum"]?.arrayValue ?? property["items"]?["enum"]?.arrayValue ?? [])
                    .map { $0.stringValue ?? $0.encodedString() },
                defaultValue: property["default"].map { $0.stringValue ?? $0.encodedString() })
        }
    }

    /// The parameters as Settings lists them: the required ones first, then the optional
    /// ones, each in the order the model sees them.
    public static func inCallOrder(_ parameters: [ToolParameter]) -> [ToolParameter] {
        parameters.filter(\.isRequired) + parameters.filter { !$0.isRequired }
    }

    static func typeName(of property: JSONValue) -> String {
        switch property["type"] {
        case .string(let type)?:
            if type == "array", let items = property["items"], items["type"] != nil {
                return "array of \(typeName(of: items))"
            }
            return type
        case .array(let types)?:
            return types.compactMap(\.stringValue).joined(separator: " or ")
        default:
            return property["enum"] != nil ? "one of a list" : "any"
        }
    }
}

/// A tool as Settings shows it: what the model is told, and how it behaves.
public struct ToolSummary: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    /// The description exactly as it is sent to the model.
    public var description: String
    public var parameters: [ToolParameter]
    public var goAhead: ToolGoAhead
    public var source: ToolSource
    /// The parameters' JSON Schema, indented for reading.
    public var schemaText: String
    /// Where an MCP tool comes from, for its go-ahead control. Nil for a built-in tool.
    public var mcp: MCPToolReference?

    /// - Parameter source: Where Settings lists it, when not the tool's own source, such as the
    ///   group a tool behind `use_tool` is kept in.
    public init(_ tool: any AgentTool, source: ToolSource? = nil) {
        let definition = tool.definition
        name = definition.name
        description = definition.description
        parameters = ToolParameter.list(from: definition.parameters)
        goAhead = tool.goAhead
        self.source = source ?? tool.source
        schemaText = definition.parameters.prettyEncodedString()
        if let tool = tool as? MCPTool {
            mcp = MCPToolReference(server: tool.server, tool: tool.info.name, readOnly: tool.info.readOnly)
        }
    }

    /// The tool's name where its group is already shown: an MCP tool's name on its server,
    /// such as `create_attachment` for `tracker__create_attachment`, and a built-in tool's
    /// name as the model sees it.
    public var nameInGroup: String { mcp?.tool ?? name }

    /// The first sentence of the description, for a list row.
    public var shortDescription: String {
        let text = AgentInstructions.singleLine(description)
        guard let end = text.range(of: ". ") else { return text }
        return String(text[..<end.lowerBound]) + "."
    }

    /// Whether the description goes on past its first sentence.
    public var descriptionGoesOn: Bool {
        shortDescription != AgentInstructions.singleLine(description)
    }
}

/// An MCP tool by its server and the name its server gave it.
public struct MCPToolReference: Sendable, Equatable {
    public var server: String
    public var tool: String
    public var readOnly: Bool

    public init(server: String, tool: String, readOnly: Bool) {
        self.server = server
        self.tool = tool
        self.readOnly = readOnly
    }

    /// What the tool does without an override, in a sentence for Settings.
    public var defaultExplanation: String {
        readOnly
            ? "By default it runs without asking, since its server marks it read-only."
            : "By default it asks, since its server does not mark it read-only."
    }
}

/// The tools of one source, in registry order.
public struct ToolGroup: Sendable, Equatable, Identifiable {
    public var id: String { source.id }
    public var source: ToolSource
    public var tools: [ToolSummary]
}

extension ToolRegistry {
    /// Each tool's source title by name, such as `run_shell_command` to `Built In`.
    public var sourceTitles: [String: String] {
        Dictionary(tools.map { ($0.definition.name, $0.source.title) }, uniquingKeysWith: { first, _ in first })
    }

    /// The tools grouped by source. Groups come in the order their first tool appears, so the
    /// built-in tools are first, and each group keeps the registry's order. The tools kept in
    /// groups behind `use_tool` follow, one source per group, since the model can call them too.
    public var groups: [ToolGroup] {
        var groups: [ToolGroup] = []
        let inGroups = onDemandGroups.flatMap { group in group.tools.map { ToolSummary($0, source: group.source) } }
        for tool in tools.map({ ToolSummary($0) }) + inGroups {
            if let index = groups.firstIndex(where: { $0.source == tool.source }) {
                groups[index].tools.append(tool)
            } else {
                groups.append(ToolGroup(source: tool.source, tools: [tool]))
            }
        }
        return groups
    }
}
