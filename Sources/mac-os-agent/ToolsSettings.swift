import AppKit
import MacOSAgentCore
import Observation
import SwiftUI

/// The agent's tools, grouped by source in registry order.
///
/// Tools from MCP servers are more groups from `ToolRegistry.groups`, one per server, after the
/// built-in groups. Their one setting is the go-ahead, kept in `mcp-settings.json` by
/// `MCPSettingsStore`. Built-in tools have no settings here.
@MainActor
@Observable
final class ToolsSettingsModel {
    let groups: [ToolGroup]
    /// Which group and tool are open. See `ToolsSettingsView` for how each level shows.
    var navigation = ToolsNavigation()
    /// For previews and renders: the details pane opens scrolled to its end instead of its top.
    @ObservationIgnored var detailsStartAtEnd = false
    /// The app's access to each kind of personal data the tools use, read again whenever the
    /// window comes forward, since the owner changes it in System Settings.
    private(set) var access: [PrivacyAccessKind: PrivacyAccessStatus] = [:]
    @ObservationIgnored private let gate: any PrivacyAccessGate
    @ObservationIgnored let mcpSettings: MCPSettingsStore?
    /// Changes when an MCP tool's go-ahead does, so the views read the store again.
    private(set) var goAheadRevision = 0
    var errorMessage: String?

    init(registry: ToolRegistry, access gate: any PrivacyAccessGate, mcpSettings: MCPSettingsStore? = nil) {
        groups = registry.groups
        self.gate = gate
        self.mcpSettings = mcpSettings
        reloadAccess()
    }

    var openGroup: ToolGroup? {
        guard let id = navigation.groupID else { return nil }
        return groups.first { $0.id == id }
    }

    var openTool: ToolSummary? {
        guard let id = navigation.toolID else { return nil }
        return openGroup?.tools.first { $0.id == id }
    }

    /// Opens a tool by its name, or a group by its id, as `--preview-item` asks.
    func show(_ item: String) {
        if let group = groups.group(holding: item) {
            navigation.openTool(item, in: group.id)
        } else if groups.contains(where: { $0.id == item }) {
            navigation.openGroup(item)
        }
    }

    /// The tool's go-ahead as it is now. An MCP tool's can change while the app runs.
    func goAhead(of tool: ToolSummary) -> ToolGoAhead {
        _ = goAheadRevision
        guard let mcp = tool.mcp, let mcpSettings else { return tool.goAhead }
        return mcpSettings.goAhead(server: mcp.server, tool: mcp.tool, readOnly: mcp.readOnly).toolGoAhead
    }

    /// Whether any tool in the group can ask for a go-ahead now.
    func asksForGoAhead(_ group: ToolGroup) -> Bool {
        group.asksForGoAhead { goAhead(of: $0) }
    }

    /// Whether an MCP tool asks before each call. The change applies to its next call.
    func setAsks(_ asks: Bool, _ tool: ToolSummary) {
        guard let mcp = tool.mcp, let mcpSettings else { return }
        do {
            try mcpSettings.setGoAhead(asks ? .ask : .dontAsk, server: mcp.server, tool: mcp.tool, readOnly: mcp.readOnly)
            errorMessage = nil
        } catch {
            errorMessage = "Could not save the go-ahead: \(error.localizedDescription)"
        }
        goAheadRevision += 1
    }

    func reloadAccess() {
        for kind in PrivacyAccessKind.allCases {
            access[kind] = gate.status(kind)
        }
    }

    func requestAccess(_ kind: PrivacyAccessKind) {
        Task {
            access[kind] = await gate.requestAccess(kind)
        }
    }
}

/// Settings, Tools: three panes that slide over each other from the right.
///
/// The groups fill the section. Opening a group slides its tools over them, leaving a strip of
/// the groups showing at the left. Opening a tool slides its details over the tools, and the
/// strips narrow: the groups to their icons, the tools to their names. A click on a strip, or
/// Escape, slides the panes above it away. Only the top pane scrolls and takes clicks.
struct ToolsSettingsView: View {
    /// How much of the groups shows beside the tools.
    static let groupsStripWidth: CGFloat = 200
    /// How much of the groups shows beside a tool's details: their icons.
    static let narrowGroupsStripWidth: CGFloat = 56
    /// How much of the tools shows beside a tool's details: the start of their names.
    static let toolsStripWidth: CGFloat = 170
    /// How far each pane sits below the one under it.
    static let paneDrop: CGFloat = 10

    @Bindable var model: ToolsSettingsModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let level = model.navigation.level
        ZStack(alignment: .topLeading) {
            ToolGroupsPane(model: model, showsCaptions: level < .details) { group in
                change { model.navigation.openGroup(group.id) }
            }
            .covered(level > .groups, backLabel: "Back to all tool groups") {
                change { model.navigation.goBack(to: .groups) }
            }

            if let group = model.openGroup {
                ToolListPane(group: group, model: model) { tool in
                    change { model.navigation.openTool(tool.id, in: group.id) }
                }
                .covered(level > .tools, backLabel: "Back to \(group.source.title)") {
                    change { model.navigation.goBack(to: .tools) }
                }
                .paneCard(level: 1)
                .padding(.leading, level == .details ? Self.narrowGroupsStripWidth : Self.groupsStripWidth)
                .padding(.top, Self.paneDrop)
                .transition(paneTransition)
                .zIndex(1)
            }

            if let group = model.openGroup, let tool = model.openTool {
                ToolDetailPane(tool: tool, group: group, model: model)
                    // A new tool starts at the top, with the schema folded.
                    .id(tool.id)
                    .paneCard(level: 2)
                    .padding(.leading, Self.narrowGroupsStripWidth + Self.toolsStripWidth)
                    .padding(.top, 2 * Self.paneDrop)
                    .transition(paneTransition)
                    .zIndex(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .background {
            // Escape slides one pane away. With only the groups showing there is no button, so
            // Escape means what it meant before.
            if level > .groups {
                Button("Back") { change { model.navigation.goBack() } }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
    }

    /// Panes slide in from the right, or fade with Reduce Motion on.
    private var paneTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .trailing)
    }

    private func change(_ body: () -> Void) {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.28, bounce: 0), body)
    }
}

// MARK: - Groups

/// The base pane: every group of tools, built-in ones first, then one per MCP server.
struct ToolGroupsPane: View {
    let model: ToolsSettingsModel
    /// False while only the icons show, so the captions are not cut off at the strip's edge.
    let showsCaptions: Bool
    let open: (ToolGroup) -> Void

    var body: some View {
        ScrollView {
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
                ToolGroupRow(
                    group: group, asks: model.asksForGoAhead(group),
                    isSelected: model.navigation.groupID == group.id
                ) { open(group) }
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
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
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
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background { PaneRowSelection(isSelected: isSelected) }
        .accessibilityLabel(Text(accessibilityText))
        .accessibilityHint(Text("Shows the group's tools"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var accessibilityText: String {
        var text = "\(group.source.title), \(group.countLabel)"
        if asks { text += ", can ask for a go-ahead" }
        return text
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
        default: return .gray
        }
    }
}

// MARK: - Tools

/// The second pane: one group's tools, under the group's title.
struct ToolListPane: View {
    let group: ToolGroup
    let model: ToolsSettingsModel
    let open: (ToolSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneTitle(title: Text(group.source.title).font(.headline), subtitle: group.countLabel)
            Divider().opacity(0.6)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(group.tools) { tool in
                        ToolRow(
                            tool: tool, goAhead: model.goAhead(of: tool),
                            isSelected: model.navigation.toolID == tool.id
                        ) { open(tool) }
                        if tool.id != group.tools.last?.id {
                            PaneRowDivider(leading: ToolRow.inset)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }
}

struct ToolRow: View {
    static let inset: CGFloat = 20

    let tool: ToolSummary
    let goAhead: ToolGoAhead
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tool.name).font(.body.monospaced()).lineLimit(1)
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
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background { PaneRowSelection(isSelected: isSelected) }
        .accessibilityLabel(Text(goAhead != .never ? "\(tool.name), can ask for a go-ahead" : tool.name))
        .accessibilityHint(Text("Shows the tool's details"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Details

/// The top pane: everything about one tool, under its name. The content scrolls under the title.
struct ToolDetailPane: View {
    let tool: ToolSummary
    let group: ToolGroup
    let model: ToolsSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneTitle(title: Text(tool.name).font(.title3.monospaced()), subtitle: group.source.title)
            Divider().opacity(0.6)
            ScrollView {
                ToolDetailView(tool: tool, model: model)
            }
            .defaultScrollAnchor(model.detailsStartAtEnd ? .bottom : .top)
        }
    }
}

struct ToolDetailView: View {
    let tool: ToolSummary
    let model: ToolsSettingsModel
    @State private var showingSchema = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let kind = tool.source.privacyAccess {
                PrivacyAccessView(kind: kind, status: model.access[kind] ?? .notDetermined) {
                    model.requestAccess(kind)
                }
            }
            if let mcp = tool.mcp {
                MCPGoAheadControl(tool: tool, mcp: mcp, model: model)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Asks for a go-ahead").font(.headline)
                    Text("\(tool.goAhead.label). \(tool.goAhead.explanation)")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("In the incognito window").font(.headline)
                Text(incognitoText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Description sent to the model").font(.headline)
                Text(tool.description)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.secondary, in: .rect(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Parameters").font(.headline)
                if tool.parameters.isEmpty {
                    Text("None.").foregroundStyle(.secondary)
                } else {
                    ForEach(tool.parameters) { parameter in
                        ParameterRow(parameter: parameter)
                        if parameter.id != tool.parameters.last?.id { Divider() }
                    }
                }
            }

            DisclosureGroup("JSON Schema as sent", isExpanded: $showingSchema) {
                Text(tool.schemaText)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension ToolDetailView {
    private var incognitoText: String {
        if tool.mcp != nil {
            return "Not available. The incognito window has no tools from MCP servers."
        }
        return BuiltInTools.incognitoNames.contains(tool.name)
            ? "Available. The incognito window has only the three application tools."
            : "Not available. The incognito window only opens apps and answers questions, with the three application tools."
    }
}

// MARK: - Pane parts

/// A pane's pinned title, with a line of secondary text under it.
struct PaneTitle: View {
    let title: Text
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            title.lineLimit(1).truncationMode(.middle)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
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

struct PaneChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

/// A faint line between rows, starting at the rows' text.
struct PaneRowDivider: View {
    let leading: CGFloat

    var body: some View {
        Divider().opacity(0.5).padding(.leading, leading)
    }
}

/// The mark on the open group's or tool's row, which stays while a pane covers it.
struct PaneRowSelection: View {
    let isSelected: Bool

    var body: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.22))
                .padding(.horizontal, 4)
        }
    }
}

/// The hairline along a card's top and leading edges, round at the top-leading corner.
struct PaneCardEdge: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.minY),
            tangent2End: CGPoint(x: rect.minX + radius, y: rect.minY), radius: radius)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

/// A sliding pane's card: a surface a little lighter than the one under it, round at the
/// top-leading corner, square and flush at the bottom and right, with a shadow to the left.
struct PaneCard: ViewModifier {
    static let cornerRadius: CGFloat = 12

    let level: Int
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: Self.cornerRadius, style: .continuous)
        let dark = colorScheme == .dark
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    // Each level lifts toward white: a little in dark mode, more in light mode,
                    // where the window's gray is already light.
                    Color.white.opacity(dark ? 0.045 * Double(level) : 0.4 * Double(level))
                }
            }
            .clipShape(shape)
            .overlay {
                PaneCardEdge(radius: Self.cornerRadius)
                    .offset(x: 0.5 / displayScale, y: 0.5 / displayScale)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1 / displayScale)
            }
            .shadow(color: .black.opacity(dark ? 0.4 : 0.12), radius: 10, x: -4, y: 0)
    }
}

/// A pane under another: dimmed, still, and hidden from accessibility, with its visible strip
/// a button that slides the panes above it away.
struct CoveredPane: ViewModifier {
    let isCovered: Bool
    let backLabel: String
    let goBack: () -> Void

    func body(content: Content) -> some View {
        content
            .scrollDisabled(isCovered)
            .allowsHitTesting(!isCovered)
            .accessibilityHidden(isCovered)
            .overlay {
                if isCovered {
                    Rectangle()
                        .fill(Color.black.opacity(0.3))
                        .contentShape(.rect)
                        .onTapGesture(perform: goBack)
                        .transition(.opacity)
                        .accessibilityElement()
                        .accessibilityLabel(Text(backLabel))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { goBack() }
                }
            }
    }
}

extension View {
    func paneCard(level: Int) -> some View { modifier(PaneCard(level: level)) }

    func covered(_ isCovered: Bool, backLabel: String, goBack: @escaping () -> Void) -> some View {
        modifier(CoveredPane(isCovered: isCovered, backLabel: backLabel, goBack: goBack))
    }
}

// MARK: - Settings

/// An MCP tool's one setting: whether it asks before each call. A change applies to the next
/// call, since it does not change what the model is sent.
struct MCPGoAheadControl: View {
    let tool: ToolSummary
    let mcp: MCPToolReference
    let model: ToolsSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Asks for a go-ahead").font(.headline)
                Spacer()
                Toggle("Ask before each call", isOn: Binding(
                    get: { model.goAhead(of: tool) == .always },
                    set: { model.setAsks($0, tool) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            Text(model.goAhead(of: tool) == .always
                 ? "Asks before each call, with the server, the tool, and the arguments."
                 : "Runs without asking.")
                .fixedSize(horizontal: false, vertical: true)
            Text("\(mcp.defaultExplanation) A change applies to the next call.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        }
    }
}

struct ParameterRow: View {
    let parameter: ToolParameter

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(parameter.name).font(.body.monospaced())
                Text(parameter.type).foregroundStyle(.secondary)
                Spacer()
                Text(parameter.isRequired ? "Required" : "Optional")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !parameter.description.isEmpty {
                Text(parameter.description)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !parameter.allowedValues.isEmpty {
                Text("One of: \(parameter.allowedValues.joined(separator: ", "))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Whether the app may use the personal data a group of tools needs, with a way to change it.
struct PrivacyAccessView: View {
    let kind: PrivacyAccessKind
    let status: PrivacyAccessStatus
    let request: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Access to \(kind.title)").font(.headline)
            Label(status.label, systemImage: status == .fullAccess ? "checkmark.circle" : "exclamationmark.circle")
                .foregroundStyle(status == .fullAccess ? Color.secondary : Color.orange)
            Text(explanation)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if status == .notDetermined {
                    Button("Ask for Access…", action: request)
                }
                Button("Open Privacy Settings") {
                    NSWorkspace.shared.open(kind.systemSettingsURL)
                }
            }
        }
    }
}

extension PrivacyAccessView {
    private var explanation: String {
        switch status {
        case .fullAccess:
            "These tools can read and change \(kind.title.lowercased()). You can turn this off in Privacy & Security."
        case .notDetermined:
            "macOS asks the first time the agent uses one of these tools. You can also ask now."
        case .denied:
            "The agent cannot use these tools until you allow mac-os-agent in Privacy & Security, under \(kind.title)."
        case .writeOnly:
            "The agent can add items but not read them. Allow full access in Privacy & Security, under \(kind.title)."
        case .restricted:
            "Something other than you, such as a management profile, does not allow this on this Mac."
        }
    }
}
