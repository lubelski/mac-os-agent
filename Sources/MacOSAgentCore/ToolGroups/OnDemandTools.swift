import Foundation

/// Tools kept out of the tool list, in a group the model reaches through `find_tools` and
/// `use_tool`. The instructions list each group in one line, so a group costs the prompt a
/// line instead of every tool's description and schema, and the tool list stays the same
/// whatever the group holds.
public struct OnDemandToolGroup: Sendable {
    /// The name the model passes to `find_tools` and `use_tool`, such as `settings`.
    public var name: String
    /// What the group is for, in one line, as the instructions list it.
    public var summary: String
    public var tools: [any AgentTool]

    public init(name: String, summary: String, tools: [any AgentTool]) {
        self.name = name
        self.summary = summary
        self.tools = tools
    }

    /// Where the group's tools are listed in Settings, Tools.
    public var source: ToolSource {
        ToolSource(id: "group:\(name)", title: "\(name.prefix(1).uppercased() + name.dropFirst()) Group")
    }

    func tool(named name: String) -> (any AgentTool)? {
        tools.first { $0.definition.name == name }
    }

    /// The group as the instructions list it.
    public var listing: AgentInstructions.ToolGroupSummary {
        AgentInstructions.ToolGroupSummary(name: name, summary: summary)
    }
}

/// Where `find_tools` and `use_tool` are listed in Settings, Tools.
extension ToolSource {
    public static let onDemand = ToolSource(id: "on-demand", title: "Tools in Groups")
}

/// `find_tools`: lists the tools in one group, with their full definitions when there are
/// few or the model asked for some by name or words.
public struct FindToolsTool: AgentTool {
    public static let name = "find_tools"
    /// A group this size or smaller is always returned whole, with every definition.
    public static let wholeGroupLimit = 4
    /// The most full definitions one query returns.
    public static let matchLimit = 8

    public let groups: [OnDemandToolGroup]

    public init(groups: [OnDemandToolGroup]) {
        self.groups = groups
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: Self.name,
            description: """
                Lists the tools in one of the groups named in your instructions. A small group, or a \
                query, returns the tools with their full descriptions and parameters, ready for \
                use_tool. A large group with a null query returns each tool's name and first sentence.
                """,
            parameters: [
                "type": "object",
                "properties": [
                    "group": ["type": "string", "description": "The group's name, as your instructions list it."],
                    "query": [
                        "type": ["string", "null"],
                        "description": "A tool's name, or words to match against the tools' names and descriptions. Null for the whole group.",
                    ],
                ],
                "required": ["group", "query"],
                "additionalProperties": false,
            ])
    }

    public var source: ToolSource { .onDemand }

    public func summary(arguments: JSONValue) -> String {
        let group = arguments["group"]?.stringValue ?? ""
        let query = arguments["query"]?.stringValue.map(AgentInstructions.singleLine) ?? ""
        return query.isEmpty ? "Find tools in \(group)" : "Find tools in \(group): \(query)"
    }

    public func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        let name = arguments["group"]?.stringValue ?? ""
        guard let group = groups.first(where: { $0.name == name }) else {
            return "Error: there is no group named \"\(name)\". " + Self.groupList(groups)
        }
        let query = arguments["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let definitions = group.tools.map(\.definition)
        if query.isEmpty {
            if definitions.count <= Self.wholeGroupLimit { return Self.full(definitions) }
            return definitions.map { "\($0.name): \(Self.firstSentence($0.description))" }.joined(separator: "\n")
                + "\n\nCall find_tools again with a tool's name as the query for its parameters."
        }
        let matches = Self.rank(definitions, query: query)
        if matches.isEmpty {
            if definitions.count <= Self.wholeGroupLimit { return Self.full(definitions) }
            return "No tool in \(name) matches \"\(query)\". Call find_tools with a null query to list them all."
        }
        return Self.full(Array(matches.prefix(Self.matchLimit)))
    }

    /// The tools that match the query, best first: a tool whose name is the query, then by
    /// how many of the query's words its name and description hold, with words in the name
    /// counted ahead of words only in the description. A tool matching no word is left out.
    static func rank(_ definitions: [ToolDefinition], query: String) -> [ToolDefinition] {
        let exact = query.lowercased()
        let words = Set(words(in: query))
        let scored = definitions.enumerated().compactMap { index, definition -> (score: (Int, Int, Int), index: Int, definition: ToolDefinition)? in
            let name = definition.name.lowercased()
            let nameWords = Set(Self.words(in: definition.name))
            let textWords = Set(Self.words(in: definition.description)).union(nameWords)
            let isExact = name == exact ? 1 : 0
            let inName = words.filter { nameWords.contains($0) || name.contains($0) }.count
            let inText = words.filter { textWords.contains($0) }.count
            guard isExact + inName + inText > 0 else { return nil }
            return ((isExact, inName, inText), index, definition)
        }
        return scored.sorted { left, right in
            left.score != right.score ? left.score > right.score : left.index < right.index
        }.map(\.definition)
    }

    static func words(in text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 }
    }

    static func full(_ definitions: [ToolDefinition]) -> String {
        JSONValue.array(definitions.map { definition in
            ["name": .string(definition.name), "description": .string(definition.description), "parameters": definition.parameters]
        }).prettyEncodedString()
    }

    static func groupList(_ groups: [OnDemandToolGroup]) -> String {
        groups.isEmpty ? "There are no groups." : "The groups are: \(groups.map(\.name).joined(separator: ", "))."
    }

    /// The description's first sentence, for a list of names.
    static func firstSentence(_ text: String) -> String {
        let line = AgentInstructions.singleLine(text)
        if let end = line.range(of: ". ") { return String(line[..<end.lowerBound]) + "." }
        return line.count > 160 ? String(line.prefix(159)) + "…" : line
    }
}

/// `use_tool`: calls one tool from a group, through the tool's own `run` with the same
/// context, so it asks for the owner's go-ahead exactly when the tool asks, on the row of the
/// `use_tool` call.
public struct UseToolTool: AgentTool {
    public static let name = "use_tool"

    public let groups: [OnDemandToolGroup]

    public init(groups: [OnDemandToolGroup]) {
        self.groups = groups
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: Self.name,
            description: """
                Calls a tool from one of the groups named in your instructions, by the name find_tools \
                gave, with arguments that match the parameters find_tools gave.
                """,
            parameters: [
                "type": "object",
                "properties": [
                    "group": ["type": "string", "description": "The group's name."],
                    "name": ["type": "string", "description": "The tool's name in the group."],
                    "arguments": ["type": "object", "description": "The tool's arguments, as its parameters describe them."],
                ],
                "required": ["group", "name", "arguments"],
            ],
            // The arguments are the inner tool's, which this schema cannot spell out.
            strict: false)
    }

    public var source: ToolSource { .onDemand }

    public var goAhead: ToolGoAhead {
        .sometimes("Never asks for itself. The tool it calls asks exactly when that tool asks.")
    }

    /// The called tool's own summary, so the row reads as the call it makes, or the tool and
    /// its group when the tool is not known in this run.
    public func summary(arguments: JSONValue) -> String {
        let groupName = arguments["group"]?.stringValue ?? ""
        let name = arguments["name"]?.stringValue ?? ""
        let inner = arguments["arguments"] ?? .object([:])
        if let tool = groups.first(where: { $0.name == groupName })?.tool(named: name), case .object = inner {
            let text = tool.summary(arguments: inner)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        return name.isEmpty ? Self.name : "\(name) in \(groupName)"
    }

    public func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        let groupName = arguments["group"]?.stringValue ?? ""
        let name = arguments["name"]?.stringValue ?? ""
        guard let group = groups.first(where: { $0.name == groupName }) else {
            return "Error: there is no group named \"\(groupName)\". " + FindToolsTool.groupList(groups)
                + " Call find_tools with a group's name to see its tools."
        }
        guard let tool = group.tool(named: name) else {
            return "Error: the \(groupName) group has no tool named \"\(name)\". Call find_tools with the group \"\(groupName)\" to see its tools."
        }
        let inner = arguments["arguments"] ?? .object([:])
        guard case .object = inner else {
            return "Error: arguments should be an object, as \(name)'s parameters describe. Call find_tools with \"\(name)\" as the query to see them."
        }
        return await tool.run(arguments: inner, context: context)
    }
}

extension ToolRegistry {
    /// The groups behind `use_tool` in this run's list. Empty when the list has no `use_tool`.
    public var onDemandGroups: [OnDemandToolGroup] {
        tools.compactMap { $0 as? UseToolTool }.first?.groups ?? []
    }
}
