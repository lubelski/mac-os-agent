import Foundation
import Testing
@testable import MacOSAgentCore

/// Files, the clipboard, the desktop picture, and running apps held in memory. Nothing real is
/// opened, written, set, or quit.
final class FakeSystemControl: SystemControl, @unchecked Sendable {
    private let lock = NSLock()
    var files: [String: FileInfo] = [:]
    var spotlightResults: [FileInfo] = []
    var clipboard = ClipboardContents()
    var screens = 2
    var quitOutcome: QuitOutcome = .quit
    private(set) var opened: [([URL], URL?)] = []
    private(set) var revealed: [URL] = []
    private(set) var queries: [(String, [String], Int)] = []
    private(set) var desktopPictures: [URL] = []
    private(set) var quitApps: [String] = []
    private(set) var hiddenApps: [String] = []

    init(files: [FileInfo] = []) {
        for file in files { self.files[file.path] = file }
    }

    func fileInfo(atPath path: String) async -> FileInfo? { lock.withLock { files[path] } }
    func open(_ urls: [URL], withApplicationAt application: URL?) async throws { lock.withLock { opened.append((urls, application)) } }
    func revealInFinder(_ url: URL) async { lock.withLock { revealed.append(url) } }
    func spotlight(query: String, scope: [String], limit: Int) async -> [FileInfo] {
        lock.withLock {
            queries.append((query, scope, limit))
            return spotlightResults
        }
    }
    func readClipboard() async -> ClipboardContents { lock.withLock { clipboard } }
    func writeClipboard(_ text: String) async { lock.withLock { clipboard = ClipboardContents(text: text, types: ["public.utf8-plain-text"]) } }
    func setDesktopPicture(_ url: URL) async throws -> Int {
        lock.withLock {
            desktopPictures.append(url)
            return screens
        }
    }
    func quit(_ application: RunningApplication) async -> QuitOutcome {
        lock.withLock {
            quitApps.append(application.name)
            return quitOutcome
        }
    }
    func hide(_ application: RunningApplication) async -> Bool {
        lock.withLock {
            hiddenApps.append(application.name)
            return true
        }
    }
}

private let home = "/Users/owner"
private let pacific = LocalDates(timeZone: TimeZone(identifier: "America/Los_Angeles")!)

private func moment(_ text: String) -> Date {
    guard case .moment(let date, _)? = pacific.parse(text) else { fatalError(text) }
    return date
}

private let neverAsks = ToolRunContext(callID: "c", confirm: { _ in
    Issue.record("this call should not ask")
    return false
})

private let applications = FakeApplicationWorkspace(
    installed: [
        InstalledApplication(name: "Preview", bundleIdentifier: "com.apple.Preview", url: URL(filePath: "/System/Applications/Preview.app", directoryHint: .isDirectory)),
        InstalledApplication(name: "Safari", bundleIdentifier: "com.apple.Safari", url: URL(filePath: "/Applications/Safari.app", directoryHint: .isDirectory)),
    ],
    running: [
        RunningApplication(name: "Safari", bundleIdentifier: "com.apple.Safari", url: URL(filePath: "/Applications/Safari.app")),
        RunningApplication(name: "zoom.us", bundleIdentifier: "us.zoom.xos", url: URL(filePath: "/Applications/zoom.us.app")),
        RunningApplication(name: "mac-os-agent", bundleIdentifier: "dev.lubelski.mac-os-agent", url: URL(filePath: "/Users/owner/Applications/mac-os-agent.app")),
    ])

@Suite struct OpenItemToolTests {
    private let report = FileInfo(path: "\(home)/Documents/report.pdf", contentType: "com.adobe.pdf")

    @Test func opensAWebAddressWithTheDefaultApp() async {
        let system = FakeSystemControl()
        let output = await OpenItemTool(system: system, applications: applications)
            .run(arguments: ["target": "https://example.com/a?b=c", "application": nil, "reveal_in_finder": nil], context: neverAsks)
        #expect(output == "Opened https://example.com/a?b=c with its default app.")
        #expect(system.opened.first?.0 == [URL(string: "https://example.com/a?b=c")!])
        #expect(system.opened.first?.1 == nil)
    }

    @Test func opensAFileWithANamedApp() async {
        let system = FakeSystemControl(files: [report])
        let tool = OpenItemTool(system: system, applications: applications)
        let output = await tool.run(arguments: ["target": .string(report.path), "application": "preview", "reveal_in_finder": false], context: neverAsks)
        #expect(output == "Opened \(report.path) with Preview.")
        #expect(system.opened.first?.1?.path == "/System/Applications/Preview.app")
    }

    @Test func revealsInFinder() async {
        let system = FakeSystemControl(files: [report])
        let output = await OpenItemTool(system: system, applications: applications)
            .run(arguments: ["target": .string(report.path), "application": nil, "reveal_in_finder": true], context: neverAsks)
        #expect(output == "Showed \(report.path) in Finder.")
        #expect(system.revealed.map(\.path) == [report.path])
        #expect(system.opened.isEmpty)
    }

    @Test func reportsMissingFilesAndApps() async {
        let system = FakeSystemControl(files: [report])
        let tool = OpenItemTool(system: system, applications: applications)
        let missing = await tool.run(arguments: ["target": "/nowhere/file.txt", "application": nil, "reveal_in_finder": nil], context: neverAsks)
        #expect(missing == "Error: there is nothing at /nowhere/file.txt. Use find_files to look for it.")
        let app = await tool.run(arguments: ["target": .string(report.path), "application": "xylophone", "reveal_in_finder": nil], context: neverAsks)
        #expect(app == "Error: no installed app matches \"xylophone\". Use search_applications to find it.")
        let web = await tool.run(arguments: ["target": "https://example.com", "application": nil, "reveal_in_finder": true], context: neverAsks)
        #expect(web == "Error: only a file or folder can be shown in Finder.")
        #expect(system.opened.isEmpty)
    }

    @Test func expandsTheHomeFolder() {
        #expect(SystemToolText.expandedPath("~/Pictures/", home: home) == "\(home)/Pictures")
        #expect(SystemToolText.expandedPath("~", home: home) == home)
        #expect(SystemToolText.expandedPath("/tmp/x", home: home) == "/tmp/x")
    }
}

@Suite struct FindFilesToolTests {
    private func arguments(
        name: String? = nil, content: String? = nil, kind: String? = nil, after: String? = nil, before: String? = nil,
        folder: String? = nil, limit: Int? = nil
    ) -> JSONValue {
        [
            "name": name.map { .string($0) } ?? .null, "content": content.map { .string($0) } ?? .null,
            "kind": kind.map { .string($0) } ?? .null, "modified_after": after.map { .string($0) } ?? .null,
            "modified_before": before.map { .string($0) } ?? .null, "folder": folder.map { .string($0) } ?? .null,
            "limit": limit.map { .number(Double($0)) } ?? .null,
        ]
    }

    private func tool(_ system: FakeSystemControl) -> FindFilesTool { FindFilesTool(system: system, dates: pacific, home: home) }

    @Test func buildsASpotlightQueryFromEveryFilter() async {
        let system = FakeSystemControl()
        _ = await tool(system).run(arguments: arguments(name: "budget\"*", content: "quarterly plan", kind: "spreadsheet", after: "2026-11-01", before: "2026-11-20"), context: neverAsks)
        #expect(system.queries.first?.0 == """
            kMDItemFSName == "*budget*"cd && kMDItemTextContent == "quarterly*"cdw && kMDItemTextContent == "plan*"cdw \
            && kMDItemContentTypeTree == "public.spreadsheet" && kMDItemContentModificationDate >= $time.iso(2026-11-01T07:00:00Z) \
            && kMDItemContentModificationDate < $time.iso(2026-11-21T08:00:00Z)
            """)
        #expect(system.queries.first?.1 == [home])
        #expect(FindFilesTool.query(name: nil, content: nil, types: FindFilesTool.kinds["document"], after: nil, before: nil)
            == "(kMDItemContentTypeTree == \"public.composite-content\" || kMDItemContentTypeTree == \"public.text\" || kMDItemContentTypeTree == \"com.adobe.pdf\")")
    }

    @Test func listsNewestFirstAndLeavesOutHiddenFilesAndLibrary() async {
        let system = FakeSystemControl()
        system.spotlightResults = [
            FileInfo(path: "\(home)/Documents/old.pdf", contentType: "com.adobe.pdf", modified: moment("2026-01-02T09:00"), size: 2_000_000),
            FileInfo(path: "\(home)/Documents/new.pdf", contentType: "com.adobe.pdf", modified: moment("2026-11-20T16:45"), size: 1500),
            FileInfo(path: "\(home)/Documents/Receipts", isFolder: true, modified: moment("2026-11-01T08:00")),
            FileInfo(path: "\(home)/.cache/hidden.pdf", contentType: "com.adobe.pdf", modified: moment("2026-11-21T09:00")),
            FileInfo(path: "\(home)/Library/Caches/x.pdf", contentType: "com.adobe.pdf", modified: moment("2026-11-21T09:00")),
        ]
        let output = await tool(system).run(arguments: arguments(name: "pdf"), context: neverAsks)
        let lines = output.split(separator: "\n").map(String.init)
        #expect(lines[0] == "3 matches in /Users/owner, newest first, as path | kind | modified | size:")
        #expect(lines[1].hasPrefix("/Users/owner/Documents/new.pdf | "))
        #expect(lines[1].hasSuffix(" | modified Fri 2026-11-20 16:45 | 2 KB"))
        #expect(lines[2] == "/Users/owner/Documents/Receipts | folder | modified Sun 2026-11-01 08:00")
        #expect(lines[3].hasPrefix("/Users/owner/Documents/old.pdf"))
        #expect(lines.count == 4)
    }

    @Test func searchesInsideAGivenFolderIncludingLibrary() async {
        let system = FakeSystemControl(files: [FileInfo(path: "\(home)/Library/Fonts", isFolder: true)])
        system.spotlightResults = [FileInfo(path: "\(home)/Library/Fonts/Inter.ttf", modified: moment("2026-11-01T08:00"))]
        let output = await tool(system).run(arguments: arguments(kind: "text", folder: "~/Library/Fonts"), context: neverAsks)
        #expect(system.queries.first?.1 == ["\(home)/Library/Fonts"])
        #expect(output.contains("Inter.ttf"))
    }

    @Test func refusesAnEmptySearchAndBadFolders() async {
        let system = FakeSystemControl(files: [FileInfo(path: "\(home)/notes.txt")])
        let tool = tool(system)
        #expect(await tool.run(arguments: arguments(), context: neverAsks) == "Error: give at least one of name, content, kind, modified_after, or modified_before.")
        #expect(await tool.run(arguments: arguments(name: "\"*"), context: neverAsks).hasPrefix("Error: give at least one"))
        #expect(await tool.run(arguments: arguments(name: "x", folder: "~/notes.txt"), context: neverAsks) == "Error: there is no folder at /Users/owner/notes.txt.")
        #expect(await tool.run(arguments: arguments(name: "x", after: "last week"), context: neverAsks).hasPrefix("Error: modified_after \"last week\""))
        #expect(system.queries.isEmpty)
        #expect(await tool.run(arguments: arguments(name: "x"), context: neverAsks) == "Nothing in /Users/owner matches.")
    }
}

@Suite struct ClipboardAndDesktopToolTests {
    @Test func readsTextFilesOrTypes() async {
        let system = FakeSystemControl()
        let read = ReadClipboardTool(system: system)
        #expect(await read.run(arguments: [:], context: neverAsks) == "The clipboard is empty.")
        system.clipboard = ClipboardContents(text: "hello", types: ["public.utf8-plain-text"])
        #expect(await read.run(arguments: [:], context: neverAsks) == "hello")
        system.clipboard = ClipboardContents(text: "a.pdf", filePaths: ["/Users/owner/a.pdf"], types: ["public.file-url"])
        #expect(await read.run(arguments: [:], context: neverAsks) == "The clipboard holds a file copied in Finder:\n/Users/owner/a.pdf")
        system.clipboard = ClipboardContents(types: ["public.png", "public.tiff"])
        #expect(await read.run(arguments: [:], context: neverAsks) == "The clipboard holds no text. The kinds of data on it are: public.png, public.tiff.")
    }

    @Test func writesText() async {
        let system = FakeSystemControl()
        let output = await WriteClipboardTool(system: system).run(arguments: ["text": "Meet at 3"], context: neverAsks)
        #expect(output == "Copied 9 characters to the clipboard.")
        #expect(system.clipboard.text == "Meet at 3")
        #expect(await WriteClipboardTool(system: system).run(arguments: ["text": ""], context: neverAsks).hasPrefix("Error:"))
    }

    @Test func setsTheDesktopPictureOnlyFromAnImage() async {
        let system = FakeSystemControl(files: [
            FileInfo(path: "\(home)/Pictures/sunset.jpg", contentType: "public.jpeg"),
            FileInfo(path: "\(home)/notes.txt", contentType: "public.plain-text"),
            FileInfo(path: "\(home)/Pictures", isFolder: true, contentType: "public.folder"),
        ])
        let tool = SetDesktopPictureTool(system: system)
        #expect(await tool.run(arguments: ["path": .string("\(home)/Pictures/sunset.jpg")], context: neverAsks)
            == "Set the desktop picture to /Users/owner/Pictures/sunset.jpg on 2 screens.")
        #expect(await tool.run(arguments: ["path": .string("\(home)/notes.txt")], context: neverAsks) == "Error: /Users/owner/notes.txt is not an image file.")
        #expect(await tool.run(arguments: ["path": .string("\(home)/Pictures")], context: neverAsks) == "Error: /Users/owner/Pictures is not an image file.")
        #expect(await tool.run(arguments: ["path": "/nowhere.png"], context: neverAsks).hasPrefix("Error: there is nothing at /nowhere.png."))
        #expect(system.desktopPictures.map(\.path) == ["\(home)/Pictures/sunset.jpg"])
    }
}

@Suite struct QuitOrHideApplicationToolTests {
    private func tool(_ system: FakeSystemControl) -> QuitOrHideApplicationTool {
        QuitOrHideApplicationTool(system: system, applications: applications, ownBundleIdentifier: "dev.lubelski.mac-os-agent")
    }

    @Test func hidingDoesNotAsk() async {
        let system = FakeSystemControl()
        let output = await tool(system).run(arguments: ["application": "safari", "action": "hide"], context: neverAsks)
        #expect(output == "Hid Safari (com.apple.Safari).")
        #expect(system.hiddenApps == ["Safari"])
    }

    @Test func quittingAsksFirst() async {
        let system = FakeSystemControl()
        let declined = GoAheadRecorder(answer: false)
        #expect(await tool(system).run(arguments: ["application": "us.zoom.xos", "action": "quit"], context: declined.context)
            == "The owner declined. zoom.us is still running.")
        #expect(declined.requests.map(\.kind) == [.quitApplication])
        #expect(declined.requests.map(\.body) == [.item(name: "zoom.us", detail: "us.zoom.xos")])
        #expect(declined.requests.first?.prompt == "Quit this app? It may ask you to save unsaved work first.")
        #expect(declined.requests.first?.approveTitle == "Quit")
        #expect(declined.requests.first?.declineTitle == "Don’t Quit")
        #expect(declined.requests.first?.waitingText == "waiting for your go-ahead to quit zoom.us")
        #expect(system.quitApps.isEmpty)

        let approved = GoAheadRecorder(answer: true)
        #expect(await tool(system).run(arguments: ["application": "Zoom.us", "action": "quit"], context: approved.context) == "Quit zoom.us (us.zoom.xos).")
        system.quitOutcome = .stillRunning
        #expect(await tool(system).run(arguments: ["application": "/Applications/Safari.app", "action": "quit"], context: approved.context)
            == "Asked Safari (com.apple.Safari) to quit. It is still running, perhaps asking the owner about unsaved work.")
        #expect(system.quitApps == ["zoom.us", "Safari"])
    }

    @Test func refusesUnknownAppsAndItself() async {
        let system = FakeSystemControl()
        #expect(await tool(system).run(arguments: ["application": "Notes", "action": "quit"], context: neverAsks)
            == "Error: no running app matches \"Notes\". Use list_running_applications to see what is running.")
        #expect(await tool(system).run(arguments: ["application": "mac-os-agent", "action": "quit"], context: neverAsks)
            == "Error: mac-os-agent does not quit itself. The owner can quit it from its menu bar menu.")
        #expect(system.quitApps.isEmpty)
    }
}

@Suite struct SystemToolShapeTests {
    @Test func theSystemToolsStayWithinTheirBudget() {
        let tools = BuiltInTools.make(
            applicationWorkspace: FakeApplicationWorkspace(installed: []), reminders: FakePersonalDataStore(),
            calendar: FakePersonalDataStore(), system: FakeSystemControl())
            .filter { $0.source == .system }
        let characters = tools.map { tool in
            JSONValue.object([
                "type": "function", "name": .string(tool.definition.name), "description": .string(tool.definition.description),
                "parameters": tool.definition.parameters, "strict": true,
            ]).encodedString().count
        }.reduce(0, +)
        #expect(tools.count == 6)
        #expect(characters < 4_200, "the system tools add \(characters) characters to every request")
    }
}
