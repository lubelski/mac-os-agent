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
    var selection: ToolSummary.ID?
    /// The app's access to each kind of personal data the tools use, read again whenever the
    /// window comes forward, since the owner changes it in System Settings.
    private(set) var access: [PrivacyAccessKind: PrivacyAccessStatus] = [:]
    @ObservationIgnored private let gate: any PrivacyAccessGate
    @ObservationIgnored let mcpSettings: MCPSettingsStore?
    /// Changes when an MCP tool's go-ahead does, so the views read the store again.
    private(set) var goAheadRevision = 0
    @ObservationIgnored private var goAheadObserver: (any NSObjectProtocol)?
    var errorMessage: String?

    init(registry: ToolRegistry, access gate: any PrivacyAccessGate, mcpSettings: MCPSettingsStore? = nil) {
        groups = registry.groups
        selection = groups.first?.tools.first?.id
        self.gate = gate
        self.mcpSettings = mcpSettings
        reloadAccess()
        if let mcpSettings {
            // Always Call on a go-ahead card changes a tool's go-ahead while this pane may be open.
            goAheadObserver = NotificationCenter.default.addObserver(
                forName: MCPSettingsStore.goAheadDidChange, object: mcpSettings, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.goAheadRevision += 1 }
            }
        }
    }

    isolated deinit {
        if let goAheadObserver { NotificationCenter.default.removeObserver(goAheadObserver) }
    }

    /// The tool's go-ahead as it is now. An MCP tool's can change while the app runs.
    func goAhead(of tool: ToolSummary) -> ToolGoAhead {
        _ = goAheadRevision
        guard let mcp = tool.mcp, let mcpSettings else { return tool.goAhead }
        return mcpSettings.goAhead(server: mcp.server, tool: mcp.tool, readOnly: mcp.readOnly).toolGoAhead
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

    var selectedTool: ToolSummary? {
        groups.lazy.flatMap(\.tools).first { $0.id == selection }
    }
}

struct ToolsSettingsView: View {
    @Bindable var model: ToolsSettingsModel

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                List(selection: $model.selection) {
                    ForEach(model.groups) { group in
                        Section(group.source.title) {
                            ForEach(group.tools) { tool in
                                ToolRow(tool: tool, goAhead: model.goAhead(of: tool)).tag(tool.id).id(tool.id)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .task {
                    // Waits a moment for the rows, then brings the selected tool into view, such
                    // as an MCP tool at the end of the list.
                    try? await Task.sleep(for: .milliseconds(100))
                    if let selection = model.selection { proxy.scrollTo(selection, anchor: .center) }
                }
            }
            .frame(width: 260)
            Divider()
            Group {
                if let tool = model.selectedTool {
                    ToolDetailView(tool: tool, model: model)
                } else {
                    ContentUnavailableView("No Tool Selected", systemImage: "wrench.and.screwdriver")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ToolRow: View {
    let tool: ToolSummary
    let goAhead: ToolGoAhead

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.name).font(.body.monospaced())
                Text(tool.shortDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if goAhead != .never {
                Image(systemName: "hand.raised")
                    .foregroundStyle(.secondary)
                    .help("Can ask for a go-ahead")
                    .accessibilityLabel("Can ask for a go-ahead")
            }
        }
        .padding(.vertical, 2)
    }
}

struct ToolDetailView: View {
    let tool: ToolSummary
    let model: ToolsSettingsModel
    @State private var showingSchema = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tool.name).font(.title2.monospaced())
                    Text(tool.source.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
