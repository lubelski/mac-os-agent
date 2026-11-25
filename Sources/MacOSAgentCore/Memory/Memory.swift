import CryptoKit
import Foundation
import Synchronization

/// The agent's memory: what it knows about the person from one episode to the next. The agent
/// manages it on its own with `read_memory` and `change_memory`. Settings shows it for
/// inspection and debugging.
///
/// It is a folder, `memory/` in the data folder:
///
/// - `core.md`: plain Markdown, the facts the agent needs in most episodes and every standing
///   rule or prohibition. It is in the memory block at the end of the instructions.
/// - `<name>.md`: a topic file, with `name` and `description` front matter as a `SKILL.md`
///   has, then a Markdown body. The block lists topic files by name and description, and the
///   agent reads one when its description matches the request.
/// - `archive/`: where a deleted topic file goes instead of being destroyed.
/// - `journal.jsonl`: the version history, one JSON line per change. See `MemoryJournal`.
///
/// The Markdown files are the current state and the journal is the history. Every change the
/// app makes is journaled, and a change made outside the app, in an editor or Finder, is found
/// by comparing hashes and journaled too, so the history has no holes.
public enum MemoryLayout {
    public static let coreName = "core"
    public static let coreFileName = "core.md"
    public static let archiveFolderName = "archive"
    public static let journalFileName = "journal.jsonl"

    /// The rough size `core.md` should stay under, in characters. The app says so in the tool's
    /// result when core nears or passes it.
    public static let coreCap = 4_000
    /// The most the memory block holds, core and the index of topic files together. Over it,
    /// the index and then core are cut, and a line says the rest can be read.
    public static let blockCap = 8_000
    /// At this share of the cap, a write's result says core is nearly full.
    public static let nearCapShare = 0.8
}

/// A topic file's front matter and body.
public struct MemoryTopicDocument: Sendable, Equatable {
    public var name: String
    public var description: String
    public var body: String

    public init(name: String, description: String, body: String) {
        self.name = name
        self.description = description
        self.body = body
    }

    /// Reads a topic file. The front matter follows the `SKILL.md` convention: `name` and
    /// `description` lines between two lines of three dashes, and other keys are ignored.
    public static func parse(_ text: String) throws(MemoryError) -> MemoryTopicDocument {
        do {
            let skill = try SkillDocument.parse(text)
            return MemoryTopicDocument(name: skill.name, description: skill.description, body: skill.body)
        } catch {
            throw MemoryError(error.description)
        }
    }

    /// The whole file: front matter, a blank line, the body, and a newline at the end.
    public var text: String {
        var text = "---\nname: \(name)\ndescription: \(Self.frontMatterValue(description))\n---\n"
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { text += "\n" + body + "\n" }
        return text
    }

    /// A one-line value, quoted when the front matter reader would otherwise change it.
    static func frontMatterValue(_ value: String) -> String {
        let value = AgentInstructions.singleLine(value)
        let needsQuotes = value.contains(" #") || value.hasPrefix("\"") || value.hasPrefix("'")
            || value.hasPrefix("|") || value.hasPrefix(">") || value.hasPrefix("#")
        guard needsQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The longest description, in characters. It is one line in the index.
    public static let descriptionLimit = 300
}

/// One Markdown file in the memory folder, as read now.
public struct MemoryFile: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case core
        case topic
        /// In `archive/`, out of the agent's view.
        case archived
    }

    /// The file's name without `.md`: `core`, a topic's name, or an archived file's name.
    public var id: String
    public var kind: Kind
    public var url: URL
    /// The whole file as it is on disk. Empty for a `core.md` that does not exist yet.
    public var text: String
    /// When the file last changed on disk. Nil for a missing `core.md`.
    public var modified: Date?
    /// The front matter's description, for a topic file that has one.
    public var description: String?
    /// Why the front matter cannot be read, or why it does not match the file. Nil when fine.
    public var problem: String?

    public var characters: Int { text.count }
    /// The path inside the memory folder, as the journal records it: `core.md`,
    /// `travel-plans.md`, or `archive/travel-plans.md`.
    public var path: String { kind == .archived ? "\(MemoryLayout.archiveFolderName)/\(id).md" : "\(id).md" }

    /// The body after the front matter, or the whole text when there is none.
    public var body: String {
        guard kind != .core, let document = try? MemoryTopicDocument.parse(text) else { return text }
        return document.body
    }
}

public struct MemoryError: Error, Equatable, CustomStringConvertible, LocalizedError {
    public var description: String
    public init(_ description: String) { self.description = description }
    public var errorDescription: String? { description }
}

/// What made a change: the agent in an episode, the owner in Settings, or something outside
/// the app, such as an editor.
public enum MemoryCause: Sendable, Equatable, Hashable {
    case episode(UUID?)
    case settings
    case outside

    /// As Settings shows it.
    public var title: String {
        switch self {
        case .episode: "Agent"
        case .settings: "Settings"
        case .outside: "Edited outside the app"
        }
    }
}

/// The memory folder: reads it, changes it one local edit at a time, and journals each change.
/// Reads never fail: a missing folder is an empty memory.
public struct MemoryLibrary: Sendable {
    /// Posted after the app changes memory, or finds a change made outside it.
    public static let didChangeNotification = Notification.Name("dev.lubelski.mac-os-agent.memoryDidChange")

    public let folder: URL
    public let now: @Sendable () -> Date

    /// One change at a time, from the agent, Settings, and the folder watch, so none writes
    /// over another or journals out of order.
    private static let writing = Mutex(())

    /// Makes nothing on disk. The folder is made by the first write.
    public init(folder: URL = AgentPaths.memoryFolder, now: @escaping @Sendable () -> Date = { Date() }) {
        self.folder = folder
        self.now = now
    }

    public var coreURL: URL { folder.appending(path: MemoryLayout.coreFileName) }
    public var archiveFolder: URL { folder.appending(path: MemoryLayout.archiveFolderName, directoryHint: .isDirectory) }
    public var journal: MemoryJournal { MemoryJournal(fileURL: folder.appending(path: MemoryLayout.journalFileName)) }

    // MARK: Reading

    /// `core.md` as it is now, or an empty core when there is no file yet.
    public func core() -> MemoryFile {
        let text = Self.read(coreURL)
        return MemoryFile(
            id: MemoryLayout.coreName, kind: .core, url: coreURL, text: text ?? "",
            modified: text == nil ? nil : Self.modified(coreURL))
    }

    /// The topic files, sorted by name.
    public func topics() -> [MemoryFile] {
        files(in: folder, kind: .topic)
    }

    /// The archived files, sorted by name.
    public func archived() -> [MemoryFile] {
        files(in: archiveFolder, kind: .archived)
    }

    /// Core, a topic file, or an archived one, by its name or path. `core`, `core.md`,
    /// `travel-plans`, `travel-plans.md`, and `archive/travel-plans.md` all work.
    public func file(named name: String) -> MemoryFile? {
        var name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let archivePrefix = MemoryLayout.archiveFolderName + "/"
        let inArchive = name.hasPrefix(archivePrefix)
        if inArchive { name.removeFirst(archivePrefix.count) }
        if name.hasSuffix(".md") { name.removeLast(3) }
        name = name.lowercased()
        if inArchive { return archived().first { $0.id == name } }
        if name == MemoryLayout.coreName { return core() }
        return topics().first { $0.id == name }
    }

    /// Every file the journal tracks, as it is now: core, the topic files, and the archive.
    public func allFiles() -> [MemoryFile] {
        [core()] + topics() + archived()
    }

    private func files(in folder: URL, kind: MemoryFile.Kind) -> [MemoryFile] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return contents
            .filter { $0.pathExtension == "md" && (kind != .topic || $0.lastPathComponent != MemoryLayout.coreFileName) }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
            .sorted { $0.deletingPathExtension().lastPathComponent < $1.deletingPathExtension().lastPathComponent }
            .map { url in
                let id = String(url.lastPathComponent.dropLast(3))
                let text = Self.read(url) ?? ""
                var file = MemoryFile(id: id, kind: kind, url: url, text: text, modified: Self.modified(url))
                do {
                    let document = try MemoryTopicDocument.parse(text)
                    file.description = document.description
                    if kind == .topic, document.name != id {
                        file.problem = "The name in its front matter is \(document.name), not \(id) as the file is named."
                    }
                } catch {
                    file.problem = String(describing: error)
                }
                return file
            }
    }

    static func read(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        // A file that is not UTF-8 is read as Latin-1 rather than dropped.
        var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // MARK: Changing

    /// One change, as the tool and Settings ask for it.
    public enum Change: Sendable, Equatable {
        /// A new topic file.
        case create(name: String, description: String, body: String)
        /// Replaces exactly one occurrence of `old` with `new` in core or a topic file's body.
        case replace(file: String, old: String, new: String)
        /// Removes exactly one occurrence of the text from core or a topic file's body.
        case remove(file: String, text: String)
        /// Adds text at the end of core or a topic file, on a line of its own.
        case append(file: String, text: String)
        case setDescription(file: String, description: String)
        case rename(file: String, newName: String)
        /// Moves a topic file into the archive.
        case delete(file: String)
        /// Writes a whole file as given, from Settings.
        case edit(file: String, text: String)
        /// Writes a journaled revision back as the content of the file now at `file`, the path
        /// whose history it is in.
        case restore(MemoryJournalEntry, file: String)
        /// Moves an archived file back among the topic files.
        case unarchive(file: String)
    }

    /// What a change did, for the tool's result and the notice.
    public struct ChangeResult: Sendable, Equatable {
        /// The journal entries it added, in order.
        public var entries: [MemoryJournalEntry]
        /// A sentence saying what changed.
        public var summary: String
    }

    /// Makes a change and journals it. Any change made outside the app since the last one is
    /// journaled first, so the history stays in order.
    @discardableResult
    public func apply(_ change: Change, cause: MemoryCause) throws -> ChangeResult {
        let result = try Self.writing.withLock { _ in
            _ = try reconcileLocked()
            return try applyLocked(change, cause: cause)
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        return result
    }

    private func applyLocked(_ change: Change, cause: MemoryCause) throws -> ChangeResult {
        switch change {
        case .create(let name, let description, let body):
            let name = try Self.checkedName(name)
            let description = try Self.checkedDescription(description)
            if topics().contains(where: { $0.id == name }) {
                throw MemoryError("There is already a topic file \(name). Change it instead.")
            }
            let document = MemoryTopicDocument(name: name, description: description, body: body)
            let url = topicURL(name)
            try write(document.text, to: url)
            let entry = try record(.create, file: "\(name).md", content: document.text, cause: cause)
            return ChangeResult(entries: [entry], summary: "Created the topic file \(name).")

        case .replace(let name, let old, let new):
            let file = try existing(name)
            guard !old.isEmpty else { throw MemoryError("replace needs the exact text to replace in old_text.") }
            let updated = try replacing(old, with: new, in: file)
            try write(updated, to: file.url)
            let entry = try record(.replace, file: file.path, content: updated, cause: cause)
            return ChangeResult(entries: [entry], summary: "Replaced the text in \(file.id).")

        case .remove(let name, let text):
            let file = try existing(name)
            guard !text.isEmpty else { throw MemoryError("remove needs the exact text to remove in old_text.") }
            let updated = try replacing(text, with: "", in: file)
            try write(updated, to: file.url)
            let entry = try record(.remove, file: file.path, content: updated, cause: cause)
            return ChangeResult(entries: [entry], summary: "Removed the text from \(file.id).")

        case .append(let name, let text):
            let file = try existing(name)
            let addition = text.trimmingCharacters(in: .newlines)
            guard !addition.trimmingCharacters(in: .whitespaces).isEmpty else { throw MemoryError("append needs some text.") }
            var updated = file.text
            while updated.hasSuffix("\n") { updated.removeLast() }
            updated = updated.isEmpty ? addition + "\n" : updated + "\n" + addition + "\n"
            try write(updated, to: file.url)
            let entry = try record(.append, file: file.path, content: updated, cause: cause)
            return ChangeResult(entries: [entry], summary: "Added to \(file.id).")

        case .setDescription(let name, let description):
            let file = try existingTopic(name)
            let description = try Self.checkedDescription(description)
            var document = try readable(file)
            document.description = description
            try write(document.text, to: file.url)
            let entry = try record(.setDescription, file: file.path, content: document.text, cause: cause)
            return ChangeResult(entries: [entry], summary: "Changed the description of \(file.id).")

        case .rename(let name, let newName):
            let file = try existingTopic(name)
            let newName = try Self.checkedName(newName)
            guard newName != file.id else { throw MemoryError("\(file.id) already has that name.") }
            if topics().contains(where: { $0.id == newName }) { throw MemoryError("There is already a topic file \(newName).") }
            var document = try readable(file)
            document.name = newName
            let url = topicURL(newName)
            try write(document.text, to: url)
            try FileManager.default.removeItem(at: file.url)
            var entry = MemoryJournalEntry(
                date: now(), file: "\(newName).md", operation: .rename, content: document.text, cause: cause)
            entry.renamedFrom = file.path
            try journal.append(entry)
            return ChangeResult(entries: [entry], summary: "Renamed \(file.id) to \(newName).")

        case .delete(let name):
            let file = try existingTopic(name)
            let target = archiveURL(for: file.id)
            try FileManager.default.createDirectory(at: archiveFolder, withIntermediateDirectories: true)
            do {
                try FileManager.default.moveItem(at: file.url, to: target)
            } catch {
                throw MemoryError("Could not move \(file.id) to the archive: \(error.localizedDescription)")
            }
            var entry = MemoryJournalEntry(date: now(), file: file.path, operation: .archive, content: nil, cause: cause)
            entry.archivedAs = "\(MemoryLayout.archiveFolderName)/\(target.lastPathComponent)"
            try journal.append(entry)
            // The archived copy is a file of its own in the history, so it can be read and restored.
            let copy = try record(.archive, file: entry.archivedAs!, content: file.text, cause: cause)
            return ChangeResult(entries: [entry, copy], summary: "Archived \(file.id). It is no longer in your memory.")

        case .edit(let name, let text):
            guard let file = file(named: name) else { throw Self.missing(name) }
            guard text != file.text else { return ChangeResult(entries: [], summary: "\(file.id) is unchanged.") }
            try write(text, to: file.url)
            let entry = try record(.edit, file: file.path, content: text, cause: cause)
            return ChangeResult(entries: [entry], summary: "Saved \(file.id).")

        case .restore(let revision, let path):
            guard var content = revision.content else { throw MemoryError("That entry holds no revision to restore.") }
            // A revision from before a rename takes the name the file has now.
            let name = String(path.split(separator: "/").last ?? "").replacingOccurrences(of: ".md", with: "")
            if path != MemoryLayout.coreFileName, var document = try? MemoryTopicDocument.parse(content), document.name != name {
                document.name = name
                content = document.text
            }
            try write(content, to: folder.appending(path: path))
            var entry = MemoryJournalEntry(date: now(), file: path, operation: .restore, content: content, cause: cause)
            entry.restoredFrom = revision.id
            try journal.append(entry)
            return ChangeResult(entries: [entry], summary: "Restored \(path) as it was on \(revision.date.formatted()).")

        case .unarchive(let name):
            guard let file = archived().first(where: { $0.id == name || $0.path == name }) else { throw Self.missing(name) }
            var topicName = file.id
            if let document = try? MemoryTopicDocument.parse(file.text), SkillDocument.isValidName(document.name) {
                topicName = document.name
            }
            guard !topics().contains(where: { $0.id == topicName }) else {
                throw MemoryError("There is already a topic file \(topicName). Rename or archive it first.")
            }
            let target = topicURL(topicName)
            try FileManager.default.moveItem(at: file.url, to: target)
            var removal = MemoryJournalEntry(date: now(), file: file.path, operation: .unarchive, content: nil, cause: cause)
            removal.restoredAs = "\(topicName).md"
            try journal.append(removal)
            let entry = try record(.unarchive, file: "\(topicName).md", content: file.text, cause: cause)
            return ChangeResult(entries: [removal, entry], summary: "Moved \(topicName) back out of the archive.")
        }
    }

    /// Journals any change made outside the app: a file whose hash is not the one the journal
    /// last recorded for it, a new file, or a file that is gone. Returns the entries it added.
    /// Called at launch, when the folder changes, and before every change the app makes.
    @discardableResult
    public func reconcile() -> [MemoryJournalEntry] {
        let entries = (try? Self.writing.withLock { _ in try reconcileLocked() }) ?? []
        if !entries.isEmpty { NotificationCenter.default.post(name: Self.didChangeNotification, object: nil) }
        return entries
    }

    private func reconcileLocked() throws -> [MemoryJournalEntry] {
        guard FileManager.default.fileExists(atPath: folder.plainPath) else { return [] }
        let known = journal.latestHashes()
        var added: [MemoryJournalEntry] = []
        var present = Set<String>()
        for file in allFiles() {
            // A missing core.md is an empty one, not a file.
            if file.kind == .core, file.modified == nil { continue }
            present.insert(file.path)
            let hash = MemoryJournal.hash(file.text)
            if let recorded = known[file.path], recorded == hash { continue }
            let entry = MemoryJournalEntry(date: now(), file: file.path, operation: .outsideEdit, content: file.text, cause: .outside)
            try journal.append(entry)
            added.append(entry)
        }
        for (path, hash) in known.sorted(by: { $0.key < $1.key }) where hash != nil && !present.contains(path) {
            let entry = MemoryJournalEntry(date: now(), file: path, operation: .outsideRemoval, content: nil, cause: .outside)
            try journal.append(entry)
            added.append(entry)
        }
        return added
    }

    // MARK: Helpers

    func topicURL(_ name: String) -> URL { folder.appending(path: "\(name).md") }

    /// `archive/<name>.md`, or with a number after the name when that is taken.
    func archiveURL(for name: String) -> URL {
        var candidate = archiveFolder.appending(path: "\(name).md")
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.plainPath) {
            candidate = archiveFolder.appending(path: "\(name)-\(number).md")
            number += 1
        }
        return candidate
    }

    private func existing(_ name: String) throws -> MemoryFile {
        guard let file = file(named: name), file.kind != .archived else { throw Self.missing(name) }
        return file
    }

    private func existingTopic(_ name: String) throws -> MemoryFile {
        let file = try existing(name)
        guard file.kind == .topic else {
            throw MemoryError("core has no name or description and cannot be renamed or archived. Use replace or remove to change what it says.")
        }
        return file
    }

    private func readable(_ file: MemoryFile) throws -> MemoryTopicDocument {
        do {
            var document = try MemoryTopicDocument.parse(file.text)
            document.name = file.id
            return document
        } catch {
            throw MemoryError("\(file.id) has no readable front matter: \(error.description) Fix it with replace on the whole file, or ask the person to fix it in Settings.")
        }
    }

    /// The file's text with exactly one occurrence of `old` replaced. In a topic file only the
    /// body is searched, so an edit never breaks the front matter.
    private func replacing(_ old: String, with new: String, in file: MemoryFile) throws -> String {
        var document: MemoryTopicDocument?
        var text = file.text
        if file.kind == .topic, let parsed = try? MemoryTopicDocument.parse(file.text) {
            document = parsed
            text = parsed.body
        }
        let count = text.ranges(of: old).count
        if count == 0 {
            throw MemoryError("That text is not in \(file.id). Call \(ReadMemoryTool.name) with \"\(file.id)\" to see what it says now, and copy the text exactly.")
        }
        if count > 1 {
            throw MemoryError("That text is in \(file.id) \(count) times. Include more of the text around it so it matches once.")
        }
        var updated = text.replacing(old, with: new, maxReplacements: 1)
        if new.isEmpty {
            // Removing a whole line leaves no empty line behind.
            updated = updated.replacingOccurrences(of: "\n\n\n", with: "\n\n")
            if updated.hasPrefix("\n") { updated.removeFirst() }
        }
        if var document {
            document.body = updated
            return document.text
        }
        return updated
    }

    private func write(_ text: String, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            throw MemoryError("Could not write \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func record(_ operation: MemoryJournalEntry.Operation, file: String, content: String, cause: MemoryCause) throws -> MemoryJournalEntry {
        let entry = MemoryJournalEntry(date: now(), file: file, operation: operation, content: content, cause: cause)
        try journal.append(entry)
        return entry
    }

    static func missing(_ name: String) -> MemoryError {
        MemoryError("There is no memory file \(name). Call \(ReadMemoryTool.name) with file null for the list.")
    }

    static func checkedName(_ name: String) throws -> String {
        var name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasSuffix(".md") { name.removeLast(3) }
        guard SkillDocument.isValidName(name) else {
            throw MemoryError("\"\(name)\" is not a topic file name. Use lowercase letters, digits, and hyphens, up to 64 characters.")
        }
        guard name != MemoryLayout.coreName, name != MemoryLayout.archiveFolderName, name != "journal" else {
            throw MemoryError("\(name) is reserved. Choose another name.")
        }
        return name
    }

    static func checkedDescription(_ description: String) throws -> String {
        let description = AgentInstructions.singleLine(description)
        guard !description.isEmpty else { throw MemoryError("A topic file needs a description that says when to read it.") }
        guard description.count <= MemoryTopicDocument.descriptionLimit else {
            throw MemoryError("The description is \(description.count) characters. Keep it to one line of at most \(MemoryTopicDocument.descriptionLimit).")
        }
        return description
    }
}

extension MemoryLibrary {
    /// The line after a write that says how big core is against its cap, and what to do when it
    /// is nearly or over full.
    public func sizeNote() -> String {
        let core = core().characters
        let cap = MemoryLayout.coreCap
        let block = MemoryBlock.contents(self)
        var note = "core.md is \(core.formatted()) of about \(cap.formatted()) characters, and the memory block is \(block.characters.formatted()) of \(MemoryLayout.blockCap.formatted())."
        if core > cap {
            note += " Core is over its cap. Move long or topic-specific items into a topic file now, so the standing rules and the facts needed in most episodes stay in view."
        } else if Double(core) >= Double(cap) * MemoryLayout.nearCapShare {
            note += " Core is nearly full. Move the least general items into a topic file."
        }
        if block.isCut { note += " The block is over its cap, so part of it is left out." }
        return note
    }

    /// The one line the panel shows after a turn that changed memory, such as "Remembered in
    /// core." or "Remembered in travel-plans. Forgot old-trips.", or nil when nothing changed.
    public static func changeNotice(_ entries: [MemoryJournalEntry]) -> String? {
        var remembered: [String] = []
        var updated: [String] = []
        var forgotten: [String] = []
        var removedFrom: [String] = []
        func add(_ name: String, to list: inout [String]) {
            if !list.contains(name) { list.append(name) }
        }
        for entry in entries {
            guard case .episode = entry.memoryCause else { continue }
            let name = entry.displayName
            switch entry.operation {
            case .create, .append: add(name, to: &remembered)
            case .replace, .setDescription, .rename, .edit, .restore, .unarchive: add(name, to: &updated)
            case .remove: add(name, to: &removedFrom)
            case .archive where entry.archivedAs != nil: add(name, to: &forgotten)
            case .archive, .outsideEdit, .outsideRemoval: break
            }
        }
        updated.removeAll { remembered.contains($0) }
        func names(_ list: [String]) -> String {
            switch list.count {
            case 1: list[0]
            case 2: "\(list[0]) and \(list[1])"
            default: "\(list.count) files"
            }
        }
        var sentences: [String] = []
        if !remembered.isEmpty { sentences.append("Remembered in \(names(remembered)).") }
        if !updated.isEmpty { sentences.append("Updated \(names(updated)).") }
        if !removedFrom.isEmpty { sentences.append("Forgot something in \(names(removedFrom)).") }
        if !forgotten.isEmpty { sentences.append("Forgot \(names(forgotten)).") }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }
}
