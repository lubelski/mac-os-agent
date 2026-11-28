import AppKit
import MacOSAgentCore
import Observation
import SwiftUI

/// The MCP servers in `mcp-servers.json`, each with its state for this run. Adding and editing
/// a server happens in the file. The app decides only whether each one is on.
@MainActor
@Observable
final class MCPServersSettingsModel {
    private(set) var statuses: [MCPServerStatus] = []
    var selection: MCPServerStatus.ID?
    /// Which tab the selected server's detail shows under its header. Kept here, so moving from
    /// server to server keeps it while the window is open. Details first.
    var detailTab: MCPServerDetailTab = .details
    var errorMessage: String?
    @ObservationIgnored let pool: MCPServerPool
    @ObservationIgnored let file: URL

    init(pool: MCPServerPool, file: URL = AgentPaths.mcpServersFile) {
        self.pool = pool
        self.file = file
        pool.onChange { [weak self] in
            Task { @MainActor in await self?.reload() }
        }
        Task { await reload() }
    }

    /// What the servers file said when the pool read it.
    private(set) var config = MCPServerConfig(fileExists: false)

    func reload() async {
        config = await pool.config
        statuses = await pool.statuses()
        if let selection, !statuses.contains(where: { $0.id == selection }) { self.selection = nil }
        if selection == nil { selection = statuses.first?.id }
    }

    var selectedStatus: MCPServerStatus? { statuses.first { $0.id == selection } }

    /// Selects what `--preview-item` names: a server, then dot-separated words, of which a tab's
    /// name picks that tab, as in `example.tools`. A server name has no dots, so the dot is free
    /// to split on. Other words, such as `narrow`, are for the window.
    func showPreviewItem(_ item: String) {
        let words = item.split(separator: ".").map(String.init)
        selection = words.first ?? item
        if let tab = words.dropFirst().lazy.compactMap(MCPServerDetailTab.init(rawValue:)).first { detailTab = tab }
    }

    func setEnabled(_ enabled: Bool, _ server: String) {
        Task {
            do {
                try await pool.setEnabled(enabled, server: server)
                errorMessage = nil
            } catch {
                errorMessage = "Could not save the setting: \(error.localizedDescription)"
            }
            await reload()
        }
    }

    func openFile() {
        NSWorkspace.shared.open(file)
    }

    /// Selects the file in Finder, or opens its folder when there is no file yet.
    func revealInFinder() {
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            let folder = file.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
    }
}

struct MCPServersSettingsView: View {
    @Bindable var model: MCPServersSettingsModel

    var body: some View {
        if model.statuses.isEmpty {
            MCPServersEmptyView(model: model)
        } else {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if let problem = model.config.fileProblem {
                        MCPProblemBanner(text: problem).padding(10)
                    }
                    List(model.statuses, selection: $model.selection) { status in
                        MCPServerRow(status: status).tag(status.id)
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    Divider()
                    HStack(spacing: 8) {
                        Button("Open mcp-servers.json", systemImage: "doc.text") { model.openFile() }
                            .help("Open mcp-servers.json")
                        Button("Show in Finder", systemImage: "folder") { model.revealInFinder() }
                            .help("Show mcp-servers.json in Finder")
                        Spacer()
                        Text(countText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .frame(width: 260)
                Divider()
                Group {
                    if let status = model.selectedStatus {
                        MCPServerDetailView(status: status, model: model)
                    } else {
                        ContentUnavailableView("No Server Selected", systemImage: "server.rack")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var countText: String {
        let count = model.statuses.count
        let on = model.statuses.filter(\.isEnabled).filter { $0.entry.problem == nil }.count
        return count == 1 ? "1 server, \(on) on" : "\(count) servers, \(on) on"
    }
}

/// No file, or a file with no servers in it: where the file goes, and what it holds.
struct MCPServersEmptyView: View {
    let model: MCPServersSettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label(model.config.fileExists ? "No Servers in the File" : "No MCP Servers", systemImage: "server.rack")
                    .font(.title2)
                if let problem = model.config.fileProblem {
                    MCPProblemBanner(text: problem)
                }
                Text("MCP servers give the agent more tools. List them in mcp-servers.json, in the same shape other apps use, so an entry can be pasted from one. The app starts each server itself and talks to it over standard input and output.")
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.file.path(percentEncoded: false))
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("For example:").font(.headline)
                Text(MCPServerConfig.example)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.secondary, in: .rect(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                Text("A server's tools join the tool list at the next launch after it first connects.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if model.config.fileExists {
                        Button("Open mcp-servers.json") { model.openFile() }
                    }
                    Button("Show in Finder") { model.revealInFinder() }
                }
            }
            .padding(20)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

struct MCPProblemBanner: View {
    let text: String
    /// How many lines to show, or nil for all of them. A shortened one shows the whole text on
    /// hover.
    var lineLimit: Int?

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .help(lineLimit == nil ? "" : text)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: .rect(cornerRadius: 8))
    }
}

extension MCPServerStatus {
    /// One line for the list row.
    var rowLine: String {
        switch state {
        case .off: "Off"
        case .starting: "Starting…"
        case .connected: tools.count == 1 ? "Connected, 1 tool" : "Connected, \(tools.count) tools"
        case .failed(let reason): "Failed: \(reason)"
        case .invalid(let problem): problem
        }
    }

    var stateSymbol: String {
        switch state {
        case .off: "circle"
        case .starting: "circle.dotted"
        case .connected: "checkmark.circle.fill"
        case .failed, .invalid: "exclamationmark.triangle.fill"
        }
    }

    var stateColor: Color {
        switch state {
        case .off, .starting: .secondary
        case .connected: .green
        case .failed, .invalid: .orange
        }
    }
}

struct MCPServerRow: View {
    let status: MCPServerStatus

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(status.entry.name)
                    .font(.body.monospaced())
                    .foregroundStyle(status.state == .off ? .secondary : .primary)
                Text(status.rowLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: status.stateSymbol)
                .foregroundStyle(status.stateColor)
                .accessibilityLabel(status.state.label)
        }
        .padding(.vertical, 2)
    }
}

/// The two tabs under a server's header: what it is (its command and environment), and what it
/// gives the agent (its tools).
enum MCPServerDetailTab: String, CaseIterable {
    case details
    case tools

    /// The tab's name in the switch. Tools carries its count once any are known.
    func title(toolCount: Int) -> String {
        switch self {
        case .details: "Details"
        case .tools: toolCount == 0 ? "Tools" : "Tools (\(toolCount))"
        }
    }
}

/// A server's detail: a header that stays in place, with its name, its state, its switch, and
/// anything that says why it is in that state, then a switch between two tabs, each of which
/// scrolls on its own under them.
struct MCPServerDetailView: View {
    let status: MCPServerStatus
    @Bindable var model: MCPServersSettingsModel

    var body: some View {
        VStack(spacing: 0) {
            MCPServerDetailHeader(status: status, model: model)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)
            Divider()
            Group {
                switch model.detailTab {
                case .details: MCPServerDetailsTab(status: status, model: model)
                case .tools: MCPServerToolsTab(status: status)
                }
            }
            // Each server starts its tabs at the top.
            .id(status.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// What stays in place above the tabs: the name, the state, the switch, why it failed or is not
/// valid, what changes at the next launch, a save error, and the tab switch.
struct MCPServerDetailHeader: View {
    let status: MCPServerStatus
    @Bindable var model: MCPServersSettingsModel

    private var entry: MCPServerEntry { status.entry }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name)
                        .font(.title2.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(entry.name)
                        .accessibilityAddTraits(.isHeader)
                    Label(stateText, systemImage: status.stateSymbol)
                        .foregroundStyle(status.stateColor)
                        .font(.callout)
                        .lineLimit(1)
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
                if entry.problem == nil {
                    Toggle("Use \(entry.name)", isOn: Binding(
                        get: { status.isEnabled }, set: { model.setEnabled($0, entry.name) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .help(status.isEnabled ? "On: started when the app launches" : "Off: never started")
                }
            }
            // A failure can be a long message from the server, so the header shows its start
            // and the whole of it on hover.
            switch status.state {
            case .failed(let reason): MCPProblemBanner(text: reason, lineLimit: 3)
            case .invalid(let problem): MCPProblemBanner(text: problem, lineLimit: 3)
            default: EmptyView()
            }
            if let note = status.nextLaunchNote {
                Label(note, systemImage: "arrow.clockwise")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("Show", selection: $model.detailTab) {
                ForEach(MCPServerDetailTab.allCases, id: \.self) { tab in
                    Text(tab.title(toolCount: status.tools.count)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stateText: String {
        switch status.state {
        case .connected: "Connected"
        case .starting: "Starting"
        case .off: "Off"
        case .failed: "Failed"
        case .invalid: "Not valid"
        }
    }
}

/// What the server is: the command the app starts, the names in its environment, and where the
/// file is.
struct MCPServerDetailsTab: View {
    let status: MCPServerStatus
    let model: MCPServersSettingsModel

    private var entry: MCPServerEntry { status.entry }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Command").font(.headline)
                    Text(entry.commandLine.isEmpty ? "(none)" : entry.commandLine)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background.secondary, in: .rect(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Environment").font(.headline)
                    if entry.env.isEmpty {
                        Text("None.").foregroundStyle(.secondary)
                    } else {
                        // Only the names. The values can be tokens.
                        Text(entry.env.keys.sorted().joined(separator: ", "))
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                        Text("Values are not shown.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Adding and changing a server happens in the file.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Side by side, or one over the other when the pane is too narrow for both.
                ViewThatFits(in: .horizontal) {
                    HStack { fileButtons }
                    VStack(alignment: .leading) { fileButtons }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var fileButtons: some View {
        Button("Open mcp-servers.json") { model.openFile() }
        Button("Show in Finder") { model.revealInFinder() }
    }
}

/// What the server gives the agent: each tool's name as the model calls it, whether it is
/// read-only, and the start of its description.
struct MCPServerToolsTab: View {
    let status: MCPServerStatus

    var body: some View {
        if status.tools.isEmpty {
            Text(emptyToolsText)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let names = MCPToolNaming.names(server: status.entry.name, tools: status.tools.map(\.name))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    Text("Each tool's go-ahead is in Tools.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(status.tools, id: \.name) { tool in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(names[tool.name] ?? tool.name)
                                    .font(.callout.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if tool.readOnly {
                                    Text("Read-only")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize()
                                }
                            }
                            if !tool.description.isEmpty {
                                Text(tool.description.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        if tool.name != status.tools.last?.name { Divider() }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var emptyToolsText: String {
        switch status.state {
        case .starting: "Its tools are listed once it connects."
        case .invalid: "None, since the entry cannot be used."
        case .off: "None known. Turn it on to list them."
        case .failed: "None known. Its tools are listed once it connects."
        case .connected: "It has no tools."
        }
    }
}
