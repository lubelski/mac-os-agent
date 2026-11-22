import Foundation

/// Finds installed applications by a loose name.
public struct SearchApplicationsTool: AgentTool {
    public static let name = "search_applications"

    public var workspace: any ApplicationWorkspace
    public var limit: Int

    public init(workspace: any ApplicationWorkspace, limit: Int = 8) {
        self.workspace = workspace
        self.limit = limit
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: Self.name,
            description: """
                Search the applications installed on this Mac by name. Matching is loose: "chrome", \
                "vs code", and "notion" find Google Chrome, Visual Studio Code, and Notion. Looks in \
                /Applications, ~/Applications, the system app folders, and Spotlight. Returns the best \
                matches first, each with its name, bundle identifier, path, and whether it is running.
                """,
            parameters: [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "Part of the app's name, or its bundle identifier.",
                    ],
                ],
                "required": ["query"],
                "additionalProperties": false,
            ])
    }

    public func summary(arguments: JSONValue) -> String {
        guard let query = arguments["query"]?.trimmedString, !query.isEmpty else { return "Search applications" }
        return "Search applications for \"\(query)\""
    }

    public func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        guard let query = arguments["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ApplicationMatcher.normalized(query).isEmpty
        else {
            return "Error: the call did not include a query with letters or digits in it."
        }
        let running = await workspace.runningApplications()
        let runningPaths = Set(running.compactMap { $0.url?.plainPath })
        // Running apps are candidates too, since they can live outside the standard folders.
        let runningApps = running.compactMap { app -> InstalledApplication? in
            guard let url = app.url else { return nil }
            return InstalledApplication(name: url.deletingPathExtension().lastPathComponent,
                                        bundleIdentifier: app.bundleIdentifier, url: url,
                                        alternateNames: [app.name])
        }
        var candidates = await workspace.installedApplications() + runningApps
        var matches = ApplicationMatcher.rank(query: query, applications: candidates, runningPaths: runningPaths, limit: limit)
        if (matches.first?.score ?? 0) < ApplicationMatcher.closeMatchScore {
            candidates += await workspace.otherApplications(matching: query)
            matches = ApplicationMatcher.rank(query: query, applications: candidates, runningPaths: runningPaths, limit: limit)
        }
        guard !matches.isEmpty else {
            return "No installed application matched \"\(query)\". Try a shorter or different part of its name."
        }
        let header = matches[0].score >= ApplicationMatcher.closeMatchScore
            ? "Best match first, as name | bundle identifier | path:"
            : "No close match for \"\(query)\". These loose matches may not be what was meant, as name | bundle identifier | path:"
        return header + "\n" + matches.map { match in
            ApplicationToolText.line(
                name: match.application.name, bundleIdentifier: match.application.bundleIdentifier,
                path: match.application.path, notes: match.isRunning ? ["running"] : [])
        }.joined(separator: "\n")
    }
}

/// Opens an application, or brings it to the front when it is already running.
public struct OpenApplicationTool: AgentTool {
    public static let name = "open_application"

    public var workspace: any ApplicationWorkspace

    public init(workspace: any ApplicationWorkspace) {
        self.workspace = workspace
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: Self.name,
            description: """
                Open an application, or bring it to the front if it is already running. Pass its bundle \
                identifier or the path to its .app bundle, as search_applications reports them.
                """,
            parameters: [
                "type": "object",
                "properties": [
                    "bundle_identifier_or_path": [
                        "type": "string",
                        "description": "A bundle identifier such as com.apple.calculator, or a path such as /Applications/Safari.app.",
                    ],
                ],
                "required": ["bundle_identifier_or_path"],
                "additionalProperties": false,
            ])
    }

    public func summary(arguments: JSONValue) -> String {
        guard let target = arguments["bundle_identifier_or_path"]?.trimmedString, !target.isEmpty else { return "Open an application" }
        // A path reads as the app's name, such as Safari for /Applications/Safari.app.
        if target.hasPrefix("/") || target.hasPrefix("~") {
            return "Open \(URL(filePath: target).deletingPathExtension().lastPathComponent)"
        }
        return "Open \(target)"
    }

    public func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        guard let target = arguments["bundle_identifier_or_path"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty
        else {
            return "Error: the call did not include a bundle identifier or path."
        }
        let application: InstalledApplication
        if target.hasPrefix("/") || target.hasPrefix("~") {
            let path = (target as NSString).expandingTildeInPath
            guard let found = await workspace.application(at: URL(filePath: path, directoryHint: .isDirectory)) else {
                return "Error: there is no application bundle at \(path). Use \(SearchApplicationsTool.name) to find the app."
            }
            application = found
        } else {
            guard let url = await workspace.applicationURL(forBundleIdentifier: target),
                  let found = await workspace.application(at: url)
            else {
                let hint = target.contains(".")
                    ? "Use \(SearchApplicationsTool.name) to find the right one."
                    : "Pass a bundle identifier such as com.apple.calculator, or use \(SearchApplicationsTool.name) to find the app first."
                return "Error: no installed application has the bundle identifier \"\(target)\". \(hint)"
            }
            application = found
        }
        let label = application.bundleIdentifier.map { "\(application.name) (\($0))" } ?? application.name
        do {
            switch try await workspace.openApplication(at: application.url) {
            case .launched: return "Opened \(label). It is now in front."
            case .broughtToFront: return "\(label) was already running. Brought it to the front."
            }
        } catch {
            return "Error: could not open \(label): \(error.localizedDescription)"
        }
    }
}

/// Lists the applications that are running now.
public struct ListRunningApplicationsTool: AgentTool {
    public static let name = "list_running_applications"

    public var workspace: any ApplicationWorkspace

    public init(workspace: any ApplicationWorkspace) {
        self.workspace = workspace
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: Self.name,
            description: """
                List the applications running now that have a Dock icon, with each one's name, bundle \
                identifier, path, and whether it is frontmost or hidden.
                """,
            parameters: [
                "type": "object",
                "properties": [:],
                "required": [],
                "additionalProperties": false,
            ])
    }

    public func summary(arguments: JSONValue) -> String { "List running applications" }

    public func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        let running = await workspace.runningApplications()
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !running.isEmpty else { return "No applications with a Dock icon are running." }
        return running.map { app in
            var notes: [String] = []
            if app.isFrontmost { notes.append("frontmost") }
            if app.isHidden { notes.append("hidden") }
            return ApplicationToolText.line(
                name: app.name, bundleIdentifier: app.bundleIdentifier,
                path: app.url?.plainPath, notes: notes)
        }.joined(separator: "\n")
    }
}

enum ApplicationToolText {
    /// One app per line: `Google Chrome | com.google.Chrome | /Applications/Google Chrome.app | running`.
    static func line(name: String, bundleIdentifier: String?, path: String?, notes: [String]) -> String {
        ([name, bundleIdentifier ?? "(no bundle identifier)", path ?? "(no path)"] + notes).joined(separator: " | ")
    }
}
