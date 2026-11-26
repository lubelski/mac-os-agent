import Foundation

/// Settings, Tools, as a stack of panes: what each depth of a `PaneStackPath` shows.
///
/// The base is every group. The path's first entry is a group's id, which opens its tools, and
/// its second a tool's name, which opens that tool's details. Nothing goes deeper.
public enum ToolsPane: Equatable, Sendable {
    case groups
    case group(ToolGroup)
    case tool(ToolSummary, in: ToolGroup)

    /// The pane's title, as a strip's "Back to" button says it.
    public var title: String {
        switch self {
        case .groups: "all tool groups"
        case .group(let group): group.source.title
        case .tool(let tool, _): tool.name
        }
    }
}

extension Array where Element == ToolGroup {
    /// The groups of built-in tools, which come first.
    public var builtIn: [ToolGroup] { filter { !$0.source.isMCPServer } }

    /// One group per MCP server, after the built-in ones.
    public var fromMCPServers: [ToolGroup] { filter(\.source.isMCPServer) }

    /// The group that holds a tool, by the tool's name.
    public func group(holding toolID: ToolSummary.ID) -> ToolGroup? {
        first { $0.tools.contains { $0.id == toolID } }
    }

    /// What the pane at a depth of the path shows, or nil when the path does not reach that
    /// depth or names something that is not there.
    public func pane(at depth: Int, of path: PaneStackPath) -> ToolsPane? {
        guard depth <= path.depth else { return nil }
        switch depth {
        case 0:
            return .groups
        case 1:
            return first { $0.id == path.entry(at: 1) }.map(ToolsPane.group)
        case 2:
            guard let group = first(where: { $0.id == path.entry(at: 1) }),
                  let tool = group.tools.first(where: { $0.id == path.entry(at: 2) }) else { return nil }
            return .tool(tool, in: group)
        default:
            return nil
        }
    }

    /// The longest start of the path that names groups and tools that are here, such as after a
    /// group of MCP tools went away.
    public func validPrefix(of path: PaneStackPath) -> PaneStackPath {
        var depth = 0
        while depth < Swift.min(path.depth, 2), pane(at: depth + 1, of: path) != nil { depth += 1 }
        return path.prefix(depth)
    }

    /// The path that shows an item: a tool's name opens its group and its details, and a
    /// group's id opens its tools. Nil when there is no such tool or group.
    public func path(showing item: String) -> PaneStackPath? {
        if let group = group(holding: item) { return PaneStackPath([group.id, item]) }
        if contains(where: { $0.id == item }) { return PaneStackPath([item]) }
        return nil
    }

    /// The ids the top pane of a path lists, top to bottom, which a swap's direction follows:
    /// the groups as the base shows them, built-in ones first, or a group's tools. A tool's
    /// details list nothing.
    public func rows(of path: PaneStackPath) -> [String] {
        switch pane(at: path.depth, of: path) {
        case .groups: (builtIn + fromMCPServers).map(\.id)
        case .group(let group): group.tools.map(\.id)
        case .tool, nil: []
        }
    }
}

extension ToolGroup {
    /// The number of tools, for a list row: "1 tool" or "7 tools".
    public var countLabel: String {
        tools.count == 1 ? "1 tool" : "\(tools.count) tools"
    }

    /// Whether any of the group's tools can ask for a go-ahead. An MCP tool's go-ahead can change
    /// while the app runs, so the caller can pass the current one.
    public func asksForGoAhead(_ goAhead: (ToolSummary) -> ToolGoAhead = \.goAhead) -> Bool {
        tools.contains { goAhead($0) != .never }
    }
}

extension ToolSource {
    /// The SF Symbol for the source's group in Settings.
    public var symbolName: String {
        if isMCPServer { return "server.rack" }
        if id.hasPrefix("group:") { return "square.stack.3d.up" }
        switch id {
        case ToolSource.builtIn.id: return "terminal"
        case ToolSource.system.id: return "desktopcomputer"
        case ToolSource.reminders.id: return "checklist"
        case ToolSource.calendar.id: return "calendar"
        case ToolSource.memory.id: return "brain"
        case ToolSource.quickActions.id: return "bolt"
        case ToolSource.appearance.id: return "paintpalette"
        case ToolSource.webSearch.id: return "globe"
        case ToolSource.taskLinks.id: return "link"
        case ToolSource.onDemand.id: return "magnifyingglass"
        case RunScriptTool.scripts.id: return "curlybraces"
        default: return "wrench.and.screwdriver"
        }
    }

    /// One line under the group's title in Settings, saying what its tools are for.
    public var summary: String {
        if isMCPServer { return "Tools from the \(title) MCP server" }
        if id.hasPrefix("group:") { return "Tools the agent reaches through use_tool" }
        switch id {
        case ToolSource.builtIn.id: return "Shell commands, apps, history, and skills"
        case ToolSource.system.id: return "Files, the clipboard, quitting apps, and the desktop picture"
        case ToolSource.reminders.id: return "Read and change reminders"
        case ToolSource.calendar.id: return "Read and change calendar events"
        case ToolSource.memory.id: return "What the agent remembers between conversations"
        case ToolSource.quickActions.id: return "Read and save quick actions"
        case ToolSource.appearance.id: return "The panel's themes"
        case ToolSource.webSearch.id: return "Search the web"
        case ToolSource.taskLinks.id: return "Links beside a running task"
        case ToolSource.onDemand.id: return "Find and use the tools kept in groups"
        case RunScriptTool.scripts.id: return "Scripts that call the other tools"
        default: return title
        }
    }
}
