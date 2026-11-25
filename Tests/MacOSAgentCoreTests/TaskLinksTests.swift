import Foundation
import Testing
@testable import MacOSAgentCore

private func linksFile() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "mac-os-agent-task-links-\(UUID().uuidString)", directoryHint: .isDirectory)
        .appending(path: "task-links.json")
}

private func link(_ label: String, _ url: String) -> JSONValue {
    ["label": .string(label), "url": .string(url)]
}

private func list(_ links: [JSONValue]) -> JSONValue {
    ["links": .array(links)]
}

private func run(_ tool: SetLinksTool, _ arguments: JSONValue, episode: UUID? = nil) async -> String {
    await tool.run(arguments: arguments, context: ToolRunContext(callID: "c", episodeID: episode, confirm: { _ in true }))
}

@Suite struct TaskLinksValidationTests {
    @Test func labelsAreCleanedAndRepeatedURLsDropped() throws {
        let links = try TaskLinks.normalize(.array([
            link("  PR\t#12\n ", "https://example.com/pull/12"),
            link("Same again", "https://example.com/pull/12"),
            link("Mock", " http://example.com/mock "),
        ]))
        #expect(links == [
            TaskLink(label: "PR #12", url: "https://example.com/pull/12"),
            TaskLink(label: "Mock", url: "http://example.com/mock"),
        ])
    }

    @Test func anEmptyListIsValid() throws {
        #expect(try TaskLinks.normalize(.array([])) == [])
    }

    @Test(arguments: [
        ("not an array", JSONValue.string("https://example.com")),
        ("no url", JSONValue.array([["label": "A"]])),
        ("a number for a label", JSONValue.array([["label": 3, "url": "https://example.com"]])),
        ("an empty label", JSONValue.array([link("   ", "https://example.com")])),
        ("a long label", JSONValue.array([link(String(repeating: "a", count: 33), "https://example.com")])),
        ("ftp", JSONValue.array([link("A", "ftp://example.com/file")])),
        ("javascript", JSONValue.array([link("A", "javascript:alert(1)")])),
        ("a file", JSONValue.array([link("A", "file:///etc/hosts")])),
        ("relative", JSONValue.array([link("A", "/pull/12")])),
        ("no host", JSONValue.array([link("A", "https://")])),
        ("a space inside", JSONValue.array([link("A", "https://example.com/a b")])),
        ("a long url", JSONValue.array([link("A", "https://example.com/" + String(repeating: "a", count: 2048))])),
    ])
    func aBadListIsRefusedWithTheReason(_ case: String, _ value: JSONValue) {
        #expect(throws: TaskLinks.Problem.self, "\(`case`)") { try TaskLinks.normalize(value) }
    }

    @Test func theListIsCappedAtEight() throws {
        let eight = (1...8).map { link("L\($0)", "https://example.com/\($0)") }
        #expect(try TaskLinks.normalize(.array(eight)).count == 8)
        let nine = eight + [link("L9", "https://example.com/9")]
        #expect(throws: TaskLinks.Problem("links are limited to 8 items")) { try TaskLinks.normalize(.array(nine)) }
    }
}

@Suite struct SetLinksToolTests {
    @Test func eachCallReplacesTheWholeListAndAnEmptyOneClearsIt() async {
        let store = TaskLinkStore(fileURL: linksFile())
        let tool = SetLinksTool(store: store)
        let episode = UUID()

        let first = await run(tool, list([link("PR #12", "https://example.com/pull/12"), link("Spec", "https://example.com/spec")]), episode: episode)
        #expect(first == "Links: PR #12, Spec")
        #expect(store.links(inEpisode: episode).map(\.label) == ["PR #12", "Spec"])

        _ = await run(tool, list([link("TASK-123", "https://example.com/task/123")]), episode: episode)
        #expect(store.links(inEpisode: episode).map(\.label) == ["TASK-123"])

        #expect(await run(tool, list([]), episode: episode) == "No links set.")
        #expect(store.links(inEpisode: episode) == [])
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test func aRefusedListLeavesTheOldOne() async {
        let store = TaskLinkStore(fileURL: linksFile())
        let tool = SetLinksTool(store: store)
        _ = await run(tool, list([link("Spec", "https://example.com/spec")]))
        let refused = await run(tool, list([link("Bad", "ftp://example.com")]))
        #expect(refused.hasPrefix("Error: links must be http or https URLs"))
        #expect(store.links(inEpisode: nil).map(\.label) == ["Spec"])
    }

    @Test func turnedOffSinceLaunchItSetsNothing() async {
        let store = TaskLinkStore(fileURL: linksFile())
        let tool = SetLinksTool(store: store, isOn: { false })
        let result = await run(tool, list([link("Spec", "https://example.com/spec")]))
        #expect(result.hasPrefix("Error:"))
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test func itNeedsNoGoAheadAndShowsInItsOwnGroup() {
        let tool = SetLinksTool()
        #expect(tool.goAhead == .never)
        #expect(tool.source == .taskLinks)
        #expect(tool.definition.strict)
        let summary = ToolSummary(tool)
        #expect(summary.parameters.map(\.name) == ["links"])
        #expect(summary.parameters.first?.type == "array of object")
        #expect(tool.summary(arguments: list([link("A", "https://example.com")])) == "Set 1 task link")
        #expect(tool.summary(arguments: list([])) == "Clear the task links")
    }
}

@Suite struct TaskLinksPersistenceTests {
    @Test func theListBelongsToItsEpisode() throws {
        let file = linksFile()
        let episode = UUID()
        try TaskLinkStore(fileURL: file).set([TaskLink(label: "Spec", url: "https://example.com/spec")], episode: episode)
        // A relaunch reads the same file.
        let relaunched = TaskLinkStore(fileURL: file)
        #expect(relaunched.links(inEpisode: episode).map(\.label) == ["Spec"])
        #expect(relaunched.links(inEpisode: UUID()) == [])
    }

    @Test func linksSetInAnEpisodeComeBackAfterARelaunchUntilANewEpisode() async throws {
        let threadFile = temporaryThreadFile()
        let file = threadFile.deletingLastPathComponent().appending(path: "task-links.json")
        let store = try ThreadStore(fileURL: threadFile)
        let provider = FakeProvider(replies: [
            [.item(toolCall("a", name: SetLinksTool.name, arguments: list([link("PR #12", "https://example.com/pull/12")])))],
            [.item(assistant("Set."))],
            [.item(assistant("Fresh."))],
        ])
        let loop = AgentLoop(provider: provider, thread: store, tools: [SetLinksTool(store: TaskLinkStore(fileURL: file))], instructions: "x")
        try await loop.run("show the pr", onEvent: { _ in }, confirm: { _ in true })

        // The app quits and opens the thread again.
        let reopened = try ThreadStore(fileURL: threadFile)
        let episode = await reopened.currentEpisode?.id
        #expect(episode != nil)
        #expect(TaskLinkStore(fileURL: file).links(inEpisode: episode).map(\.label) == ["PR #12"])

        // A new episode starts with none.
        let next = AgentLoop(provider: provider, thread: reopened, tools: [SetLinksTool(store: TaskLinkStore(fileURL: file))], instructions: "x")
        try await next.run("something else", startsNewEpisode: true, onEvent: { _ in }, confirm: { _ in true })
        #expect(TaskLinkStore(fileURL: file).links(inEpisode: await reopened.currentEpisode?.id) == [])
    }
}

@Suite struct TaskLinksSwitchTests {
    @Test func withTheSwitchOffTheToolListIsAsBefore() {
        let names = BuiltInTools.make().map(\.definition.name)
        #expect(names == BuiltInTools.names)
        #expect(!names.contains(SetLinksTool.name))
        #expect(BuiltInTools.names(webSearch: false, taskLinks: false) == BuiltInTools.names)
        #expect(BuiltInTools.names(webSearch: true) == BuiltInTools.names + [SearchWebTool.name])
    }

    @Test func withTheSwitchOnItGoesLastAndNothingElseMoves() {
        let names = BuiltInTools.make(webSearch: SearchWebTool(key: nil), taskLinks: SetLinksTool()).map(\.definition.name)
        #expect(names == BuiltInTools.names + [SearchWebTool.name, SetLinksTool.name])
        #expect(BuiltInTools.make(taskLinks: SetLinksTool()).map(\.definition.name) == BuiltInTools.names + [SetLinksTool.name])
    }

    @Test func theInstructionsSayWhatTheRowIsForOnlyWithTheSwitchOn() {
        let folder = URL(filePath: "/tmp/skills")
        let off = AgentInstructions.assemble(editable: "Be brief.", skills: [], skillsFolder: folder)
        let explicitOff = AgentInstructions.assemble(editable: "Be brief.", skills: [], skillsFolder: folder, taskLinks: false)
        let on = AgentInstructions.assemble(editable: "Be brief.", skills: [], skillsFolder: folder, taskLinks: true)
        #expect(off == explicitOff)
        #expect(!off.contains(SetLinksTool.name))
        #expect(on.contains(AgentInstructions.taskLinksRule))
        // Stable while the switch is unchanged.
        #expect(on == AgentInstructions.assemble(editable: "Be brief.", skills: [], skillsFolder: folder, taskLinks: true))
        // Only the rule is added.
        #expect(on.replacingOccurrences(of: "\n" + AgentInstructions.taskLinksRule, with: "") == off)
    }

    @Test func theIncognitoWindowHasNoLinksAndWritesNone() async throws {
        #expect(!BuiltInTools.makeIncognito().map(\.definition.name).contains(SetLinksTool.name))
        #expect(!AgentInstructions.incognitoFixed.contains(SetLinksTool.name))
        let prompt = AgentPrompt(instructions: InstructionsStore(fileURL: linksFile().deletingLastPathComponent().appending(path: "instructions.md")), taskLinks: true)
        #expect(!prompt.currentIncognito().contains(SetLinksTool.name))

        // A call the model makes there anyway finds no such tool, and nothing is written.
        let file = linksFile()
        let provider = FakeProvider(replies: [
            [.item(toolCall("a", name: SetLinksTool.name, arguments: list([link("PR #12", "https://example.com/pull/12")])))],
            [.item(assistant("I cannot here."))],
        ])
        let loop = AgentLoop(provider: provider, thread: InMemoryThreadStore(), tools: BuiltInTools.makeIncognito(), instructions: "x")
        try await loop.run("show the pr", onEvent: { _ in }, confirm: { _ in true })
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
    }
}
