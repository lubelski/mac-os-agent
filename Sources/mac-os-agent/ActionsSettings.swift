import AppKit
import MacOSAgentCore
import Observation
import SwiftUI

/// The saved actions for Settings, kept live: the folder is watched, and the app's own changes
/// post `SavedActionLibrary.didChangeNotification`.
@MainActor
@Observable
final class ActionsSettingsModel {
    private(set) var entries: [SavedActionEntry] = []
    var selection: SavedActionEntry.ID?
    var filter = ""
    var errorMessage: String?
    @ObservationIgnored let library: SavedActionLibrary
    /// The tools a step may call, for showing a step that does not fit its tool.
    @ObservationIgnored private let tools: [ToolDefinition]
    @ObservationIgnored let summaries: ToolCallSummaries
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(library: SavedActionLibrary, tools: [ToolDefinition], summaries: ToolCallSummaries, watches: Bool = true) {
        self.library = library
        self.tools = tools
        self.summaries = summaries
        reload()
        guard watches else { return }
        watcher = FolderWatcher(folder: library.folder) { [weak self] in self?.reload() }
        observer = NotificationCenter.default.addObserver(
            forName: SavedActionLibrary.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func reload() {
        if watcher?.isWatching == false { watcher?.rearm() }
        let fresh = library.entries()
        if fresh != entries { entries = fresh }
        if let selection, !entries.contains(where: { $0.id == selection }) { self.selection = nil }
        if selection == nil { selection = entries.first?.id }
    }

    var filteredEntries: [SavedActionEntry] {
        entries.filter { entry in
            guard let action = entry.action else { return filter.isEmpty || entry.id.localizedCaseInsensitiveContains(filter) }
            return action.matches(filter)
        }
    }

    var selectedEntry: SavedActionEntry? { entries.first { $0.id == selection } }

    var countText: String {
        let on = entries.filter(\.isAvailable).count
        return entries.count == 1 ? "1 quick action, \(on) on" : "\(entries.count) quick actions, \(on) on"
    }

    /// What is wrong with an action that reads: a step that names no tool, or whose arguments
    /// do not fit it.
    func problems(_ action: SavedAction) -> [String] {
        ActionValidation.problems(action, tools: tools)
    }

    func setEnabled(_ enabled: Bool, _ entry: SavedActionEntry) {
        do {
            try library.setEnabled(enabled, id: entry.id)
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
        reload()
    }

    func delete(_ entry: SavedActionEntry) {
        do {
            try library.delete(id: entry.id)
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
        reload()
    }

    func open(_ entry: SavedActionEntry) {
        NSWorkspace.shared.open(entry.fileURL)
    }

    func revealInFinder() {
        if let entry = selectedEntry {
            NSWorkspace.shared.activateFileViewerSelecting([entry.fileURL])
            return
        }
        try? FileManager.default.createDirectory(at: library.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(library.folder)
    }
}

/// Saved actions as a list beside the selected action's detail, as Skills is.
struct ActionsSettingsView: View {
    @Bindable var model: ActionsSettingsModel
    @AgentName private var agentName

    var body: some View {
        VStack(spacing: 0) {
            // The section's one-line description, as Behaviors and Experiments have, with the
            // plain explanation under it.
            VStack(alignment: .leading, spacing: 2) {
                Text("Just do it.")
                Text("A quick action is a fixed tool call, or a few, that runs at once when you type its name and press Return.")
                    .font(.callout)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            list
        }
        .onAppear { model.reload() }
    }

    private var list: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                FilterField(prompt: "Filter Quick Actions", text: $model.filter)
                    .padding(10)
                Group {
                    if model.entries.isEmpty {
                        ContentUnavailableView {
                            Label("No Quick Actions Yet", systemImage: "bolt")
                        } description: {
                            Text("Ask \(agentName) to make something it did instant, and it saves it here.")
                        }
                    } else if model.filteredEntries.isEmpty {
                        ContentUnavailableView.search(text: model.filter)
                    } else {
                        List(model.filteredEntries, selection: $model.selection) { entry in
                            ActionRow(entry: entry).tag(entry.id)
                        }
                        .listStyle(.inset)
                        .scrollContentBackground(.hidden)
                    }
                }
                .frame(maxHeight: .infinity)
                Divider()
                HStack(spacing: 8) {
                    Button("Show Quick Actions Folder in Finder", systemImage: "folder") {
                        try? FileManager.default.createDirectory(at: model.library.folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(model.library.folder)
                    }
                    .help("Show the quick actions folder in Finder")
                    Button("Reload", systemImage: "arrow.clockwise") { model.reload() }
                        .help("Read the quick actions folder again")
                    Spacer()
                    Text(model.countText)
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
                if let entry = model.selectedEntry {
                    ActionDetailView(entry: entry, model: model)
                } else {
                    VStack(spacing: 12) {
                        ContentUnavailableView("No Quick Action Selected", systemImage: "bolt")
                        Button("Show Quick Actions Folder in Finder") { model.revealInFinder() }
                    }
                    .padding(.bottom, 40)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ActionRow: View {
    let entry: SavedActionEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                // One weight whether the row is selected or not.
                Text(entry.name)
                    .fontWeight(.regular)
                    .foregroundStyle(entry.action?.isEnabled == false ? .secondary : .primary)
                Text(entry.problem ?? entry.action?.description ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if entry.problem != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Has a problem")
            } else if entry.action?.isEnabled == false {
                Text("Off")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct ActionDetailView: View {
    let entry: SavedActionEntry
    let model: ActionsSettingsModel
    @State private var confirmingDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.name).font(.title2)
                        Text(entry.fileURL.path(percentEncoded: false))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    if let action = entry.action {
                        Toggle("Use \(entry.name)", isOn: Binding(
                            get: { action.isEnabled }, set: { model.setEnabled($0, entry) }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .help(action.isEnabled ? "On: typing its name offers it" : "Off: the panel does not offer it")
                    }
                }
                if let problem = entry.problem {
                    problemBox([problem])
                } else if let action = entry.action {
                    Text(action.description)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    let problems = model.problems(action)
                    if !problems.isEmpty { problemBox(problems) }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Typed as").font(.headline)
                        Text(([action.name] + action.phrases).map { "“\($0)”" }.joined(separator: ", "))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(action.steps.count == 1 ? "Step" : "Steps, in order").font(.headline)
                        ForEach(Array(action.steps.enumerated()), id: \.offset) { index, step in
                            ActionStepView(number: index + 1, step: step, summaries: model.summaries)
                        }
                        Text("Return runs every step without asking, since choosing the quick action is the go-ahead. A step that fails stops the rest.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let error = model.errorMessage {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                HStack {
                    Button("Open File") { model.open(entry) }
                    Button("Show in Finder") { model.revealInFinder() }
                    Spacer()
                    Button("Delete…", role: .destructive) { confirmingDelete = true }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Delete \(entry.name)?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { model.delete(entry) }
        } message: {
            Text("Its file is removed from the quick actions folder.")
        }
    }

    private func problemBox(_ problems: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill")
            }
        }
        .foregroundStyle(.orange)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 8))
    }
}

/// One step: what it does in the tool's words, the tool's name, and its arguments as JSON.
struct ActionStepView: View {
    let number: Int
    let step: SavedAction.Step
    let summaries: ToolCallSummaries
    @AgentName private var agentName

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).").foregroundStyle(.secondary).monospacedDigit()
                Text(summaries.summary(name: step.tool, arguments: step.arguments.encodedString()))
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(step.tool)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text(step.arguments.prettyEncodedString())
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            if let reason = ActionValidation.goAheadNote(step) {
                Text("When \(agentName) makes this call it asks first, because it \(reason). Here it runs without asking.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
