import Foundation
import Testing
@testable import MacOSAgentCore

private func app(_ name: String, _ identifier: String?, _ folder: String = "/Applications", alternates: [String] = []) -> InstalledApplication {
    InstalledApplication(
        name: name, bundleIdentifier: identifier,
        url: URL(filePath: "\(folder)/\(name).app", directoryHint: .isDirectory), alternateNames: alternates)
}

private let installed: [InstalledApplication] = [
    app("Google Chrome", "com.google.Chrome"),
    app("Google Chrome Canary", "com.google.Chrome.canary"),
    app("Visual Studio Code", "com.microsoft.VSCode"),
    app("Notion", "notion.id"),
    app("Notion Calendar", "com.cron.electron"),
    app("Calculator", "com.apple.calculator", "/System/Applications"),
    app("Calendar", "com.apple.iCal", "/System/Applications"),
    app("Safari", "com.apple.Safari", "/System/Cryptexes/App/System/Applications"),
    app("zoom.us", "us.zoom.xos"),
    app("GitHub Desktop", "com.github.GitHubClient"),
    app("System Settings", "com.apple.systempreferences", "/System/Applications"),
    app("Activity Monitor", "com.apple.ActivityMonitor", "/System/Applications/Utilities"),
    app("Microsoft Word", "com.microsoft.Word"),
]

private func top(_ query: String, running: Set<String> = []) -> String? {
    ApplicationMatcher.rank(query: query, applications: installed, runningPaths: running).first?.application.name
}

@Suite struct ApplicationMatcherTests {
    @Test func findsAppsFromLooseNames() {
        #expect(top("chrome") == "Google Chrome")
        #expect(top("Chrome") == "Google Chrome")
        #expect(top("vs code") == "Visual Studio Code")
        #expect(top("vscode") == "Visual Studio Code")
        #expect(top("visual studio") == "Visual Studio Code")
        #expect(top("notion") == "Notion")
        #expect(top("zoom") == "zoom.us")
        #expect(top("github") == "GitHub Desktop")
        #expect(top("settings") == "System Settings")
        #expect(top("activity") == "Activity Monitor")
        #expect(top("word") == "Microsoft Word")
    }

    @Test func anExactNameBeatsALongerOneThatStartsTheSame() {
        let names = ApplicationMatcher.rank(query: "notion", applications: installed).map(\.application.name)
        #expect(names.prefix(2) == ["Notion", "Notion Calendar"])
        #expect(top("calc") == "Calculator")
        #expect(top("calendar") == "Calendar")
    }

    @Test func matchesABundleIdentifier() {
        #expect(top("com.apple.calculator") == "Calculator")
        #expect(top("com.google.chrome") == "Google Chrome")
    }

    @Test func toleratesAOneLetterTypo() {
        #expect(top("crome") == "Google Chrome")
        #expect(top("safar") == "Safari")
        #expect(top("calculater") == "Calculator")
    }

    @Test func matchesInitials() {
        #expect(top("vsc") == "Visual Studio Code")
    }

    @Test func ignoresCaseAccentsAndPunctuation() {
        #expect(top("ZOOM.US") == "zoom.us")
        #expect(ApplicationMatcher.normalized("Café Zoom.us") == "cafezoomus")
    }

    @Test func returnsNothingForUnrelatedText() {
        #expect(ApplicationMatcher.rank(query: "xylophone", applications: installed).isEmpty)
        #expect(ApplicationMatcher.rank(query: "   ", applications: installed).isEmpty)
        #expect(ApplicationMatcher.rank(query: "!!", applications: installed).isEmpty)
    }

    @Test func aRunningAppWinsATie() {
        let twoCopies = [
            app("Xcode", "com.apple.dt.Xcode"),
            app("Xcode", "com.apple.dt.Xcode", "/Users/someone/Applications"),
        ]
        let running: Set<String> = ["/Users/someone/Applications/Xcode.app"]
        let ranked = ApplicationMatcher.rank(query: "xcode", applications: twoCopies, runningPaths: running)
        #expect(ranked.map(\.application.path) == ["/Users/someone/Applications/Xcode.app", "/Applications/Xcode.app"])
        #expect(ranked[0].isRunning)
    }

    @Test func theSamePathIsListedOnce() {
        let ranked = ApplicationMatcher.rank(query: "safari", applications: installed + installed)
        #expect(ranked.count == 1)
    }

    @Test func alternateNamesFromTheBundleMatch() {
        let apps = [app("Code", "com.example.code", alternates: ["Visual Studio Code"])]
        #expect(ApplicationMatcher.rank(query: "visual studio", applications: apps).count == 1)
    }

    @Test func systemComponentsRankBelowOrdinaryApps() {
        var placeholder = app("SettingsPlaceholder", "com.apple.Settings", "/System/Library/CoreServices")
        placeholder.isSystemComponent = true
        let ranked = ApplicationMatcher.rank(query: "settings", applications: [placeholder] + installed)
        #expect(ranked.map(\.application.name) == ["System Settings", "SettingsPlaceholder"])
    }

    @Test func respectsTheLimit() {
        #expect(ApplicationMatcher.rank(query: "c", applications: installed, limit: 2).count == 2)
    }

    @Test func editDistance() {
        #expect(ApplicationMatcher.editDistance("chrome", "chrome", limit: 1) == 0)
        #expect(ApplicationMatcher.editDistance("crome", "chrome", limit: 1) == 1)
        #expect(ApplicationMatcher.editDistance("abc", "xyz", limit: 1) == 2)
    }
}

/// A made-up Mac for the tools.
final class FakeApplicationWorkspace: ApplicationWorkspace, @unchecked Sendable {
    private let lock = NSLock()
    var installed: [InstalledApplication]
    var spotlight: [InstalledApplication]
    var running: [RunningApplication]
    var openError: Error?
    private var openedURLs: [URL] = []
    private var spotlightQueries: [String] = []

    init(installed: [InstalledApplication], spotlight: [InstalledApplication] = [], running: [RunningApplication] = []) {
        self.installed = installed
        self.spotlight = spotlight
        self.running = running
    }

    var opened: [URL] { lock.withLock { openedURLs } }
    var spotlightSearches: [String] { lock.withLock { spotlightQueries } }

    func installedApplications() async -> [InstalledApplication] { installed }

    func otherApplications(matching query: String) async -> [InstalledApplication] {
        lock.withLock { spotlightQueries.append(query) }
        return spotlight
    }

    func runningApplications() async -> [RunningApplication] { running }

    func applicationURL(forBundleIdentifier bundleIdentifier: String) async -> URL? {
        (installed + spotlight).first { $0.bundleIdentifier?.lowercased() == bundleIdentifier.lowercased() }?.url
    }

    func application(at url: URL) async -> InstalledApplication? {
        (installed + spotlight).first { $0.url.standardizedFileURL == url.standardizedFileURL }
    }

    func openApplication(at url: URL) async throws -> OpenApplicationOutcome {
        if let openError { throw openError }
        lock.withLock { openedURLs.append(url) }
        return running.contains { $0.url == url } ? .broughtToFront : .launched
    }
}

@Suite struct ApplicationToolTests {
    private let context = ToolRunContext(callID: "c", confirm: { _ in
        Issue.record("application tools never ask")
        return false
    })

    @Test func searchReportsNameIdentifierPathAndRunning() async {
        let workspace = FakeApplicationWorkspace(
            installed: installed,
            running: [RunningApplication(name: "Google Chrome", bundleIdentifier: "com.google.Chrome",
                                         url: URL(filePath: "/Applications/Google Chrome.app", directoryHint: .isDirectory))])
        let output = await SearchApplicationsTool(workspace: workspace).run(arguments: ["query": "chrome"], context: context)
        let lines = output.split(separator: "\n").map(String.init)
        #expect(lines[1] == "Google Chrome | com.google.Chrome | /Applications/Google Chrome.app | running")
        #expect(lines[2] == "Google Chrome Canary | com.google.Chrome.canary | /Applications/Google Chrome Canary.app")
        #expect(workspace.spotlightSearches.isEmpty)
    }

    @Test func searchAsksSpotlightOnlyWithoutAGoodMatch() async {
        let elsewhere = app("Figma", "com.figma.Desktop", "/Users/someone/Downloads")
        let workspace = FakeApplicationWorkspace(installed: installed, spotlight: [elsewhere])
        let output = await SearchApplicationsTool(workspace: workspace).run(arguments: ["query": "figma"], context: context)
        #expect(output.contains("Figma | com.figma.Desktop | /Users/someone/Downloads/Figma.app"))
        #expect(workspace.spotlightSearches == ["figma"])
    }

    @Test func searchFindsARunningAppOutsideTheStandardFolders() async {
        let workspace = FakeApplicationWorkspace(
            installed: installed,
            running: [RunningApplication(name: "Thing", bundleIdentifier: "com.example.thing",
                                         url: URL(filePath: "/Volumes/Disk/Thing.app", directoryHint: .isDirectory))])
        let output = await SearchApplicationsTool(workspace: workspace).run(arguments: ["query": "thing"], context: context)
        #expect(output.contains("Thing | com.example.thing | /Volumes/Disk/Thing.app | running"))
    }

    @Test func searchSaysWhenTheMatchesAreOnlyLoose() async {
        let workspace = FakeApplicationWorkspace(installed: [app("NotificationCenter", "com.apple.notificationcenterui")])
        let output = await SearchApplicationsTool(workspace: workspace).run(arguments: ["query": "notion"], context: context)
        #expect(output.hasPrefix("No close match for \"notion\"."))
        #expect(output.contains("NotificationCenter"))
    }

    @Test func searchSaysClearlyWhenNothingMatched() async {
        let workspace = FakeApplicationWorkspace(installed: installed)
        let output = await SearchApplicationsTool(workspace: workspace).run(arguments: ["query": "xylophone"], context: context)
        #expect(output.hasPrefix("No installed application matched \"xylophone\""))
    }

    @Test func searchRejectsMissingOrEmptyQueries() async {
        let tool = SearchApplicationsTool(workspace: FakeApplicationWorkspace(installed: installed))
        for arguments: JSONValue in [[:], ["query": ""], ["query": "  "], ["query": 3]] {
            #expect(await tool.run(arguments: arguments, context: context).hasPrefix("Error:"))
        }
    }

    @Test func openByBundleIdentifier() async {
        let workspace = FakeApplicationWorkspace(installed: installed)
        let output = await OpenApplicationTool(workspace: workspace)
            .run(arguments: ["bundle_identifier_or_path": "com.apple.calculator"], context: context)
        #expect(output == "Opened Calculator (com.apple.calculator). It is now in front.")
        #expect(workspace.opened == [URL(filePath: "/System/Applications/Calculator.app", directoryHint: .isDirectory)])
    }

    @Test func openByPathBringsARunningAppToTheFront() async {
        let url = URL(filePath: "/System/Cryptexes/App/System/Applications/Safari.app", directoryHint: .isDirectory)
        let workspace = FakeApplicationWorkspace(
            installed: installed, running: [RunningApplication(name: "Safari", bundleIdentifier: "com.apple.Safari", url: url)])
        let output = await OpenApplicationTool(workspace: workspace)
            .run(arguments: ["bundle_identifier_or_path": .string(url.path)], context: context)
        #expect(output == "Safari (com.apple.Safari) was already running. Brought it to the front.")
        #expect(workspace.opened == [url])
    }

    @Test func openReportsWhenNothingMatched() async {
        let workspace = FakeApplicationWorkspace(installed: installed)
        let tool = OpenApplicationTool(workspace: workspace)
        let unknownIdentifier = await tool.run(arguments: ["bundle_identifier_or_path": "com.example.missing"], context: context)
        #expect(unknownIdentifier.hasPrefix("Error: no installed application has the bundle identifier \"com.example.missing\""))
        let bareName = await tool.run(arguments: ["bundle_identifier_or_path": "chrome"], context: context)
        #expect(bareName.contains("search_applications"))
        let missingPath = await tool.run(arguments: ["bundle_identifier_or_path": "/Applications/Missing.app"], context: context)
        #expect(missingPath.hasPrefix("Error: there is no application bundle at /Applications/Missing.app"))
        let empty = await tool.run(arguments: ["bundle_identifier_or_path": " "], context: context)
        #expect(empty.hasPrefix("Error:"))
        #expect(workspace.opened.isEmpty)
    }

    @Test func openReportsAFailureToLaunch() async {
        struct Refused: LocalizedError { var errorDescription: String? { "the app is damaged" } }
        let workspace = FakeApplicationWorkspace(installed: installed)
        workspace.openError = Refused()
        let output = await OpenApplicationTool(workspace: workspace)
            .run(arguments: ["bundle_identifier_or_path": "com.apple.calculator"], context: context)
        #expect(output == "Error: could not open Calculator (com.apple.calculator): the app is damaged")
    }

    @Test func listRunningSortsByNameAndMarksState() async {
        let workspace = FakeApplicationWorkspace(installed: [], running: [
            RunningApplication(name: "Safari", bundleIdentifier: "com.apple.Safari",
                               url: URL(filePath: "/Applications/Safari.app"), isFrontmost: true),
            RunningApplication(name: "Finder", bundleIdentifier: "com.apple.finder",
                               url: URL(filePath: "/System/Library/CoreServices/Finder.app"), isHidden: true),
        ])
        let output = await ListRunningApplicationsTool(workspace: workspace).run(arguments: [:], context: context)
        #expect(output == """
            Finder | com.apple.finder | /System/Library/CoreServices/Finder.app | hidden
            Safari | com.apple.Safari | /Applications/Safari.app | frontmost
            """)
    }

    @Test func schemasAreStrict() throws {
        let workspace = FakeApplicationWorkspace(installed: [])
        let history = try ThreadStore(fileURL: temporaryThreadFile())
        let tools: [any AgentTool] = [
            SearchApplicationsTool(workspace: workspace), OpenApplicationTool(workspace: workspace),
            ListRunningApplicationsTool(workspace: workspace),
            SearchHistoryTool(history: history), ReadEpisodeTool(history: history),
        ] + BuiltInTools.make(applicationWorkspace: workspace, reminders: FakePersonalDataStore(), calendar: FakePersonalDataStore(), system: FakeSystemControl())
            .filter { $0.source != .builtIn }
        for tool in tools {
            let parameters = tool.definition.parameters
            #expect(parameters["additionalProperties"] == false)
            guard case .object(let properties) = parameters["properties"] else {
                Issue.record("no properties for \(tool.definition.name)")
                continue
            }
            let required = Set(parameters["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            #expect(required == Set(properties.keys), "strict mode needs every property listed as required")
        }
    }
}

@Suite struct ToolRegistryTests {
    @Test func builtInToolsAreAFixedOrderedList() throws {
        let workspace = FakeApplicationWorkspace(installed: [])
        let history = try ThreadStore(fileURL: temporaryThreadFile())
        let first = ToolRegistry(builtIn: BuiltInTools.make(applicationWorkspace: workspace, history: history))
        let second = ToolRegistry(builtIn: BuiltInTools.make(applicationWorkspace: workspace, history: history))
        // The list before the quick action tools is exactly as it was, so a cached prefix holds.
        let before = [
            "run_shell_command", "search_applications", "open_application", "list_running_applications", "load_skill",
            "search_history", "read_episode", "read_reminders", "change_reminders", "read_events", "change_events",
            "open_item", "find_files", "read_clipboard", "write_clipboard", "set_desktop_picture", "quit_or_hide_application",
            "read_themes", "change_theme",
        ]
        #expect(Array(first.definitions.map(\.name).prefix(before.count)) == before)
        // The memory tools come last, so every tool before them keeps its place.
        #expect(first.definitions.map(\.name) == before + ["read_quick_actions", "change_quick_action", "read_memory", "change_memory"])
        #expect(first.definitions == second.definitions)
    }

    @Test func additionalToolsGoAfterTheBuiltInsSortedByName() {
        final class Named: AgentTool, @unchecked Sendable {
            let name: String
            init(_ name: String) { self.name = name }
            var definition: ToolDefinition { ToolDefinition(name: name, description: "", parameters: ["type": "object"]) }
            func summary(arguments: JSONValue) -> String { name }
            func run(arguments: JSONValue, context: ToolRunContext) async -> String { "" }
        }
        let registry = ToolRegistry(builtIn: [Named("b"), Named("a")], additional: [Named("z"), Named("c"), Named("a")])
        #expect(registry.definitions.map(\.name) == ["b", "a", "c", "z"])
    }
}

@Suite struct ApplicationCatalogTests {
    @Test func readsBundlesAndNoticesNewOnes() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "mac-os-agent-catalog-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        func makeApp(_ relativePath: String, identifier: String, displayName: String? = nil) throws {
            let contents = folder.appending(path: relativePath).appending(path: "Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            var info: [String: Any] = ["CFBundleIdentifier": identifier]
            if let displayName { info["CFBundleDisplayName"] = displayName }
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: contents.appending(path: "Info.plist"))
        }
        try makeApp("One.app", identifier: "com.example.one", displayName: "The First")
        try makeApp("Suite/Two.app", identifier: "com.example.two")
        try makeApp("One.app/Contents/Helpers/Helper.app", identifier: "com.example.helper")

        let catalog = ApplicationCatalog(folders: [folder])
        let apps = catalog.applications()
        #expect(apps.map(\.name) == ["One", "Two"])
        #expect(apps[0].bundleIdentifier == "com.example.one")
        #expect(apps[0].alternateNames == ["The First"])

        // Adding an app changes the folder's modification date, so the next read sees it.
        Thread.sleep(forTimeInterval: 0.01)
        try makeApp("Three.app", identifier: "com.example.three")
        #expect(catalog.applications().map(\.name) == ["One", "Three", "Two"])
    }

    @Test func anAppUpdatedInPlaceIsReadAgain() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "mac-os-agent-catalog-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let info = folder.appending(path: "Placeholder.app/Contents/Info.plist")
        try FileManager.default.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
        func writeInfo(displayName: String, date: Date) throws {
            let plist = ["CFBundleIdentifier": "com.example.placeholder", "CFBundleDisplayName": displayName]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: info)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: info.path)
        }
        try writeInfo(displayName: "Old Name", date: Date(timeIntervalSince1970: 1_000_000))
        let folderDate = try #require(
            try FileManager.default.attributesOfItem(atPath: folder.path)[.modificationDate] as? Date)

        let catalog = ApplicationCatalog(folders: [folder])
        #expect(catalog.applications().map(\.alternateNames) == [["Old Name"]])

        // The updater rewrites the Info.plist inside the bundle. The folder the app sits in keeps
        // its date.
        try writeInfo(displayName: "New Name", date: Date(timeIntervalSince1970: 2_000_000))
        try FileManager.default.setAttributes([.modificationDate: folderDate], ofItemAtPath: folder.path)
        #expect(catalog.applications().map(\.alternateNames) == [["New Name"]])
    }

    @Test func aFolderThatIsNotAnAppIsNotAnApplication() {
        #expect(ApplicationCatalog.application(at: URL(filePath: "/Applications")) == nil)
        #expect(ApplicationCatalog.application(at: URL(filePath: "/nonexistent/Nothing.app")) == nil)
    }
}
