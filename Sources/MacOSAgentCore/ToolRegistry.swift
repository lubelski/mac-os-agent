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

    /// The list with `run_script` at the very end, after the MCP tools, when the scripts
    /// experiment was on at launch. A script can call every tool before it. Off, the list is
    /// unchanged.
    public func addingRunScript(_ on: Bool, helper: URL? = ScriptRunner.bundledHelper) -> ToolRegistry {
        guard on else { return self }
        return ToolRegistry(builtIn: tools + [RunScriptTool(tools: tools, helper: helper)])
    }

    /// The one-line summaries of calls to these tools.
    public var summaries: ToolCallSummaries { ToolCallSummaries(tools) }
}

/// The one-line summary a tool call's row shows, such as the command being run or the app
/// being opened, taken from the tool's own `summary(arguments:)`. A row rebuilt from the
/// saved thread reads the same as it did while the call ran. A call to a tool that no longer
/// exists, or whose arguments cannot be read, shows the tool's name.
///
/// With `showsDisplayNames`, a call to an MCP tool reads by the names people know its server
/// and the tool by, resolved each time a row is built from the literal names the thread keeps,
/// so a rename reaches rows drawn before it. A call to an MCP tool that is no longer listed reads
/// by the names the owner saved for it while they are still in `mcp-settings.json`, and else by
/// its literal names made readable. None of this text is sent to the model.
public struct ToolCallSummaries: Sendable {
    private let tools: [String: any AgentTool]
    /// Whether MCP calls read by display names. For rows a person reads: the panel and History.
    public let showsDisplayNames: Bool
    /// Where the names the owner saved are read for a call to a tool that is no longer listed.
    private let savedNames: MCPSettingsStore?

    /// - Parameter savedNames: The store of the owner's display names. Nil reads the store of the
    ///   first MCP tool in `tools`, and with none, unlisted calls read by their literal names.
    public init(_ tools: [any AgentTool], showsDisplayNames: Bool = false, savedNames: MCPSettingsStore? = nil) {
        self.tools = Dictionary(
            (tools + Self.conditional).map { ($0.definition.name, $0) }, uniquingKeysWith: { first, _ in first })
        self.showsDisplayNames = showsDisplayNames
        self.savedNames = savedNames ?? Self.store(in: tools)
    }

    private init(tools: [String: any AgentTool], showsDisplayNames: Bool, savedNames: MCPSettingsStore?) {
        self.tools = tools
        self.showsDisplayNames = showsDisplayNames
        self.savedNames = savedNames
    }

    private static func store(in tools: [any AgentTool]) -> MCPSettingsStore? {
        for tool in tools {
            if let mcp = tool as? MCPTool { return mcp.pool.settings }
        }
        return nil
    }

    /// The same summaries, with MCP calls read by display names.
    /// - Parameter savedNames: The store of the owner's display names, for calls to tools no
    ///   longer listed. Nil keeps the one these summaries have.
    public func showingDisplayNames(savedNames: MCPSettingsStore? = nil) -> ToolCallSummaries {
        ToolCallSummaries(tools: tools, showsDisplayNames: true, savedNames: savedNames ?? self.savedNames)
    }

    /// The app's built-in tools. Only their summaries are used, which read nothing but the
    /// arguments, so nothing here touches the thread, Reminders, Calendar, the system, or the
    /// network. `search_web` is among them, so its rows read the same whatever the setting.
    public static let builtIn = ToolRegistry(builtIn: BuiltInTools.make(webSearch: SearchWebTool(key: nil))).summaries

    /// Built-in tools whose rows read by their summary even in a run whose list leaves them
    /// out, such as `search_web` after web search was turned off.
    static let conditional: [any AgentTool] = [
        SearchWebTool(key: nil), SetLinksTool(), RunScriptTool(tools: [], helper: nil),
        FindToolsTool(groups: []), UseToolTool(groups: [SettingsToolGroup.make(access: .summariesOnly)]),
    ]

    /// Built-in tools that were renamed, by their old name. A call in the thread made under an
    /// old name still reads as the tool's summary. The model is sent it as it was made.
    public static let formerNames: [String: String] = [
        "read_actions": ReadQuickActionsTool.name,
        "change_action": ChangeQuickActionTool.name,
    ]

    /// The summary of a stored call.
    public func summary(of call: ThreadItem.ToolCall) -> String {
        summary(name: call.name, arguments: call.arguments)
    }

    /// The summary of a call to the tool named `name` with these arguments, as the model wrote them.
    public func summary(name: String, arguments: String) -> String {
        if let text = displaySummary(name: name, arguments: arguments) { return text }
        guard let tool = tools[name] ?? Self.formerNames[name].flatMap({ tools[$0] }), let parsed = JSONValue.parse(arguments), case .object = parsed else { return name }
        // The same text the live row shows, so a shell command keeps its lines for Copy Command.
        let text = tool.summary(arguments: parsed)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? name : text
    }

    /// A call to an MCP tool by display names, with `showsDisplayNames` on: by the tool's own
    /// names when it is listed, and when it is not, by the names the owner saved for it, else the
    /// literal ones made readable. Nil for any other call, and for every call with
    /// `showsDisplayNames` off.
    public func displaySummary(of call: ThreadItem.ToolCall) -> String? {
        displaySummary(name: call.name, arguments: call.arguments)
    }

    /// The words a call's row leads with when they are more than its first word: an MCP tool's
    /// display name, with `showsDisplayNames` on. Nil for any other call.
    public func displayLead(of call: ThreadItem.ToolCall) -> String? {
        guard showsDisplayNames else { return nil }
        if let tool = tools[call.name] { return (tool as? MCPTool)?.displayNames.tool }
        return unlistedNames(ofCallName: call.name)?.tool
    }

    func displaySummary(name: String, arguments: String) -> String? {
        guard showsDisplayNames else { return nil }
        let parsed = JSONValue.parse(arguments) ?? .object([:])
        if let tool = tools[name] {
            return (tool as? MCPTool)?.displaySummary(arguments: parsed)
        }
        guard let names = unlistedNames(ofCallName: name) else { return nil }
        return MCPTool.summary(tool: names.tool, server: names.server, arguments: parsed)
    }

    /// The names for a call to an MCP tool that is not listed: the owner's while they are saved,
    /// else the literal ones made readable. Nil for a built-in tool's former name, and for a
    /// name with no server in it.
    func unlistedNames(ofCallName name: String) -> ConfirmationRequest.DisplayNames? {
        guard Self.formerNames[name] == nil else { return nil }
        if let savedNames { return savedNames.displayNames(ofUnlistedCallName: name) }
        guard let parts = MCPTool.parts(ofCallName: name) else { return nil }
        return ConfirmationRequest.DisplayNames(server: HumanizedName.from(parts.server), tool: HumanizedName.from(parts.tool))
    }
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
        OpenItemTool.name,
        FindFilesTool.name,
        ReadClipboardTool.name,
        WriteClipboardTool.name,
        SetDesktopPictureTool.name,
        QuitOrHideApplicationTool.name,
        ReadThemesTool.name,
        ChangeThemeTool.name,
        ReadQuickActionsTool.name,
        ChangeQuickActionTool.name,
        ReadMemoryTool.name,
        ChangeMemoryTool.name,
    ]

    /// The names in order for a run, with `search_web` after the memory tools when Brave Search
    /// was chosen at launch, `set_links` after it when the panel with bars experiment was on,
    /// and `find_tools` and `use_tool` last when the run has tools in groups.
    public static func names(webSearch: Bool, taskLinks: Bool = false, onDemand: Bool = false) -> [String] {
        (webSearch ? names + [SearchWebTool.name] : names) + (taskLinks ? [SetLinksTool.name] : [])
            + (onDemand ? [FindToolsTool.name, UseToolTool.name] : [])
    }

    /// - Parameters:
    ///   - history: The kept thread, which the history tools search and read.
    ///   - reminders: Reminders, which the reminder tools read and change.
    ///   - calendar: Calendar, which the event tools read and change.
    ///   - system: Files, the clipboard, the desktop picture, and running apps, for the system tools.
    ///   - themes: The panel's themes, which the appearance tools read and write.
    ///   - themePreferences: Where the active theme is kept.
    ///   - actions: The quick actions, which the quick action tools read and write.
    ///   - memories: The memory folder, which the memory tools read and write.
    ///   - webSearch: `search_web`, when Settings, General had Brave Search chosen at launch.
    ///     It goes at the very end, after the memory tools, so every tool before it keeps its
    ///     place. It is not a step a quick action can take.
    ///   - taskLinks: `set_links`, when the panel with bars experiment was on at launch. It goes
    ///     after `search_web`, so every other tool keeps its place with the switch off or on.
    ///   - onDemandGroups: Tools kept in groups, out of the list, when the settings tools
    ///     experiment was on at launch. With any, `find_tools` and `use_tool` go last, so every
    ///     other tool keeps its place with the switch off or on. A script can call `use_tool`,
    ///     since `run_script` comes after every tool.
    public static func make(
        applicationWorkspace: any ApplicationWorkspace = SystemApplicationWorkspace(),
        skills: SkillLibrary = SkillLibrary(),
        history: ThreadStore? = nil,
        reminders: any ReminderStore = EventKitStore.shared,
        calendar: any CalendarStore = EventKitStore.shared,
        system: any SystemControl = SystemControlOnMac(),
        themes: ThemeLibrary = ThemeLibrary(),
        themePreferences: ThemePreferences = ThemePreferences(),
        actions: QuickActionLibrary = QuickActionLibrary(),
        memories: MemoryLibrary = MemoryLibrary(),
        webSearch: SearchWebTool? = nil,
        taskLinks: SetLinksTool? = nil,
        onDemandGroups: [OnDemandToolGroup] = []
    ) -> [any AgentTool] {
        let reminderIDs = ShortIdentifierTable()
        let eventIDs = ShortIdentifierTable()
        var tools: [any AgentTool] = [
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
            OpenItemTool(system: system, applications: applicationWorkspace),
            FindFilesTool(system: system),
            ReadClipboardTool(system: system),
            WriteClipboardTool(system: system),
            SetDesktopPictureTool(system: system),
            QuitOrHideApplicationTool(system: system, applications: applicationWorkspace),
            ReadThemesTool(library: themes, preferences: themePreferences),
            ChangeThemeTool(library: themes, preferences: themePreferences),
        ]
        // A quick action's steps may call any tool before these two, so a save is checked
        // against their definitions.
        let stepTools = tools.map(\.definition)
        tools += [
            ReadQuickActionsTool(library: actions),
            ChangeQuickActionTool(library: actions, tools: { stepTools }),
            ReadMemoryTool(library: memories),
            ChangeMemoryTool(library: memories),
        ]
        if let webSearch { tools.append(webSearch) }
        if let taskLinks { tools.append(taskLinks) }
        if !onDemandGroups.isEmpty {
            tools += [FindToolsTool(groups: onDemandGroups), UseToolTool(groups: onDemandGroups)]
        }
        assert(tools.map(\.definition.name) == names(webSearch: webSearch != nil, taskLinks: taskLinks != nil, onDemand: !onDemandGroups.isEmpty))
        return tools
    }

    /// The tools an incognito window gets, in this order. It is only for opening apps and asking
    /// questions, so it has the three application tools and nothing else: no shell, no personal
    /// data, no system tools, no skills, no themes, and no history. The list is fixed, so its
    /// requests keep one cached prefix of their own.
    public static let incognitoNames = [
        SearchApplicationsTool.name,
        OpenApplicationTool.name,
        ListRunningApplicationsTool.name,
    ]

    /// The incognito window's tools. Made fresh for each incognito conversation, and holding
    /// nothing that writes a file.
    public static func makeIncognito(
        applicationWorkspace: any ApplicationWorkspace = SystemApplicationWorkspace()
    ) -> [any AgentTool] {
        let tools: [any AgentTool] = [
            SearchApplicationsTool(workspace: applicationWorkspace),
            OpenApplicationTool(workspace: applicationWorkspace),
            ListRunningApplicationsTool(workspace: applicationWorkspace),
        ]
        assert(tools.map(\.definition.name) == incognitoNames)
        return tools
    }
}
