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

    var config: MCPServerConfig { pool.config }

    func reload() async {
        statuses = await pool.statuses()
        if let selection, !statuses.contains(where: { $0.id == selection }) { self.selection = nil }
        if selection == nil { selection = statuses.first?.id }
    }

    var selectedStatus: MCPServerStatus? { statuses.first { $0.id == selection } }

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

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
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

struct MCPServerDetailView: View {
    let status: MCPServerStatus
    let model: MCPServersSettingsModel

    private var entry: MCPServerEntry { status.entry }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.name).font(.title2.monospaced())
                        Label(stateText, systemImage: status.stateSymbol)
                            .foregroundStyle(status.stateColor)
                            .font(.callout)
                    }
                    Spacer()
                    if entry.problem == nil {
                        Toggle("Use \(entry.name)", isOn: Binding(
                            get: { status.isEnabled }, set: { model.setEnabled($0, entry.name) }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .help(status.isEnabled ? "On: started when the app launches" : "Off: never started")
                    }
                }
                switch status.state {
                case .failed(let reason): MCPProblemBanner(text: reason)
                case .invalid(let problem): MCPProblemBanner(text: problem)
                default: EmptyView()
                }
                if let note = status.nextLaunchNote {
                    Label(note, systemImage: "arrow.clockwise")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = model.errorMessage {
                    Text(error).font(.callout).foregroundStyle(.red)
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
                if !entry.env.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Environment").font(.headline)
                        // Only the names. The values can be tokens.
                        Text(entry.env.keys.sorted().joined(separator: ", "))
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                        Text("Values are not shown.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Tools").font(.headline)
                    if status.tools.isEmpty {
                        Text(emptyToolsText).foregroundStyle(.secondary)
                    } else {
                        let names = MCPToolNaming.names(server: entry.name, tools: status.tools.map(\.name))
                        ForEach(status.tools, id: \.name) { tool in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(names[tool.name] ?? tool.name).font(.callout.monospaced())
                                    if tool.readOnly {
                                        Text("Read-only")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
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
                        Text("Each tool's go-ahead is in Tools.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Button("Open mcp-servers.json") { model.openFile() }
                    Button("Show in Finder") { model.revealInFinder() }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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

    private var emptyToolsText: String {
        switch status.state {
        case .starting: "Its tools are listed once it connects."
        case .invalid: "None, since the entry cannot be used."
        case .off: "None known. Turn it on to list them."
        default: "None."
        }
    }
}
