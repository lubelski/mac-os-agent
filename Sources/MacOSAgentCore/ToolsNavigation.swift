import Foundation

/// Where Settings, Tools, is: the list of groups, one group's tools, or one tool's details.
///
/// Each level is a pane that slides over the one before it. Opening a group shows its tools,
/// opening a tool shows its details, and going back slides the top pane away.
public struct ToolsNavigation: Sendable, Equatable {
    public enum Level: Int, Sendable, Comparable, CaseIterable {
        case groups
        case tools
        case details

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The open group's id, at the tools and details levels.
    public private(set) var groupID: ToolGroup.ID?
    /// The open tool's id, at the details level. It is always a tool of the open group.
    public private(set) var toolID: ToolSummary.ID?

    public init() {}

    public var level: Level {
        if toolID != nil { return .details }
        if groupID != nil { return .tools }
        return .groups
    }

    /// Shows a group's tools, over the groups. It closes any tool that was open.
    public mutating func openGroup(_ id: ToolGroup.ID) {
        groupID = id
        toolID = nil
    }

    /// Shows a tool's details, over its group's tools.
    public mutating func openTool(_ id: ToolSummary.ID, in group: ToolGroup.ID) {
        groupID = group
        toolID = id
    }

    /// Slides the top pane away. Returns false when only the groups show, so there was nothing
    /// to close and the key that asked can mean what it meant before.
    @discardableResult
    public mutating func goBack() -> Bool {
        switch level {
        case .groups: return false
        case .tools: groupID = nil
        case .details: toolID = nil
        }
        return true
    }

    /// Slides away every pane above a level, such as on a click on that level's strip.
    public mutating func goBack(to level: Level) {
        while self.level > level { goBack() }
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
}
