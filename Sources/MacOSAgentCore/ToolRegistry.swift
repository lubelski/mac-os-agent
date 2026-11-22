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
        SearchHistoryTool.name,
        ReadEpisodeTool.name,
        ReadRemindersTool.name,
        ChangeRemindersTool.name,
        ReadEventsTool.name,
        ChangeEventsTool.name,
    ]

    /// - Parameter history: The kept thread, which the history tools search and read. Incognito
    ///   episodes use the same tools, so they can search the past without adding to it.
    /// - Parameters:
    ///   - reminders: Reminders, which the reminder tools read and change.
    ///   - calendar: Calendar, which the event tools read and change.
    public static func make(
        applicationWorkspace: any ApplicationWorkspace = SystemApplicationWorkspace(),
        skills: SkillLibrary = SkillLibrary(),
        history: ThreadStore? = nil,
        reminders: any ReminderStore = EventKitStore.shared,
        calendar: any CalendarStore = EventKitStore.shared
    ) -> [any AgentTool] {
        let reminderIDs = ShortIdentifierTable()
        let eventIDs = ShortIdentifierTable()
        let tools: [any AgentTool] = [
            ShellCommandTool(),
            SearchApplicationsTool(workspace: applicationWorkspace),
            OpenApplicationTool(workspace: applicationWorkspace),
            ListRunningApplicationsTool(workspace: applicationWorkspace),
            LoadSkillTool(library: skills),
            SearchHistoryTool(history: history),
            ReadEpisodeTool(history: history),
            ReadRemindersTool(store: reminders, identifiers: reminderIDs),
            ChangeRemindersTool(store: reminders, identifiers: reminderIDs),
            ReadEventsTool(store: calendar, identifiers: eventIDs),
            ChangeEventsTool(store: calendar, identifiers: eventIDs),
        ]
        assert(tools.map(\.definition.name) == names)
        return tools
    }
}
