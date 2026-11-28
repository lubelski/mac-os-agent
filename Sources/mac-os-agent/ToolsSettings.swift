import AppKit
import MacOSAgentCore
import Observation
import SwiftUI

/// The agent's tools, grouped by source in registry order.
///
/// Tools from MCP servers are more groups from `ToolRegistry.groups`, one per server, after the
/// built-in group. Their one setting is the go-ahead, kept in `mcp-settings.json` by
/// `MCPSettingsStore`. Built-in tools have no settings here.
@MainActor
@Observable
final class ToolsSettingsModel {
    let groups: [ToolGroup]
    /// Where the pane stack is: `[group]` or `[group, tool]`. Kept here so the stack and its
    /// scroll places last while the window is open.
    let stack = PaneStackState()
    /// Which text a tool's details show, its description or its schema. Kept here, so moving
    /// from tool to tool keeps it while the window is open.
    var textTab: ToolTextTab = .description
    /// The app's access to each kind of personal data the tools use, read again whenever the
    /// window comes forward, since the owner changes it in System Settings.
    private(set) var access: [PrivacyAccessKind: PrivacyAccessStatus] = [:]
    @ObservationIgnored private let gate: any PrivacyAccessGate
    @ObservationIgnored let mcpSettings: MCPSettingsStore?
    /// Changes when an MCP tool's go-ahead does, so the views read the store again.
    private(set) var goAheadRevision = 0
    @ObservationIgnored private var goAheadObserver: (any NSObjectProtocol)?
    /// Changes when an MCP server's or tool's display name does, set in MCP Servers.
    private(set) var namesRevision = 0
    @ObservationIgnored private var namesObserver: (any NSObjectProtocol)?
    var errorMessage: String?

    init(registry: ToolRegistry, access gate: any PrivacyAccessGate, mcpSettings: MCPSettingsStore? = nil) {
        groups = registry.groups
        self.gate = gate
        self.mcpSettings = mcpSettings
        reloadAccess()
        if let mcpSettings {
            // Always Allow or Always Deny on a go-ahead card changes a tool's go-ahead while
            // this pane may be open.
            goAheadObserver = NotificationCenter.default.addObserver(
                forName: MCPSettingsStore.goAheadDidChange, object: mcpSettings, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.goAheadRevision += 1 }
            }
            namesObserver = NotificationCenter.default.addObserver(
                forName: MCPSettingsStore.namesDidChange, object: mcpSettings, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.namesRevision += 1 }
            }
        }
    }

    isolated deinit {
        if let goAheadObserver { NotificationCenter.default.removeObserver(goAheadObserver) }
        if let namesObserver { NotificationCenter.default.removeObserver(namesObserver) }
    }

    // MARK: - Display names

    /// An MCP tool's display name: the owner's, or its name on its server made readable. Nil
    /// for a built-in tool, which has none.
    func displayName(of tool: ToolSummary) -> String? {
        _ = namesRevision
        guard let mcp = tool.mcp else { return nil }
        return mcpSettings?.toolDisplayName(server: mcp.server, tool: mcp.tool) ?? HumanizedName.from(mcp.tool)
    }

    /// A group's title: an MCP server's display name, or a built-in group's title.
    func title(of group: ToolGroup) -> String {
        title(of: group.source)
    }

    func title(of source: ToolSource) -> String {
        _ = namesRevision
        guard source.isMCPServer else { return source.title }
        return mcpSettings?.serverDisplayName(source.title) ?? HumanizedName.from(source.title)
    }

    /// The tool's go-ahead as it is now. An MCP tool's can change while the app runs.
    func goAhead(of tool: ToolSummary) -> ToolGoAhead {
        _ = goAheadRevision
        guard let mcp = tool.mcp, let mcpSettings else { return tool.goAhead }
        return mcpSettings.goAhead(server: mcp.server, tool: mcp.tool, readOnly: mcp.readOnly).toolGoAhead
    }

    /// An MCP tool's go-ahead as the owner chose it, or nil for a built-in tool.
    func mcpGoAhead(of tool: ToolSummary) -> MCPGoAhead? {
        _ = goAheadRevision
        guard let mcp = tool.mcp, let mcpSettings else { return nil }
        return mcpSettings.goAhead(server: mcp.server, tool: mcp.tool, readOnly: mcp.readOnly)
    }

    /// Sets an MCP tool to ask each time, always allow, or always deny. The change applies to
    /// its next call.
    func setGoAhead(_ value: MCPGoAhead, _ tool: ToolSummary) {
        guard let mcp = tool.mcp, let mcpSettings else { return }
        do {
            try mcpSettings.setGoAhead(value, server: mcp.server, tool: mcp.tool, readOnly: mcp.readOnly)
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

    /// Opens a tool's details, or a group's tools, in the pane stack, as `--preview-item` asks.
    /// An item that is not here changes nothing.
    func showInStack(_ item: String) {
        if let path = groups.path(showing: item) { stack.path = path }
    }

    /// A path that names a group or tool that is not here, such as one a preview asked for,
    /// falls back to the part that is.
    func fallBack() {
        let valid = groups.validPrefix(of: stack.path)
        if valid != stack.path { stack.path = valid }
    }

    /// Whether any tool in the group can ask for a go-ahead now.
    func asksForGoAhead(_ group: ToolGroup) -> Bool {
        group.asksForGoAhead { goAhead(of: $0) }
    }
}

/// Settings, Tools: the groups, a group's tools, and a tool's details, as a pane stack. See
/// `ToolsPaneStackView`.
struct ToolsSettingsView: View {
    @Bindable var model: ToolsSettingsModel

    var body: some View {
        ToolsPaneStackView(model: model)
    }
}

/// Which of the texts the model is sent the tool's details show.
enum ToolTextTab: String, CaseIterable {
    case description
    case schema

    var title: String {
        switch self {
        case .description: "Description"
        case .schema: "JSON Schema"
        }
    }
}

/// Everything about a tool under its name: what it is for in a sentence, then what the owner
/// decides (its access and its go-ahead), then where it runs, then what the agent sends it, and
/// last the long texts the model is sent, its description and its schema, one at a time.
struct ToolDetailSections: View {
    let tool: ToolSummary
    let model: ToolsSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            // What the tool is for, in its own first sentence, before anything about it. A
            // description of one sentence is left to its box at the end, so it shows once.
            if !tool.shortDescription.isEmpty, tool.descriptionGoesOn {
                Text(tool.shortDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
            if let kind = tool.source.privacyAccess {
                PrivacyAccessView(kind: kind, status: model.access[kind] ?? .notDetermined) {
                    model.requestAccess(kind)
                }
            }
            if let mcp = tool.mcp {
                MCPGoAheadControl(tool: tool, mcp: mcp, model: model)
                ToolDetailBox {
                    ToolFactRow(label: "Incognito window", fact: incognito)
                }
            } else {
                // A built-in tool's go-ahead cannot be changed, so it is a fact like the other.
                ToolDetailBox {
                    ToolFactRow(label: "Go-ahead", fact: Self.builtInGoAhead(tool.goAhead))
                    ToolDetailDivider()
                    ToolFactRow(label: "Incognito window", fact: incognito)
                }
            }
            ToolParametersSection(tool: tool)
            ToolTextSection(tool: tool, model: model)
        }
    }
}

extension ToolDetailSections {
    private var incognito: ToolFact {
        if tool.mcp != nil {
            return ToolFact(symbol: "minus.circle", value: "Not available", detail: "The incognito window has no tools from MCP servers.")
        }
        return BuiltInTools.incognitoNames.contains(tool.name)
            ? ToolFact(symbol: "checkmark.circle", value: "Available", detail: "The incognito window has only the three application tools.")
            : ToolFact(
                symbol: "minus.circle", value: "Not available",
                detail: "The incognito window only opens apps and answers questions, with the three application tools.")
    }

    /// A built-in tool's go-ahead, which the owner cannot change.
    static func builtInGoAhead(_ goAhead: ToolGoAhead) -> ToolFact {
        switch goAhead {
        case .never: ToolFact(symbol: "checkmark.circle", value: "Never asks", detail: nil)
        case .sometimes(let text): ToolFact(symbol: "hand.raised", value: "Asks for some calls", detail: text)
        case .always: ToolFact(symbol: "hand.raised", value: "Asks before every call", detail: nil)
        case .denied: ToolFact(symbol: "nosign", value: "Never runs", detail: "Each call is denied without asking.")
        }
    }
}

/// An MCP tool's one setting: ask each time, always allow, or always deny, all three in view
/// with the chosen one marked. A change applies to the next call, since it does not change what
/// the model is sent. A denied tool stays in the model's list, and a call to it is answered
/// without asking.
struct MCPGoAheadControl: View {
    let tool: ToolSummary
    let mcp: MCPToolReference
    let model: ToolsSettingsModel

    static func explanation(_ value: MCPGoAhead) -> String {
        switch value {
        case .ask: "Asks before each call, with the server, the tool, and the arguments."
        case .allow: "Runs without asking."
        case .deny: "Never runs. Each call is denied without asking, and the agent is told you set it that way."
        }
    }

    var body: some View {
        let value = model.mcpGoAhead(of: tool) ?? .defaultValue(readOnly: mcp.readOnly)
        let defaultValue = MCPGoAhead.defaultValue(readOnly: mcp.readOnly)
        ToolDetailSection("Go-ahead", footer: "\(mcp.defaultExplanation) A change applies to the next call.") {
            ToolDetailBox {
                ForEach(MCPGoAhead.allCases, id: \.self) { choice in
                    if choice != MCPGoAhead.allCases.first { ToolDetailDivider() }
                    GoAheadChoiceRow(
                        title: choice.title, detail: Self.explanation(choice),
                        isSelected: choice == value, isDefault: choice == defaultValue
                    ) {
                        model.setGoAhead(choice, tool)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Go-ahead")
            if let error = model.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        }
    }
}

/// One go-ahead choice: a mark that fills when it is chosen, its name, and what it does. The
/// chosen row is tinted too. Its weight never changes, so choosing does not shift the text.
struct GoAheadChoiceRow: View {
    let title: String
    let detail: String
    let isSelected: Bool
    let isDefault: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .frame(width: ToolDetailRow.symbolWidth)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(title)
                        if isDefault { ToolDetailTag(text: "Default") }
                    }
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, ToolDetailRow.inset)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { if isSelected { Color.accentColor.opacity(0.12) } }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(isDefault ? "\(title), the default" : title))
        .accessibilityHint(Text(detail))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// What the agent sends the tool: the call as the model makes it, with its full name, then each
/// parameter with its name first and the facts about it quieter.
struct ToolParametersSection: View {
    let tool: ToolSummary

    var body: some View {
        let parameters = ToolParameter.inCallOrder(tool.parameters)
        ToolDetailSection("Parameters") {
            Text(Self.count(parameters))
                .font(.caption)
                .foregroundStyle(.secondary)
        } content: {
            ToolDetailBox {
                CallSignature(name: tool.name, parameters: parameters)
                    .padding(.horizontal, ToolDetailRow.inset)
                    .padding(.vertical, 9)
                    .background(.primary.opacity(0.03))
                ForEach(parameters) { parameter in
                    ToolDetailDivider()
                    ParameterRow(parameter: parameter)
                }
            }
        }
    }

    static func count(_ parameters: [ToolParameter]) -> String {
        let required = parameters.filter(\.isRequired).count
        let optional = parameters.count - required
        switch (required, optional) {
        case (0, 0): return "None"
        case (_, 0): return required == 1 ? "1, required" : "\(required), all required"
        case (0, _): return optional == 1 ? "1, optional" : "\(optional), all optional"
        default: return "\(required) required, \(optional) optional"
        }
    }
}

/// `server__tool(first, second, third?)`: the call as the model makes it, optional parameters
/// marked with a question mark. Selectable, so the full name can be copied.
struct CallSignature: View {
    let name: String
    let parameters: [ToolParameter]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(signature)
            .font(.system(size: 11.5, design: .monospaced))
            .lineSpacing(2)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(Text("Called as \(name)"))
    }

    private var signature: AttributedString {
        let dark = colorScheme == .dark
        func part(_ text: String, _ kind: CodeHighlighting.Kind?) -> AttributedString {
            var part = AttributedString(text)
            if let kind { part.foregroundColor = HighlightedCode.color(kind, dark: dark) }
            return part
        }
        var result = part(name, .command) + part("(", .punctuation)
        for (index, parameter) in parameters.enumerated() {
            if index > 0 { result += part(", ", .punctuation) }
            result += part(parameter.name, nil)
            if !parameter.isRequired { result += part("?", .punctuation) }
        }
        return result + part(")", .punctuation)
    }
}

/// One parameter: its name leads, in the body's size and weight, with its type and whether it
/// is optional quiet at the row's end. Its description, allowed values, and default follow as
/// supporting text.
struct ParameterRow: View {
    let parameter: ToolParameter

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(parameter.name)
                    .font(.body.monospaced().weight(.semibold))
                    .layoutPriority(1)
                Spacer(minLength: 8)
                if !parameter.isRequired { ToolDetailTag(text: "optional") }
                Text(parameter.type)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !parameter.description.isEmpty {
                Text(parameter.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let values = valuesText {
                values
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, ToolDetailRow.inset)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// "One of storm, heat, frost" and "Default 3", with the values in code type.
    private var valuesText: Text? {
        var parts: [Text] = []
        if !parameter.allowedValues.isEmpty {
            let values = parameter.allowedValues.map { Text($0).font(.caption.monospaced()).foregroundStyle(.primary) }
            parts.append(values.dropFirst().reduce(Text("One of ") + values[0]) { $0 + Text(", ") + $1 })
        }
        if let value = parameter.defaultValue {
            parts.append(Text("Default ") + Text(value).font(.caption.monospaced()).foregroundStyle(.primary))
        }
        guard let first = parts.first else { return nil }
        return parts.dropFirst().reduce(first) { $0 + Text(". ") + $1 }
    }
}

/// The two texts the model is sent, one at a time under a switch: the description, and the
/// parameters' JSON Schema. Both are monospaced with best-effort highlighting, selectable, and
/// shown at full length in the pane's own scroll, last on the pane so nothing is below them.
struct ToolTextSection: View {
    let tool: ToolSummary
    @Bindable var model: ToolsSettingsModel
    @State private var copied = false

    var body: some View {
        let tab = model.textTab
        let text = tab == .description ? tool.description : tool.schemaText
        ToolDetailSection("Sent to the model") {
            ToolDetailBox {
                HStack(spacing: 8) {
                    Picker("Text", selection: $model.textTab) {
                        ForEach(ToolTextTab.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    Spacer(minLength: 8)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help(tab == .description ? "Copy the description" : "Copy the JSON Schema")
                    .disabled(text.isEmpty)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                Divider().opacity(0.6)
                Group {
                    if text.isEmpty {
                        Text("No description.").foregroundStyle(.secondary)
                    } else {
                        HighlightedCodeText(
                            text: text,
                            spans: tab == .description ? CodeHighlighting.freeText(text) : CodeHighlighting.json(text),
                            size: 10.5)
                    }
                }
                .padding(.horizontal, ToolDetailRow.inset)
                .padding(.vertical, 10)
            }
        }
        .onChange(of: tab) { copied = false }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

// MARK: - Parts of the tool's details

/// A heading over a box of rows, with something small at the heading's end, such as a count,
/// and a note under the box.
struct ToolDetailSection<Accessory: View, Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    init(_ title: String, footer: String? = nil, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                accessory
            }
            .padding(.horizontal, 2)
            content
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

extension ToolDetailSection where Accessory == EmptyView {
    init(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, footer: footer, accessory: { EmptyView() }, content: content)
    }
}

/// Rows on a faint rounded box, as System Settings groups them.
struct ToolDetailBox<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.035), in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.separator))
    }
}

/// A row that states one thing: a symbol, what it is, and a line about it.
struct ToolDetailRow: View {
    static let inset: CGFloat = 12
    static let symbolWidth: CGFloat = 16

    let symbol: String
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: Self.symbolWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Self.inset)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }
}

/// One fact about a tool and a line on why, such as whether the incognito window has it.
struct ToolFact {
    let symbol: String
    let value: String
    let detail: String?
}

/// A fact in a box: what it is about at the leading edge, the fact at the trailing edge, and
/// the line on why under both.
struct ToolFactRow: View {
    let label: String
    let fact: ToolFact

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label)
                Spacer(minLength: 8)
                Label(fact.value, systemImage: fact.symbol)
                    .foregroundStyle(.secondary)
            }
            if let detail = fact.detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, ToolDetailRow.inset)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct ToolDetailDivider: View {
    var body: some View {
        Divider().opacity(0.6)
    }
}

/// A small quiet label beside a name, such as "optional" or "Default".
struct ToolDetailTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary.opacity(0.8), in: .capsule)
    }
}

/// Whether the app may use the personal data a group of tools needs, with a way to change it.
struct PrivacyAccessView: View {
    let kind: PrivacyAccessKind
    let status: PrivacyAccessStatus
    let request: () -> Void

    var body: some View {
        ToolDetailSection("Access to \(kind.title)") {
            ToolDetailBox {
                VStack(alignment: .leading, spacing: 8) {
                    ToolDetailRow(
                        symbol: status == .fullAccess ? "checkmark.circle" : "exclamationmark.circle",
                        title: status.label, detail: explanation)
                    .foregroundStyle(status == .fullAccess ? Color.primary : Color.orange)
                    HStack {
                        if status == .notDetermined {
                            Button("Ask for Access…", action: request)
                        }
                        Button("Open Privacy Settings") {
                            NSWorkspace.shared.open(kind.systemSettingsURL)
                        }
                    }
                    .padding(.leading, ToolDetailRow.inset + ToolDetailRow.symbolWidth + 10)
                    .padding(.bottom, 10)
                }
            }
        }
    }

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
