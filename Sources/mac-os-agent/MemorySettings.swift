import AppKit
import MacOSAgentCore
import Observation
import SwiftUI

/// Memory for Settings, for inspection and debugging: the agent manages it on its own. It is
/// kept live: the folder is watched, and the app's own changes post
/// `MemoryLibrary.didChangeNotification`.
@MainActor
@Observable
final class MemorySettingsModel {
    enum Item: Hashable {
        /// The block as the current episode has it.
        case block
        case core
        case topic(String)
        case archived(String)
    }

    private(set) var core: MemoryFile?
    private(set) var topics: [MemoryFile] = []
    private(set) var archived: [MemoryFile] = []
    /// The selected file's history, newest first.
    private(set) var history: [MemoryJournalEntry] = []
    var selection: Item? = .core {
        didSet {
            guard selection != oldValue else { return }
            viewedRevision = nil
            cancelEditing()
            loadHistory()
        }
    }
    /// The revision being viewed in place of the file as it is now.
    var viewedRevision: MemoryJournalEntry.ID?
    private(set) var isEditing = false
    var editText = ""
    var errorMessage: String?
    /// Nil where nothing set up memory, which shows nothing and changes nothing.
    @ObservationIgnored let library: MemoryLibrary?
    @ObservationIgnored let snapshot: MemorySnapshot?
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(prompt: AgentPrompt, watches: Bool = true) {
        library = prompt.memories
        snapshot = prompt.memorySnapshot
        reload()
        guard watches, let library else { return }
        watcher = FolderWatcher(folder: library.folder) { [weak self] in self?.reload() }
        observer = NotificationCenter.default.addObserver(
            forName: MemoryLibrary.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func reload() {
        if watcher?.isWatching == false { watcher?.rearm() }
        guard let library else { return }
        let core = library.core()
        if core != self.core { self.core = core }
        let topics = library.topics()
        if topics != self.topics { self.topics = topics }
        let archived = library.archived()
        if archived != self.archived { self.archived = archived }
        if let selection, selection != .block, selectedFile == nil { self.selection = .core }
        loadHistory()
    }

    private func loadHistory() {
        guard let library, let file = selectedFile else {
            if !history.isEmpty { history = [] }
            return
        }
        let fresh = Array(library.journal.history(of: file.path).reversed())
        if fresh != history { history = fresh }
    }

    var selectedFile: MemoryFile? {
        switch selection {
        case .core: core
        case .topic(let name): topics.first { $0.id == name }
        case .archived(let name): archived.first { $0.id == name }
        case .block, nil: nil
        }
    }

    var revision: MemoryJournalEntry? { history.first { $0.id == viewedRevision } }

    /// The block for the current episode: the one its first request took, or what the next
    /// request would take when none has yet.
    var block: (contents: MemoryBlock.Contents, taken: Date?)? {
        if let latest = snapshot?.latest { return (latest.contents, latest.date) }
        return library.map { (MemoryBlock.contents($0), nil) }
    }

    var coreSizeText: String {
        "\((core?.characters ?? 0).formatted()) of about \(MemoryLayout.coreCap.formatted()) characters"
    }

    var countText: String {
        let topics = topics.count == 1 ? "1 topic file" : "\(topics.count) topic files"
        return archived.isEmpty ? topics : "\(topics), \(archived.count) archived"
    }

    func beginEditing() {
        guard let file = selectedFile, file.kind != .archived else { return }
        editText = file.text
        isEditing = true
        errorMessage = nil
    }

    func cancelEditing() {
        isEditing = false
        editText = ""
    }

    func saveEditing() {
        guard let file = selectedFile else { return }
        perform(.edit(file: file.path, text: editText))
        if errorMessage == nil { cancelEditing() }
    }

    /// Writes the viewed revision back as the file's content, as a new journal entry.
    func restoreRevision() {
        guard let revision, let file = selectedFile else { return }
        perform(.restore(revision, file: file.path))
        if errorMessage == nil { viewedRevision = nil }
    }

    func unarchive() {
        guard let file = selectedFile, file.kind == .archived else { return }
        let before = Set(topics.map(\.id))
        perform(.unarchive(file: file.id))
        if errorMessage == nil, let topic = topics.first(where: { !before.contains($0.id) }) {
            selection = .topic(topic.id)
        }
    }

    func archive() {
        guard let file = selectedFile, file.kind == .topic else { return }
        perform(.delete(file: file.id))
    }

    private func perform(_ change: MemoryLibrary.Change) {
        guard let library else { return }
        do {
            try library.apply(change, cause: .settings)
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
        reload()
    }

    func showInFinder() {
        guard let library else { return }
        if let file = selectedFile, FileManager.default.fileExists(atPath: file.url.path(percentEncoded: false)) {
            NSWorkspace.shared.activateFileViewerSelecting([file.url])
            return
        }
        try? FileManager.default.createDirectory(at: library.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(library.folder)
    }
}

/// Memory as a list of its files beside the selected file and its history. It is for looking
/// at what the agent keeps, not for managing it.
struct MemorySettingsView: View {
    @Bindable var model: MemorySettingsModel
    @AgentName private var agentName

    var body: some View {
        VStack(spacing: 0) {
            Text("\(agentName) manages its memory itself. This section is for inspecting and debugging it.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    List(selection: $model.selection) {
                        Section("In Context") {
                            MemoryListRow(
                                title: "Memory Block",
                                detail: model.block.map { "\($0.contents.characters.formatted()) of \(MemoryLayout.blockCap.formatted()) characters" } ?? "")
                                .tag(MemorySettingsModel.Item.block)
                        }
                        Section("Core") {
                            MemoryListRow(title: "core.md", detail: model.coreSizeText, warning: (model.core?.characters ?? 0) > MemoryLayout.coreCap)
                                .tag(MemorySettingsModel.Item.core)
                        }
                        Section("Topic Files") {
                            if model.topics.isEmpty {
                                Text("None yet").fontWeight(.regular).foregroundStyle(.secondary)
                            }
                            ForEach(model.topics) { file in
                                MemoryListRow(
                                    title: file.id, subtitle: file.problem ?? file.description,
                                    detail: Self.sizeAndDate(file), warning: file.problem != nil)
                                    .tag(MemorySettingsModel.Item.topic(file.id))
                            }
                        }
                        if !model.archived.isEmpty {
                            Section("Archive") {
                                ForEach(model.archived) { file in
                                    MemoryListRow(title: file.id, subtitle: file.description, detail: Self.sizeAndDate(file), dimmed: true)
                                        .tag(MemorySettingsModel.Item.archived(file.id))
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .frame(maxHeight: .infinity)
                    Divider()
                    HStack(spacing: 8) {
                        Button("Show Memory Folder in Finder", systemImage: "folder") { model.showInFinder() }
                            .help("Show the memory folder in Finder")
                        Button("Reload", systemImage: "arrow.clockwise") { model.reload() }
                            .help("Read the memory folder again")
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
                    if model.selection == .block {
                        MemoryBlockDetail(model: model)
                    } else if let file = model.selectedFile {
                        MemoryFileDetail(file: file, model: model)
                    } else {
                        ContentUnavailableView("Nothing Selected", systemImage: "brain")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { model.reload() }
    }

    static func sizeAndDate(_ file: MemoryFile) -> String {
        let size = "\(file.characters.formatted()) characters"
        guard let modified = file.modified else { return size }
        return "\(size), \(modified.formatted(date: .abbreviated, time: .omitted))"
    }
}

struct MemoryListRow: View {
    let title: String
    var subtitle: String?
    let detail: String
    var warning = false
    var dimmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                // One weight whether the row is selected or not.
                Text(title)
                    .fontWeight(.regular)
                    .foregroundStyle(dimmed ? .secondary : .primary)
                if warning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Needs attention")
                }
            }
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .fontWeight(.regular)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(detail)
                .font(.caption)
                .fontWeight(.regular)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

/// The block exactly as the agent has it at the end of its instructions in this episode.
struct MemoryBlockDetail: View {
    let model: MemorySettingsModel
    @AgentName private var agentName

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Memory Block").font(.title2)
                if let block = model.block {
                    Text(Self.caption(block, agentName: agentName))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    MemoryText(text: block.contents.text)
                } else {
                    Text("Memory is not set up here.").foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func caption(_ block: (contents: MemoryBlock.Contents, taken: Date?), agentName: String) -> String {
        let size = "\(block.contents.characters.formatted()) of \(MemoryLayout.blockCap.formatted()) characters."
        let cut = block.contents.isCut ? " It is over the cap, so part is left out, and a line in it says so." : ""
        guard let taken = block.taken else {
            return "No request has been made since the app started. The next episode's first request takes this. \(size)\(cut)"
        }
        return """
            Frozen at \(taken.formatted(date: .abbreviated, time: .shortened)), when the current episode's first \
            request was made. \(agentName) has exactly this at the end of its instructions until the next \
            episode. \(size)\(cut)
            """
    }
}

/// A file: what it says now or at a revision, and its history from the journal.
struct MemoryFileDetail: View {
    let file: MemoryFile
    @Bindable var model: MemorySettingsModel
    @State private var confirmingArchive = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(file.kind == .core ? "core.md" : file.id).font(.title2)
                    Text(file.url.path(percentEncoded: false))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(file.kind == .core ? model.coreSizeText : MemorySettingsView.sizeAndDate(file))
                        .font(.callout)
                        .foregroundStyle(file.kind == .core && file.characters > MemoryLayout.coreCap ? .orange : .secondary)
                }
                if let problem = file.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let revision = model.revision {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Revision of \(revision.date.formatted(date: .abbreviated, time: .shortened)): \(MemoryHistoryList.operation(revision)), from \(revision.memoryCause.title).")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Show Current") { model.viewedRevision = nil }
                        Button("Restore This Revision") { model.restoreRevision() }
                            .disabled(revision.content == nil)
                    }
                    .padding(10)
                    .background(.tint.opacity(0.1), in: .rect(cornerRadius: 8))
                    MemoryText(text: revision.content ?? "This entry has no content: the file was gone from this path after it.")
                } else if model.isEditing {
                    TextEditor(text: $model.editText)
                        .font(.callout.monospaced())
                        .frame(minHeight: 220)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                    HStack {
                        Text("Saving journals this as a change from Settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { model.cancelEditing() }
                        Button("Save") { model.saveEditing() }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    MemoryText(text: file.text.isEmpty ? "core.md is empty." : file.text)
                }
                if let error = model.errorMessage {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                HStack {
                    if file.kind == .archived {
                        Button("Move Out of Archive") { model.unarchive() }
                    } else if !model.isEditing, model.revision == nil {
                        Button("Edit") { model.beginEditing() }
                    }
                    Button("Show in Finder") { model.showInFinder() }
                    Spacer()
                    if file.kind == .topic {
                        Button("Archive…") { confirmingArchive = true }
                    }
                }
                MemoryHistoryList(model: model)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Archive \(file.id)?", isPresented: $confirmingArchive) {
            Button("Archive") { model.archive() }
        } message: {
            Text("It moves to the archive folder and out of the memory block. The journal keeps every revision.")
        }
    }
}

/// The selected file's history from the journal, newest first. Choosing an entry shows that
/// revision.
struct MemoryHistoryList: View {
    @Bindable var model: MemorySettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("History").font(.headline)
            if model.history.isEmpty {
                Text("No changes are journaled yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.history) { entry in
                let selected = model.viewedRevision == entry.id
                Button {
                    model.viewedRevision = selected ? nil : entry.id
                } label: {
                    HStack(spacing: 10) {
                        Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                            .monospacedDigit()
                            .frame(width: 150, alignment: .leading)
                        Text(Self.operation(entry))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(entry.memoryCause.title)
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    // One weight whether the entry is chosen or not.
                    .fontWeight(.regular)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(.rect)
                    .background(selected ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(entry.content == nil ? "This entry has no content to show" : "Show this revision")
            }
        }
    }

    static func operation(_ entry: MemoryJournalEntry) -> String {
        if let from = entry.renamedFrom { return "Renamed from \(from.replacingOccurrences(of: ".md", with: ""))" }
        if let to = entry.archivedAs { return "Archived as \(to)" }
        if let to = entry.restoredAs { return "Moved out of the archive to \(to)" }
        return entry.operation.title
    }
}

/// A file's text, as it is on disk, in a box.
struct MemoryText: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.callout.monospaced())
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }
}
