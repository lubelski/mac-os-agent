import Foundation

/// The tools the agent runs with, in the order they are sent to the model.
///
/// The list is put together once, when the app starts, and does not change while it runs.
/// The model sees the tools as part of the prompt prefix, so a list that changed order or
/// contents between requests would throw away the prompt cache. Built-in tools come first, in
/// a fixed order. Tools from other sources, such as MCP servers, go after them, sorted by name,
/// so adding one changes only the end of the list.
public struct ToolRegistry: Sendable {
    public let tools: [any AgentTool]

    /// - Parameters:
    ///   - builtIn: The fixed, ordered built-in list. See `BuiltInTools`.
    ///   - additional: Tools from outside the app, such as MCP servers. Sorted by name after the built-ins.
    public init(builtIn: [any AgentTool], additional: [any AgentTool] = []) {
        let sortedAdditional = additional.sorted { $0.definition.name < $1.definition.name }
        var seen = Set<String>()
        var tools: [any AgentTool] = []
        for tool in builtIn + sortedAdditional where seen.insert(tool.definition.name).inserted {
            tools.append(tool)
        }
        self.tools = tools
    }

    public var definitions: [ToolDefinition] { tools.map(\.definition) }
}

/// The tools that ship with the app. Add new ones at the end, so the order of the existing ones
/// stays the same for a thread that is already cached.
public enum BuiltInTools {
    public static let names = [
        ShellCommandTool.name,
        SearchApplicationsTool.name,
        OpenApplicationTool.name,
        ListRunningApplicationsTool.name,
        LoadSkillTool.name,
    ]

    public static func make(
        applicationWorkspace: any ApplicationWorkspace = SystemApplicationWorkspace(),
        skills: SkillLibrary = SkillLibrary()
    ) -> [any AgentTool] {
        let tools: [any AgentTool] = [
            ShellCommandTool(),
            SearchApplicationsTool(workspace: applicationWorkspace),
            OpenApplicationTool(workspace: applicationWorkspace),
            ListRunningApplicationsTool(workspace: applicationWorkspace),
            LoadSkillTool(library: skills),
        ]
        assert(tools.map(\.definition.name) == names)
        return tools
    }
}
