import AppKit
import MacOSAgentCore
import SwiftUI

/// Settings, Tools, as a pane stack: the groups, a group's tools, and a tool's details, each
/// sliding over the one before. Behind the pane stack experiment. See `PaneStackView`.
struct ToolsPaneStackView: View {
    /// How much of the groups shows beside a group's tools.
    static let groupsStripWidth: CGFloat = 200
    /// How much of the groups shows beside a tool's details: their icons.
    static let narrowGroupsStripWidth: CGFloat = 56
    /// How much of the tools shows beside a tool's details: the start of their names.
    static let toolsStripWidth: CGFloat = 170

    @Bindable var model: ToolsSettingsModel

    var body: some View {
        PaneStackView(state: model.stack) { strip in
            switch strip.depth {
            case 0: strip.isNearest ? Self.groupsStripWidth : Self.narrowGroupsStripWidth
            default: Self.toolsStripWidth
            }
        } title: { level in
            model.groups.pane(at: level.depth, of: level.path)?.title ?? ""
        } rows: { path in
            model.groups.rows(of: path)
        } pane: { level in
            switch model.groups.pane(at: level.depth, of: level.path) {
            case .groups:
                ToolGroupsPane(model: model, showsCaptions: level.topDepth < 2)
            case .group(let group):
                ToolListPane(group: group, model: model)
            case .tool(let tool, let group):
                // Outer before inner: the group above the tool's name in it. The name the model
                // calls, with the server's prefix, is in Parameters.
                StackPane(scope: group.source.title, title: Text(tool.nameInGroup).font(.title3.monospaced().weight(.semibold))) {
                    ToolDetailSections(tool: tool, model: model)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(tool.id)
            case nil:
                Color.clear
            }
        }
        .onChange(of: model.stack.path, initial: true) { _, path in
            // A path that names a group or tool that is not here, such as one a preview asked
            // for, falls back to the part that is.
            let valid = model.groups.validPrefix(of: path)
            if valid != path { model.stack.path = valid }
        }
    }
}

/// The base pane: every group of tools, built-in ones first, then one per MCP server.
struct ToolGroupsPane: View {
    let model: ToolsSettingsModel
    /// False while only the icons show, so the captions are not cut off at the strip's edge.
    let showsCaptions: Bool

    var body: some View {
        PaneScrollView {
            VStack(alignment: .leading, spacing: 0) {
                section("Built into the app", model.groups.builtIn)
                section("From MCP servers", model.groups.fromMCPServers)
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func section(_ caption: String, _ groups: [ToolGroup]) -> some View {
        if !groups.isEmpty {
            Text(caption)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, ToolGroupRow.inset)
                .padding(.top, 12)
                .padding(.bottom, 4)
                .opacity(showsCaptions ? 1 : 0)
                .accessibilityAddTraits(.isHeader)
            ForEach(groups) { group in
                PaneStackLink(id: group.id) {
                    ToolGroupRow(group: group, asks: model.asksForGoAhead(group))
                }
                .accessibilityHint(Text("Shows the group's tools"))
                if group.id != groups.last?.id {
                    PaneRowDivider(leading: ToolGroupRow.textStart)
                }
            }
        }
    }
}

struct ToolGroupRow: View {
    /// The row's leading padding, which centers the icon tile in the narrow strip.
    static let inset: CGFloat = 12
    static let tileSize: CGFloat = 32
    static let spacing: CGFloat = 12
    /// Where the title starts, and the divider under it.
    static var textStart: CGFloat { inset + tileSize + spacing }

    let group: ToolGroup
    let asks: Bool

    var body: some View {
        HStack(spacing: Self.spacing) {
            ToolGroupIcon(source: group.source, size: Self.tileSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.source.title).fontWeight(.semibold).lineLimit(1)
                Text(group.source.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if asks { GoAheadMarker() }
            Text(group.countLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            PaneChevron()
        }
        .padding(.leading, Self.inset)
        .padding(.trailing, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(asks ? "\(group.source.title), \(group.countLabel), can ask for a go-ahead" : "\(group.source.title), \(group.countLabel)"))
    }
}

/// A group's symbol on a rounded tile of its own color.
struct ToolGroupIcon: View {
    let source: ToolSource
    let size: CGFloat

    var body: some View {
        Image(systemName: source.symbolName)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: .rect(cornerRadius: size * 0.25))
            .accessibilityHidden(true)
    }

    private var tint: Color {
        if source.isMCPServer { return .green }
        if source.id.hasPrefix("group:") { return .brown }
        switch source.id {
        case ToolSource.builtIn.id: return .gray
        case ToolSource.system.id: return .blue
        case ToolSource.reminders.id: return .orange
        case ToolSource.calendar.id: return .red
        case ToolSource.memory.id: return .pink
        case ToolSource.quickActions.id: return .yellow
        case ToolSource.appearance.id: return .purple
        case ToolSource.webSearch.id: return .teal
        case ToolSource.taskLinks.id: return .indigo
        case ToolSource.onDemand.id: return .cyan
        case RunScriptTool.scripts.id: return .mint
        default: return .gray
        }
    }
}

/// The second pane: one group's tools, under the group's title.
struct ToolListPane: View {
    let group: ToolGroup
    let model: ToolsSettingsModel

    var body: some View {
        StackPane(title: Text(group.source.title).font(.headline), subtitle: group.countLabel) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(group.tools) { tool in
                    let goAhead = model.goAhead(of: tool)
                    PaneStackLink(id: tool.id) {
                        ToolStackRow(tool: tool, goAhead: goAhead)
                    }
                    .accessibilityHint(Text("Shows the tool's details"))
                    if tool.id != group.tools.last?.id {
                        PaneRowDivider(leading: ToolStackRow.inset)
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }
}

struct ToolStackRow: View {
    static let inset: CGFloat = 20

    let tool: ToolSummary
    let goAhead: ToolGoAhead

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                // The group is the pane's title, so an MCP tool shows its name on its server.
                Text(tool.nameInGroup).font(.body.monospaced()).lineLimit(1)
                Text(tool.shortDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if goAhead != .never { GoAheadMarker() }
            PaneChevron()
        }
        .padding(.leading, Self.inset)
        .padding(.trailing, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(goAhead != .never ? "\(tool.nameInGroup), can ask for a go-ahead" : tool.nameInGroup))
    }
}

/// The hand the app shows for a tool that can ask for a go-ahead.
struct GoAheadMarker: View {
    var body: some View {
        Image(systemName: "hand.raised")
            .foregroundStyle(.secondary)
            .help("Can ask for a go-ahead")
            .accessibilityLabel("Can ask for a go-ahead")
    }
}
