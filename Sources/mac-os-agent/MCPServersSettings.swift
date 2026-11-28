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
    /// A tool's pane belongs to its server and its tab, so changing either closes it.
    var selection: MCPServerStatus.ID? {
        didSet { if selection != oldValue { toolStack.path = PaneStackPath() } }
    }
    /// Which tab the selected server's detail shows under its header. Kept here, so moving from
    /// server to server keeps it while the window is open. Details first.
    var detailTab: MCPServerDetailTab = .details {
        didSet { if detailTab != oldValue { toolStack.path = PaneStackPath() } }
    }
    var errorMessage: String?
    /// With the pane stack experiment on, a tool chosen in the Tools tab slides in over the
    /// server's detail: `[]` or `[tool]`, by the tool's name as the model calls it. Closed when
    /// another server is chosen or the tab changes.
    let toolStack = PaneStackState()
    /// Set by a preview that asks for the pane stack, which shows it whatever the preference says.
    var paneStackOverride: Bool?
    /// Changes when a display name does, so the views read the store again.
    private(set) var namesRevision = 0
    @ObservationIgnored let pool: MCPServerPool
    @ObservationIgnored let file: URL
    @ObservationIgnored private var namesObserver: (any NSObjectProtocol)?

    init(pool: MCPServerPool, file: URL = AgentPaths.mcpServersFile) {
        self.pool = pool
        self.file = file
        pool.onChange { [weak self] in
            Task { @MainActor in await self?.reload() }
        }
        namesObserver = NotificationCenter.default.addObserver(
            forName: MCPSettingsStore.namesDidChange, object: pool.settings, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.namesRevision += 1 }
        }
        Task { await reload() }
    }

    isolated deinit {
        if let namesObserver { NotificationCenter.default.removeObserver(namesObserver) }
    }

    // MARK: - Display names

    /// The server's name in Settings: the owner's, or its name in the file made readable.
    func displayName(of server: String) -> String {
        _ = namesRevision
        return pool.settings.serverDisplayName(server)
    }

    func displayNameOverride(of server: String) -> String? {
        _ = namesRevision
        return pool.settings.serverNameOverride(server)
    }

    /// Sets the server's display name. Empty, or the default, means the default.
    func setDisplayName(_ name: String?, of server: String) {
        save { try pool.settings.setServerDisplayName(name, server: server) }
    }

    /// The tool's name in Settings, by its name on its server.
    func displayName(of tool: MCPToolReference) -> String {
        _ = namesRevision
        return pool.settings.toolDisplayName(server: tool.server, tool: tool.tool)
    }

    func displayNameOverride(of tool: MCPToolReference) -> String? {
        _ = namesRevision
        return pool.settings.toolNameOverride(server: tool.server, tool: tool.tool)
    }

    func setDisplayName(_ name: String?, of tool: MCPToolReference) {
        save { try pool.settings.setToolDisplayName(name, server: tool.server, tool: tool.tool) }
    }

    private func save(_ body: () throws -> Void) {
        do {
            try body()
            errorMessage = nil
        } catch {
            errorMessage = "Could not save the name: \(error.localizedDescription)"
        }
        namesRevision += 1
    }

    /// The server's tools as Settings > Tools shows them, each named as the model calls it,
    /// for their rows and their details. Built from the server's list as it is now, so a tool
    /// that joins at the next launch has details too.
    func toolSummaries(_ status: MCPServerStatus) -> [ToolSummary] {
        let server = status.entry.name
        let names = MCPToolNaming.names(server: server, tools: status.tools.map(\.name))
        var seen = Set<String>()
        return status.tools.compactMap { info in
            guard seen.insert(info.name).inserted else { return nil }
            let name = names[info.name] ?? server + MCPToolNaming.separator + info.name
            return ToolSummary(MCPTool(server: server, info: info, name: name, pool: pool))
        }
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
    /// to split on. `stack` shows the pane stack as if its experiment were on, and `tool-<name>`
    /// opens that tool's pane over the Tools tab, by its name on its server, as in
    /// `example.tool-list_projects`. Other words, such as `narrow`, are for the window.
    func showPreviewItem(_ item: String) {
        let words = item.split(separator: ".").map(String.init)
        let server = words.first ?? item
        selection = server
        if let tab = words.dropFirst().lazy.compactMap(MCPServerDetailTab.init(rawValue:)).first { detailTab = tab }
        if words.contains("stack") { paneStackOverride = true }
        if let tool = words.first(where: { $0.hasPrefix("tool-") })?.dropFirst("tool-".count) {
            paneStackOverride = true
            detailTab = .tools
            toolStack.path = PaneStackPath([server + MCPToolNaming.separator + tool])
        }
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
    /// For a tool's details in its pane, which are the ones Settings > Tools shows.
    let tools: ToolsSettingsModel
    @AppStorage(Experiment.settingsPaneStack.key) private var paneStack = false

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
                        MCPServerRow(status: status, displayName: model.displayName(of: status.entry.name)).tag(status.id)
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
                        if model.paneStackOverride ?? paneStack {
                            MCPServerPaneStack(status: status, model: model, tools: tools)
                        } else {
                            MCPServerDetailView(status: status, model: model, opensTools: false)
                        }
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

    /// The row's line when the whole of it does not fit: the count alone when connected, and
    /// the state's name otherwise.
    var shortRowLine: String {
        switch state {
        case .connected: tools.count == 1 ? "1 tool" : "\(tools.count) tools"
        case .starting: "Starting…"
        case .off, .failed, .invalid: state.label
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

/// A server in the list, in three lines: its display name, which leads, then its name in the
/// file with its state for this run, then what it is for, when that is known.
struct MCPServerRow: View {
    let status: MCPServerStatus
    let displayName: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .fontWeight(.medium)
                    .foregroundStyle(status.state == .off ? .secondary : .primary)
                    .lineLimit(1)
                // The name in the file is what the model sees in each tool's name, so it keeps
                // its room. The state beside it gives way first: to a short form, such as
                // "Failed", and then to nothing, leaving the mark at the end of the row. The
                // header has the whole of it.
                HStack(spacing: 4) {
                    Text(status.entry.name)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    ViewThatFits(in: .horizontal) {
                        Text("· " + status.rowLine).lineLimit(1)
                        Text("· " + status.shortRowLine).lineLimit(1)
                        Color.clear.frame(width: 0, height: 0)
                    }
                    .font(.caption)
                }
                .foregroundStyle(.secondary)
                if let summary = status.summary {
                    Text(summary.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(summary.text)
                }
            }
            Spacer(minLength: 4)
            Image(systemName: status.stateSymbol)
                .foregroundStyle(status.stateColor)
                .accessibilityLabel(status.state.label)
        }
        .padding(.vertical, 3)
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
    /// True when a tool's row opens its pane, with the pane stack experiment on.
    let opensTools: Bool

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
                case .tools: MCPServerToolsTab(status: status, model: model, opensTools: opensTools)
                }
            }
            // Each server starts its tabs at the top.
            .id(status.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// A server's detail with its tools' panes: a tool chosen in the Tools tab slides in over the
/// detail, leaving the start of the tools' names showing. Behind the pane stack experiment, as
/// Tools and History are. See `PaneStackView`.
struct MCPServerPaneStack: View {
    /// How much of the server's detail shows beside a tool's pane: the start of the tools' names.
    static let stripWidth: CGFloat = 190

    let status: MCPServerStatus
    @Bindable var model: MCPServersSettingsModel
    let tools: ToolsSettingsModel

    var body: some View {
        let summaries = model.toolSummaries(status)
        PaneStackView(state: model.toolStack) { _ in
            Self.stripWidth
        } title: { level in
            if let id = level.item, let tool = summaries.first(where: { $0.id == id }), let mcp = tool.mcp {
                model.displayName(of: mcp)
            } else {
                model.displayName(of: status.entry.name)
            }
        } rows: { path in
            path.isAtBase ? summaries.map(\.id) : []
        } pane: { level in
            if level.depth == 0 {
                MCPServerDetailView(status: status, model: model, opensTools: true)
            } else if let id = level.item, let tool = summaries.first(where: { $0.id == id }), let mcp = tool.mcp {
                MCPToolPane(tool: tool, mcp: mcp, server: status.entry.name, model: model, tools: tools)
                    // Another tool starts with its own state, such as its name field's.
                    .id(tool.id)
            } else {
                Color.clear
            }
        }
        .onChange(of: summaries.map(\.id), initial: true) { _, ids in
            // A path naming a tool the server no longer lists falls back to the detail. While
            // the list is still loading there is nothing to check against.
            if let open = model.toolStack.path.entry(at: 1), !ids.isEmpty, !ids.contains(open) {
                model.toolStack.path = PaneStackPath()
            }
        }
    }
}

/// One tool's pane over its server's detail: its display name over the name the model calls,
/// a field for the display name, and then the details Settings > Tools shows for it, its
/// go-ahead among them.
struct MCPToolPane: View {
    let tool: ToolSummary
    let mcp: MCPToolReference
    let server: String
    let model: MCPServersSettingsModel
    let tools: ToolsSettingsModel

    var body: some View {
        StackPane(
            scope: model.displayName(of: server),
            title: Text(model.displayName(of: mcp)).font(.title3.weight(.semibold)),
            subtitle: tool.name, subtitleIsCode: true
        ) {
            VStack(alignment: .leading, spacing: 22) {
                ToolDetailSection("Display Name", footer: "Shown only here in Settings. The agent still calls it \(tool.name).") {
                    MCPDisplayNameField(
                        defaultName: HumanizedName.from(mcp.tool), override: model.displayNameOverride(of: mcp),
                        label: "Display name for \(tool.name)"
                    ) { model.setDisplayName($0, of: mcp) }
                }
                ToolDetailSections(tool: tool, model: tools)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A field for a display name. Empty shows the default as its placeholder and means the
/// default. Each change is saved as it is typed, and Use Default empties it.
struct MCPDisplayNameField: View {
    let defaultName: String
    let label: String
    let save: (String?) -> Void
    @State private var text: String

    init(defaultName: String, override: String?, label: String, save: @escaping (String?) -> Void) {
        self.defaultName = defaultName
        self.label = label
        self.save = save
        _text = State(initialValue: override ?? "")
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField(label, text: $text, prompt: Text(defaultName))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .onChange(of: text) { _, value in save(value) }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Use Default") { text = "" }
                    .help("Show \(defaultName), the default")
                    .fixedSize()
            }
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
                    let displayName = model.displayName(of: entry.name)
                    Text(displayName)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(displayName)
                        .accessibilityAddTraits(.isHeader)
                    // The name in the file, which starts each of its tools' names for the model.
                    Text(entry.name)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(entry.name)
                        .textSelection(.enabled)
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

/// What the server is: its display name, what it is for, the command the app starts, the names
/// in its environment, and where the file is.
struct MCPServerDetailsTab: View {
    let status: MCPServerStatus
    let model: MCPServersSettingsModel

    private var entry: MCPServerEntry { status.entry }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Display Name").font(.headline)
                    MCPDisplayNameField(
                        defaultName: HumanizedName.from(entry.name), override: model.displayNameOverride(of: entry.name),
                        label: "Display name for \(entry.name)"
                    ) { model.setDisplayName($0, of: entry.name) }
                    Text("Shown only here in Settings. The agent still sees \(entry.name) in each of its tools' names.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Description").font(.headline)
                    if let summary = status.summary {
                        Text(summary.text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("None.").foregroundStyle(.secondary)
                    }
                    Text(descriptionSource)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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

    /// Where the description comes from, and how to set one, with what the server says it is
    /// when it said.
    private var descriptionSource: String {
        let reported = status.serverInfo.map { info in
            " It reports itself as \(info.title ?? info.name) \(info.version)."
        } ?? ""
        switch status.summary?.source {
        case .file?: return "From \"description\" in its entry in mcp-servers.json." + reported
        case .server?: return "From the server. A \"description\" in its entry in mcp-servers.json takes its place." + reported
        case .instructions?: return "The first sentence of the server's instructions. A \"description\" in its entry in mcp-servers.json takes its place." + reported
        case nil: return "Add a \"description\" to its entry in mcp-servers.json, or connect a server that describes itself." + reported
        }
    }

    @ViewBuilder private var fileButtons: some View {
        Button("Open mcp-servers.json") { model.openFile() }
        Button("Show in Finder") { model.revealInFinder() }
    }
}

/// What the server gives the agent: each tool in three lines, its display name, the name the
/// model calls it by, and the start of its description, with whether it is read-only. With the
/// pane stack experiment on, a row opens the tool's pane.
struct MCPServerToolsTab: View {
    let status: MCPServerStatus
    let model: MCPServersSettingsModel
    let opensTools: Bool

    var body: some View {
        if status.tools.isEmpty {
            Text(emptyToolsText)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let tools = model.toolSummaries(status)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text(opensTools ? "Choose a tool for its details, its display name, and its go-ahead." : "Each tool's go-ahead is in Tools.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, MCPToolRow.inset)
                        .padding(.bottom, 6)
                    ForEach(tools) { tool in
                        if let mcp = tool.mcp {
                            let row = MCPToolRow(tool: tool, displayName: model.displayName(of: mcp), readOnly: mcp.readOnly, opens: opensTools)
                            if opensTools {
                                PaneStackLink(id: tool.id) { row }
                                    .accessibilityHint(Text("Shows the tool's details"))
                            } else {
                                row
                            }
                        }
                        if tool.id != tools.last?.id { PaneRowDivider(leading: MCPToolRow.inset) }
                    }
                }
                .padding(.vertical, 14)
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

/// One tool in a server's Tools tab: its display name, which leads, with Read-only beside it,
/// then the name the model calls, then the first line of its description.
struct MCPToolRow: View {
    static let inset: CGFloat = 20

    let tool: ToolSummary
    let displayName: String
    let readOnly: Bool
    let opens: Bool

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(displayName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if readOnly {
                        Text("Read-only")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                Text(tool.name)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !tool.description.isEmpty {
                    Text(tool.description.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if opens { PaneChevron() }
        }
        .padding(.leading, Self.inset)
        .padding(.trailing, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
