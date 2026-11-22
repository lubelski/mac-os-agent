import Foundation
import UniformTypeIdentifiers

/// Opens a web address, a file, or a folder, with its default app or a named one, or shows it in Finder.
public struct OpenItemTool: AgentTool {
    public static let name = "open_item"

    public let system: any SystemControl
    public let applications: any ApplicationWorkspace

    public init(system: any SystemControl, applications: any ApplicationWorkspace) {
        self.system = system
        self.applications = applications
    }

    public var source: ToolSource { .system }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: Self.name,
            description: """
                Open a web address, a file, or a folder, with its default app or with the app named, or \
                show a file in Finder. Use \(OpenApplicationTool.name) to open an app on its own.
                """,
            parameters: Schema.object([
                "target": Schema.string("A URL such as https://example.com or mailto:sam@example.com, or a path such as ~/Documents/report.pdf."),
                "application": Schema.nullableString("The app to open it with, by name, bundle identifier, or path. Null for the default app."),
                "reveal_in_finder": Schema.nullableBoolean("True to select the file or folder in a Finder window instead of opening it."),
            ]))
    }

    public func summary(arguments: JSONValue) -> String {
        let target = arguments["target"]?.stringValue ?? "an item"
        if arguments["reveal_in_finder"]?.boolValue == true { return "Show \(target) in Finder" }
        if let app = arguments["application"]?.trimmedString, !app.isEmpty { return "Open \(target) with \(app)" }
        return "Open \(target)"
    }

    public func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        guard let target = arguments["target"]?.trimmedString, !target.isEmpty else {
            return "Error: the call did not include a target."
        }
        let url: URL
        var label = target
        if target.wholeMatch(of: /[A-Za-z][A-Za-z0-9+.\-]*:.*/) != nil, !target.hasPrefix("/") {
            guard let parsed = URL(string: target) ?? target.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).flatMap(URL.init(string:)) else {
                return "Error: \"\(target)\" is not a URL this tool can open."
            }
            if parsed.isFileURL {
                label = parsed.plainPath
                guard await system.fileInfo(atPath: label) != nil else { return "Error: there is nothing at \(label)." }
            }
            url = parsed
        } else {
            let path = SystemToolText.expandedPath(target)
            guard let info = await system.fileInfo(atPath: path) else {
                return "Error: there is nothing at \(path). Use \(FindFilesTool.name) to look for it."
            }
            label = info.path
            url = URL(filePath: info.path, directoryHint: info.isFolder ? .isDirectory : .notDirectory)
        }

        if arguments["reveal_in_finder"]?.boolValue == true {
            guard url.isFileURL else { return "Error: only a file or folder can be shown in Finder." }
            await system.revealInFinder(url)
            return "Showed \(label) in Finder."
        }

        var application: InstalledApplication?
        if let name = arguments["application"]?.trimmedString, !name.isEmpty {
            switch await SystemToolText.resolveApplication(name, in: applications) {
            case .success(let found): application = found
            case .failure(let error): return "Error: \(error.message)"
            }
        }
        do {
            try await system.open([url], withApplicationAt: application?.url)
        } catch {
            return "Error: could not open \(label): \(error.localizedDescription)"
        }
        return application.map { "Opened \(label) with \($0.name)." } ?? "Opened \(label) with its default app."
    }
}

/// Finds files and folders with Spotlight by name, kind, date, or what they contain.
public struct FindFilesTool: AgentTool {
    public static let name = "find_files"
    public static let defaultLimit = 20
    public static let maximumLimit = 100
    /// How many items to ask Spotlight for, before the newest are picked out.
    static let candidates = 500

    public static let kinds: [String: [String]] = [
        "folder": ["public.folder"],
        "image": ["public.image"],
        "movie": ["public.movie"],
        "audio": ["public.audio"],
        "pdf": ["com.adobe.pdf"],
        "text": ["public.text"],
        "document": ["public.composite-content", "public.text", "com.adobe.pdf"],
        "presentation": ["public.presentation"],
        "spreadsheet": ["public.spreadsheet"],
        "archive": ["public.archive"],
        "application": ["com.apple.application-bundle"],
    ]

    public let system: any SystemControl
    public let dates: LocalDates
    public let home: String

    public init(system: any SystemControl, dates: LocalDates = LocalDates(), home: String? = nil) {
        self.system = system
        self.dates = dates
        self.home = home ?? URL.homeDirectory.plainPath
    }

    public var source: ToolSource { .system }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: Self.name,
            description: """
                Find files and folders with Spotlight, newest first. Give at least one of name, content, \
                kind, or a modified date. Searches the home folder unless a folder is given, and leaves \
                out hidden files and ~/Library.
                """,
            parameters: Schema.object([
                "name": Schema.nullableString("Part of the file's name, ignoring case. Null for any."),
                "content": Schema.nullableString("Words inside the file, for documents Spotlight has read. Null for any."),
                "kind": Schema.nullableChoice(Self.kinds.keys.sorted(), "The kind of item. Null for any."),
                "modified_after": Schema.nullableString("Only items changed at or after this ISO 8601 date or date-time. Null for any."),
                "modified_before": Schema.nullableString("Only items changed before the end of this date, or before this date-time. Null for any."),
                "folder": Schema.nullableString("The folder to search in, such as ~/Documents. Null for the home folder."),
                "limit": Schema.nullableInteger("The most items to return, up to \(Self.maximumLimit). Null for \(Self.defaultLimit)."),
            ]))
    }

    public func summary(arguments: JSONValue) -> String {
        var parts = ["Find"]
        parts.append(arguments["kind"]?.stringValue.map { "\($0) items" } ?? "files")
        if let name = arguments["name"]?.trimmedString, !name.isEmpty { parts.append("named \"\(name)\"") }
        if let content = arguments["content"]?.trimmedString, !content.isEmpty { parts.append("containing \"\(content)\"") }
        if let folder = arguments["folder"]?.trimmedString, !folder.isEmpty { parts.append("in \(folder)") }
        return parts.joined(separator: " ")
    }

    public func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        let name = Self.cleaned(arguments["name"]?.stringValue)
        let content = Self.cleaned(arguments["content"]?.stringValue)
        var kindTypes: [String]?
        if let kind = arguments["kind"]?.stringValue {
            guard let types = Self.kinds[kind] else {
                return "Error: kind \"\(kind)\" is not one of \(Self.kinds.keys.sorted().joined(separator: ", "))."
            }
            kindTypes = types
        }
        var after: Date?
        var before: Date?
        for (key, isEnd) in [("modified_after", false), ("modified_before", true)] {
            guard let text = arguments[key]?.trimmedString, !text.isEmpty else { continue }
            guard let input = dates.parse(text) else {
                return "Error: \(key) \"\(text)\" is not an ISO 8601 date or date-time such as 2026-11-21 or 2026-11-21T09:00."
            }
            if isEnd { before = dates.endOfRange(reaching: input) } else { after = dates.start(of: input) }
        }
        guard name != nil || content != nil || kindTypes != nil || after != nil || before != nil else {
            return "Error: give at least one of name, content, kind, modified_after, or modified_before."
        }
        let limit = min(max(arguments["limit"]?.numberValue.map { Int($0) } ?? Self.defaultLimit, 1), Self.maximumLimit)

        var folder = home
        if let given = arguments["folder"]?.trimmedString, !given.isEmpty {
            let path = SystemToolText.expandedPath(given, home: home)
            guard let info = await system.fileInfo(atPath: path), info.isFolder else {
                return "Error: there is no folder at \(path)."
            }
            folder = info.path
        }

        let query = Self.query(name: name, content: content, types: kindTypes, after: after, before: before)
        let library = home + "/Library"
        let searchesLibrary = folder == library || folder.hasPrefix(library + "/")
        let found = await system.spotlight(query: query, scope: [folder], limit: Self.candidates)
            .filter { item in
                let relative = item.path.hasPrefix(folder + "/") ? String(item.path.dropFirst(folder.count + 1)) : item.path
                if relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return false }
                if !searchesLibrary, item.path == library || item.path.hasPrefix(library + "/") { return false }
                return true
            }
            .sorted { ($0.modified ?? .distantPast, $1.path) > ($1.modified ?? .distantPast, $0.path) }
        guard !found.isEmpty else { return "Nothing in \(folder) matches." }
        var lines = ["\(found.count) match\(found.count == 1 ? "" : "es") in \(folder), newest first, as path | kind | modified | size:"]
        lines += found.prefix(limit).map(line)
        if found.count > limit {
            lines.append("Showing the first \(limit) of \(found.count). Narrow the search to see the others.")
        }
        return lines.joined(separator: "\n")
    }

    func line(_ item: FileInfo) -> String {
        var parts = [item.path, item.isFolder ? "folder" : SystemToolText.kindName(item.contentType)]
        if let modified = item.modified { parts.append("modified \(dates.text(modified))") }
        if !item.isFolder, let size = item.size { parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
        return parts.joined(separator: " | ")
    }

    /// Removes the characters that would break out of a Spotlight string.
    static func cleaned(_ text: String?) -> String? {
        guard let text else { return nil }
        let cleaned = text.filter { !"\"\\*?'".contains($0) }.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// The Spotlight query for the search. Each word of the content must appear.
    static func query(name: String?, content: String?, types: [String]?, after: Date?, before: Date?) -> String {
        var clauses: [String] = []
        if let name { clauses.append("kMDItemFSName == \"*\(name)*\"cd") }
        if let content {
            clauses += content.split(whereSeparator: \.isWhitespace).map { "kMDItemTextContent == \"\($0)*\"cdw" }
        }
        if let types {
            let options = types.map { "kMDItemContentTypeTree == \"\($0)\"" }
            clauses.append(options.count == 1 ? options[0] : "(" + options.joined(separator: " || ") + ")")
        }
        let iso = ISO8601DateFormatter()
        if let after { clauses.append("kMDItemContentModificationDate >= $time.iso(\(iso.string(from: after)))") }
        if let before { clauses.append("kMDItemContentModificationDate < $time.iso(\(iso.string(from: before)))") }
        return clauses.joined(separator: " && ")
    }
}

/// Reads what is on the clipboard.
public struct ReadClipboardTool: AgentTool {
    public static let name = "read_clipboard"
    public static let textLimit = 16_000

    public let system: any SystemControl

    public init(system: any SystemControl) {
        self.system = system
    }

    public var source: ToolSource { .system }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: Self.name,
            description: "Read the clipboard: its text, or the paths of files copied in Finder, or else the kinds of data on it.",
            parameters: Schema.object([:]))
    }

    public func summary(arguments: JSONValue) -> String { "Read the clipboard" }

    public func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        let contents = await system.readClipboard()
        if !contents.filePaths.isEmpty {
            return "The clipboard holds \(contents.filePaths.count == 1 ? "a file" : "\(contents.filePaths.count) files") copied in Finder:\n"
                + contents.filePaths.joined(separator: "\n")
        }
        if let text = contents.text, !text.isEmpty {
            return text.count > Self.textLimit
                ? ShellCommandTool.limit(text, to: Self.textLimit)
                : text
        }
        if contents.types.isEmpty { return "The clipboard is empty." }
        return "The clipboard holds no text. The kinds of data on it are: \(contents.types.prefix(8).joined(separator: ", "))."
    }
}

/// Puts text on the clipboard.
public struct WriteClipboardTool: AgentTool {
    public static let name = "write_clipboard"

    public let system: any SystemControl

    public init(system: any SystemControl) {
        self.system = system
    }

    public var source: ToolSource { .system }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: Self.name,
            description: "Put text on the clipboard, replacing what was there, so the owner can paste it.",
            parameters: Schema.object(["text": Schema.string("The text to copy.")]))
    }

    public func summary(arguments: JSONValue) -> String { "Copy text to the clipboard" }

    public func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        guard let text = arguments["text"]?.stringValue, !text.isEmpty else {
            return "Error: the call did not include any text."
        }
        await system.writeClipboard(text)
        return "Copied \(text.count) character\(text.count == 1 ? "" : "s") to the clipboard."
    }
}

/// Sets the desktop picture from an image file.
public struct SetDesktopPictureTool: AgentTool {
    public static let name = "set_desktop_picture"

    public let system: any SystemControl

    public init(system: any SystemControl) {
        self.system = system
    }

    public var source: ToolSource { .system }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: Self.name,
            description: """
                Set the desktop picture on every screen to an image file on this Mac. To use a picture \
                from the web, download it to a file first.
                """,
            parameters: Schema.object(["path": Schema.string("The image file, such as ~/Pictures/sunset.jpg.")]))
    }

    public func summary(arguments: JSONValue) -> String {
        "Set the desktop picture to \(arguments["path"]?.stringValue ?? "an image")"
    }

    public func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        guard let given = arguments["path"]?.trimmedString, !given.isEmpty else {
            return "Error: the call did not include a path."
        }
        let path = SystemToolText.expandedPath(given)
        guard let info = await system.fileInfo(atPath: path) else {
            return "Error: there is nothing at \(path). Use \(FindFilesTool.name) to look for the image."
        }
        guard !info.isFolder, let type = info.contentType.flatMap(UTType.init), type.conforms(to: .image) else {
            return "Error: \(info.path) is not an image file."
        }
        do {
            let screens = try await system.setDesktopPicture(URL(filePath: info.path))
            return "Set the desktop picture to \(info.path) on \(screens == 1 ? "the screen" : "\(screens) screens")."
        } catch {
            return "Error: could not set the desktop picture: \(error.localizedDescription)"
        }
    }
}

/// Quits or hides a running app. Quitting asks for a go-ahead.
public struct QuitOrHideApplicationTool: AgentTool {
    public static let name = "quit_or_hide_application"

    public let system: any SystemControl
    public let applications: any ApplicationWorkspace
    /// The app's own bundle identifier, which this tool will not quit.
    public let ownBundleIdentifier: String?

    public init(system: any SystemControl, applications: any ApplicationWorkspace, ownBundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        self.system = system
        self.applications = applications
        self.ownBundleIdentifier = ownBundleIdentifier
    }

    public var source: ToolSource { .system }

    public var goAhead: ToolGoAhead { .sometimes("Asks before quitting an app. Hiding one does not ask.") }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: Self.name,
            description: """
                Quit a running app the way its Quit menu item does, so it can ask to save, or hide its \
                windows. Quitting asks the owner first.
                """,
            parameters: Schema.object([
                "application": Schema.string("The app's name, bundle identifier, or path, as \(ListRunningApplicationsTool.name) reports them."),
                "action": ["type": "string", "enum": ["quit", "hide"], "description": "Whether to quit or hide it."],
            ]))
    }

    public func summary(arguments: JSONValue) -> String {
        "\(arguments["action"]?.stringValue == "hide" ? "Hide" : "Quit") \(arguments["application"]?.stringValue ?? "an application")"
    }

    public func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        guard let wanted = arguments["application"]?.trimmedString, !wanted.isEmpty else {
            return "Error: the call did not include an application."
        }
        guard let action = arguments["action"]?.stringValue, ["quit", "hide"].contains(action) else {
            return "Error: action must be quit or hide."
        }
        let running = await applications.runningApplications()
        let path = wanted.hasPrefix("/") || wanted.hasPrefix("~") ? SystemToolText.expandedPath(wanted) : nil
        let normalized = ApplicationMatcher.normalized(wanted)
        let matches = running.filter { app in
            if let path { return app.url?.plainPath == path }
            if app.bundleIdentifier?.caseInsensitiveCompare(wanted) == .orderedSame { return true }
            return ApplicationMatcher.normalized(app.name) == normalized
                || app.url.map { ApplicationMatcher.normalized($0.deletingPathExtension().lastPathComponent) } == normalized
        }
        guard let app = matches.first else {
            return "Error: no running app matches \"\(wanted)\". Use \(ListRunningApplicationsTool.name) to see what is running."
        }
        let label = app.bundleIdentifier.map { "\(app.name) (\($0))" } ?? app.name
        if action == "hide" {
            return await system.hide(app) ? "Hid \(label)." : "Error: \(label) did not hide."
        }
        if let own = ownBundleIdentifier, app.bundleIdentifier == own {
            return "Error: mac-os-agent does not quit itself. The owner can quit it from its menu bar menu."
        }
        let approved = await context.confirm(ConfirmationRequest(callID: context.callID, command: "Quit \(label)", reason: "quits an app"))
        guard approved else { return "The owner declined. \(app.name) is still running." }
        if Task.isCancelled { return "The task was stopped before \(app.name) was quit." }
        switch await system.quit(app) {
        case .quit: return "Quit \(label)."
        case .stillRunning: return "Asked \(label) to quit. It is still running, perhaps asking the owner about unsaved work."
        }
    }
}

enum SystemToolText {
    /// A path with `~` expanded and without a trailing slash.
    static func expandedPath(_ path: String, home: String = URL.homeDirectory.plainPath) -> String {
        var path = path
        if path == "~" { path = home } else if path.hasPrefix("~/") { path = home + path.dropFirst(1) }
        return URL(filePath: path).plainPath
    }

    /// A few words for a uniform type identifier, such as `PDF document`.
    static func kindName(_ identifier: String?) -> String {
        guard let identifier, let type = UTType(identifier) else { return "file" }
        return type.localizedDescription ?? type.preferredFilenameExtension ?? identifier
    }

    /// Finds an installed app by path, bundle identifier, or a close match on its name.
    static func resolveApplication(_ name: String, in workspace: any ApplicationWorkspace) async -> Result<InstalledApplication, ToolInputError> {
        if name.hasPrefix("/") || name.hasPrefix("~") {
            let path = expandedPath(name)
            guard let app = await workspace.application(at: URL(filePath: path, directoryHint: .isDirectory)) else {
                return .failure(ToolInputError("there is no application bundle at \(path)."))
            }
            return .success(app)
        }
        if name.contains("."), let url = await workspace.applicationURL(forBundleIdentifier: name), let app = await workspace.application(at: url) {
            return .success(app)
        }
        let match = ApplicationMatcher.rank(query: name, applications: await workspace.installedApplications(), limit: 1).first
        guard let match, match.score >= ApplicationMatcher.closeMatchScore else {
            return .failure(ToolInputError("no installed app matches \"\(name)\". Use \(SearchApplicationsTool.name) to find it."))
        }
        return .success(match.application)
    }
}
