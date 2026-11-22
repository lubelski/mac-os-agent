import Foundation

/// Where a tool comes from. Tools are shown in Settings grouped by source.
///
/// Every tool is built in today. An MCP server will be a source of its own, such as
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

    /// A short label for a list.
    public var label: String {
        switch self {
        case .never: "No"
        case .sometimes: "Sometimes"
        case .always: "Always"
        }
    }

    /// One sentence for the tool's detail.
    public var explanation: String {
        switch self {
        case .never: "Runs without asking."
        case .sometimes(let text): text
        case .always: "Asks for a go-ahead before every call."
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
    /// The allowed values, when the schema lists them.
    public var allowedValues: [String]

    public init(name: String, type: String, description: String, isRequired: Bool, allowedValues: [String] = []) {
        self.name = name
        self.type = type
        self.description = description
        self.isRequired = isRequired
        self.allowedValues = allowedValues
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
                allowedValues: (property["enum"]?.arrayValue ?? []).map { $0.stringValue ?? $0.encodedString() })
        }
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

    public init(_ tool: any AgentTool) {
        let definition = tool.definition
        name = definition.name
        description = definition.description
        parameters = ToolParameter.list(from: definition.parameters)
        goAhead = tool.goAhead
        source = tool.source
        schemaText = definition.parameters.prettyEncodedString()
    }

    /// The first sentence of the description, for a list row.
    public var shortDescription: String {
        let text = AgentInstructions.singleLine(description)
        guard let end = text.range(of: ". ") else { return text }
        return String(text[..<end.lowerBound]) + "."
    }
}

/// The tools of one source, in registry order.
public struct ToolGroup: Sendable, Equatable, Identifiable {
    public var id: String { source.id }
    public var source: ToolSource
    public var tools: [ToolSummary]
}

extension ToolRegistry {
    /// The tools grouped by source. Groups come in the order their first tool appears, so the
    /// built-in tools are first, and each group keeps the registry's order.
    public var groups: [ToolGroup] {
        var groups: [ToolGroup] = []
        for tool in tools.map(ToolSummary.init) {
            if let index = groups.firstIndex(where: { $0.source == tool.source }) {
                groups[index].tools.append(tool)
            } else {
                groups.append(ToolGroup(source: tool.source, tools: [tool]))
            }
        }
        return groups
    }
}
