import Foundation
import Testing
@testable import MacOSAgentCore

private func temporaryFolder() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "mac-os-agent-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

private struct GoAheadTool: AgentTool {
    var name = "ask_first"
    var source: ToolSource = .builtIn
    var definition: ToolDefinition {
        ToolDefinition(name: name, description: "Asks. Then acts.", parameters: ["type": "object"])
    }
    var goAhead: ToolGoAhead { .always }
    func summary(arguments: JSONValue) -> String { name }
    func run(arguments: JSONValue, context: ToolRunContext) async -> String { "" }
}

@Suite struct ToolCatalogTests {
    @Test func parametersComeInTheOrderSentWithTypesAndRequiredFlags() {
        let schema: JSONValue = [
            "type": "object",
            "properties": [
                "zeta": ["type": "string", "description": "Last by name."],
                "alpha": ["type": ["string", "null"]],
                "mode": ["type": "string", "enum": ["fast", "slow"]],
                "paths": ["type": "array", "items": ["type": "string"]],
            ],
            "required": ["zeta", "mode"],
        ]
        let parameters = ToolParameter.list(from: schema)
        #expect(parameters.map(\.name) == ["alpha", "mode", "paths", "zeta"])
        #expect(parameters.map(\.type) == ["string or null", "string", "array of string", "string"])
        #expect(parameters.map(\.isRequired) == [false, true, false, true])
        #expect(parameters[1].allowedValues == ["fast", "slow"])
        #expect(parameters[3].description == "Last by name.")
        #expect(ToolParameter.list(from: ["type": "object"]).isEmpty)
    }

    @Test func theBuiltInToolsAreGroupedBySourceInRegistryOrder() {
        let store = FakePersonalDataStore()
        let registry = ToolRegistry(builtIn: BuiltInTools.make(
            applicationWorkspace: FakeApplicationWorkspace(installed: []), reminders: store, calendar: store,
            system: FakeSystemControl()))
        let groups = registry.groups
        #expect(groups.map(\.source) == [.builtIn, .reminders, .calendar, .system, .appearance, .actions, .memory])
        #expect(groups.flatMap(\.tools).map(\.name) == BuiltInTools.names)
        #expect(groups[1].tools.map(\.name) == ["read_reminders", "change_reminders"])
        #expect(groups[2].tools.map(\.name) == ["read_events", "change_events"])
        #expect(groups[3].tools.map(\.name) == [
            "open_item", "find_files", "read_clipboard", "write_clipboard", "set_desktop_picture", "quit_or_hide_application",
        ])
        #expect(groups[4].tools.map(\.name) == ["read_themes", "change_theme"])
        #expect(groups[5].tools.map(\.name) == ["read_quick_actions", "change_quick_action"])
        #expect(groups[6].tools.map(\.name) == ["read_memory", "change_memory"])
        #expect(groups.map(\.source.privacyAccess) == [nil, .reminders, .calendars, nil, nil, nil, nil])
    }

    @Test func theSummaryKeepsTheDescriptionAsSentAndTheGoAhead() throws {
        let registry = ToolRegistry(builtIn: BuiltInTools.make(applicationWorkspace: FakeApplicationWorkspace(installed: [])))
        let shell = try #require(registry.groups[0].tools.first)
        #expect(shell.description == ShellCommandTool().definition.description)
        #expect(shell.parameters.map(\.name) == ["command", "destructive"])
        if case .sometimes = shell.goAhead {} else { Issue.record("The shell tool asks for some commands") }
        #expect(registry.groups[0].tools.dropFirst().allSatisfy { $0.goAhead == .never })
        // Every change to memory is journaled and can be restored, so it never asks.
        let changeTools = registry.groups.dropFirst().flatMap(\.tools).filter { $0.name.hasPrefix("change_") && $0.name != "change_memory" }
        #expect(changeTools.count == 4)
        #expect(registry.groups.flatMap(\.tools).first { $0.name == "change_memory" }?.goAhead == .never)
        #expect(changeTools.allSatisfy { if case .sometimes = $0.goAhead { true } else { false } })
        #expect(shell.schemaText.contains("\n"))
        #expect(JSONValue.parse(shell.schemaText) == ShellCommandTool().definition.parameters)
    }

    @Test func otherSourcesBecomeGroupsAfterTheBuiltIns() {
        let server = ToolSource(id: "mcp:calendar", title: "calendar")
        let registry = ToolRegistry(
            builtIn: [GoAheadTool()],
            additional: [GoAheadTool(name: "b_event", source: server), GoAheadTool(name: "a_event", source: server)])
        #expect(registry.groups.map(\.source) == [.builtIn, server])
        #expect(registry.groups[1].tools.map(\.name) == ["a_event", "b_event"])
        #expect(registry.groups[0].tools[0].goAhead == .always)
        #expect(registry.groups[0].tools[0].shortDescription == "Asks.")
    }
}

@Suite struct SkillContentsTests {
    private func library(_ root: URL) -> SkillLibrary {
        SkillLibrary(folder: root.appending(path: "skills", directoryHint: .isDirectory),
                     settingsFile: root.appending(path: "skill-settings.json"))
    }

    @Test func contentsGiveTheInstructionsAndTheOtherFiles() throws {
        let library = library(temporaryFolder())
        try library.create(name: "rename-photos", description: "Rename photos.")
        let folder = library.folder.appending(path: "rename-photos", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder.appending(path: "tests"), withIntermediateDirectories: true)
        try Data().write(to: folder.appending(path: "rename.sh"))
        try Data().write(to: folder.appending(path: "tests/sample.jpg"))
        try Data().write(to: folder.appending(path: ".hidden"))
        let skill = try #require(library.skills().first)
        let contents = library.contents(of: skill)
        #expect(contents.hasFile)
        #expect(contents.files == ["rename.sh", "tests/sample.jpg"])
        #expect(contents.instructions.hasPrefix("Write the steps for this skill here."))
        #expect(!contents.instructions.contains("name:"))
    }

    @Test func aBrokenSkillShowsItsWholeFileOrNothing() throws {
        let library = library(temporaryFolder())
        let broken = library.folder.appending(path: "notes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("Just notes.\n".utf8).write(to: broken.appending(path: "SKILL.md"))
        let empty = library.folder.appending(path: "empty", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let skills = library.skills()
        let notes = library.contents(of: try #require(skills.first { $0.folderName == "notes" }))
        #expect(notes.instructions == "Just notes.")
        let none = library.contents(of: try #require(skills.first { $0.folderName == "empty" }))
        #expect(!none.hasFile)
        #expect(none.instructions.isEmpty)
    }

    @Test func filteringMatchesNameFolderOrDescription() {
        let skill = Skill(
            folderName: "focus-mode", folderURL: URL(filePath: "/tmp/focus-mode"), name: "focus-mode",
            description: "Turn on Do Not Disturb.", isEnabled: true, problem: nil)
        #expect(skill.matches(""))
        #expect(skill.matches("  "))
        #expect(skill.matches("FOCUS"))
        #expect(skill.matches("disturb"))
        #expect(!skill.matches("wallpaper"))
    }
}

@Suite struct DiagnosticsTests {
    private let tools = [ToolDefinition(name: "t", description: "A tool.", parameters: ["type": "object"])]

    @Test func theFingerprintChangesWithTheInstructionsOrTools() {
        let a = PromptFingerprint.make(instructions: "Be brief.", tools: tools)
        #expect(a == PromptFingerprint.make(instructions: "Be brief.", tools: tools))
        #expect(a.count == 12)
        #expect(a != PromptFingerprint.make(instructions: "Be kind.", tools: tools))
        #expect(a != PromptFingerprint.make(instructions: "Be brief.", tools: []))
    }

    @Test func promptInfoFindsWhenTheLastFingerprintStarted() {
        let usage = TokenUsage(inputTokens: 10, cachedInputTokens: 0, outputTokens: 1)
        func record(_ minute: Double, _ prompt: String?) -> UsageRecord {
            UsageRecord(date: Date(timeIntervalSince1970: minute * 60), provider: "p", model: "m", usage: usage, prompt: prompt)
        }
        let current = PromptFingerprint.make(instructions: "x", tools: tools)
        let info = PromptInfo(
            instructions: "x", tools: tools,
            records: [record(1, "old"), record(2, current), record(3, nil), record(4, current)])
        #expect(info.characters == 1)
        #expect(info.lastSentFingerprint == current)
        #expect(info.unchangedSince == Date(timeIntervalSince1970: 120))
        #expect(!info.changedSinceLastRequest)
        let changed = PromptInfo(instructions: "y", tools: tools, records: [record(1, current)])
        #expect(changed.changedSinceLastRequest)
        #expect(!PromptInfo(instructions: "y", tools: tools, records: []).changedSinceLastRequest)
    }

    @Test func theLoopRecordsTheDurationAndFingerprint() async throws {
        let store = try ThreadStore(fileURL: temporaryThreadFile())
        let usage = TokenUsage(inputTokens: 50, cachedInputTokens: 0, outputTokens: 5)
        let provider = FakeProvider(replies: [[.item(assistant("done")), .usage(usage, provider: "test", model: "m")]])
        let log = UsageLog(fileURL: temporaryFolder().appending(path: "usage.jsonl"))
        let tool = RecordingTool()
        let logged = AgentLoop(
            provider: provider, thread: store, tools: [tool], instructions: { "Be brief." }, usageLog: log)
        try await logged.run("go", onEvent: { _ in }, confirm: { _ in true })
        let record = try #require(log.records().first)
        #expect(record.prompt == PromptFingerprint.make(instructions: "Be brief.", tools: [tool.definition]))
        #expect((record.seconds ?? -1) >= 0)
    }

    @Test func theThreadFileIsMeasuredWithoutReadingIt() throws {
        let file = temporaryThreadFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"a\":1}\n{\"b\":2}\n\n{\"c\":3}\n".utf8).write(to: file)
        let info = ThreadFileInfo.read(file)
        #expect(info.exists)
        #expect(info.entries == 3)
        #expect(info.bytes == 25)
        #expect(!ThreadFileInfo.read(temporaryThreadFile()).exists)
    }

    @Test func signingIsDescribedInWords() {
        #expect(BuildInfo.describeSigning(isSigned: false, isAdHoc: false, teamID: nil) == "Not signed")
        #expect(BuildInfo.describeSigning(isSigned: true, isAdHoc: true, teamID: nil).hasPrefix("Signed ad hoc"))
        #expect(BuildInfo.describeSigning(isSigned: true, isAdHoc: false, teamID: "ABCDE12345") == "Signed by team ABCDE12345")
    }

    @Test func theProblemLogKeepsTheNewestAndShortensLongMessages() {
        let log = ProblemLog()
        for index in 0..<(ProblemLog.limit + 5) { log.record("Request", "problem \(index)") }
        log.record("Sign-in", String(repeating: "x", count: 1000) + "\nsecond line")
        let problems = log.problems
        #expect(problems.count == ProblemLog.limit)
        #expect(problems[0].area == "Sign-in")
        #expect(problems[0].message.count == ProblemLog.messageLimit + 1)
        #expect(!problems[0].message.contains("\n"))
        #expect(problems[1].message == "problem \(ProblemLog.limit + 4)")
    }

    @Test func theSignInStatusHoldsNoToken() async throws {
        let secrets = MemorySecrets([
            ChatGPTAuthenticator.refreshTokenKey: "refresh-secret-123", ChatGPTAuthenticator.clientIDKey: "oaiapp_client_456",
        ])
        let now = Date(timeIntervalSince1970: 1_000_000)
        let transport = FakeTransport(body: [
            "access_token": "access-secret-789", "refresh_token": "refresh-secret-123", "expires_in": 3600,
            "scope": .string(ChatGPTSignIn.scope),
        ])
        let authenticator = ChatGPTAuthenticator(
            secrets: secrets, installationID: UUID(), transport: transport, now: { now })
        let before = await authenticator.status()
        #expect(before.isSignedIn)
        #expect(before.accessTokenExpires == nil)
        _ = try await authenticator.accessToken()
        let after = await authenticator.status()
        #expect(after.accessTokenExpires == now.addingTimeInterval(3600))
        #expect(after.lastTokenDate == now)
        #expect(after.lastError == nil)
        #expect(!"\(after)".contains("secret"))
        #expect(!"\(after)".contains("oaiapp"))
    }

    @Test func aFailedRefreshIsTheLastError() async {
        let secrets = MemorySecrets([ChatGPTAuthenticator.refreshTokenKey: "r", ChatGPTAuthenticator.clientIDKey: "c"])
        let authenticator = ChatGPTAuthenticator(
            secrets: secrets, installationID: UUID(), transport: FakeTransport(status: 400, body: ["error": "invalid_grant"]))
        _ = try? await authenticator.accessToken()
        let status = await authenticator.status()
        #expect(status.lastError?.contains("400") == true)
        #expect(status.lastErrorDate != nil)
    }

    @Test func theDiagnosticsTextHasNoMessagesOrSecrets() async throws {
        let root = temporaryFolder()
        let threadFile = root.appending(path: "thread.jsonl")
        let store = try ThreadStore(fileURL: threadFile)
        try await store.append(.userMessage(text: "my private message about taxes"))
        try await store.append(assistant("private reply about taxes"))
        let log = UsageLog(fileURL: root.appending(path: "usage.jsonl"))
        let now = Date()
        log.append(UsageRecord(
            date: now, provider: "openai", model: "gpt-6-luna",
            usage: TokenUsage(inputTokens: 4000, cachedInputTokens: 3000, outputTokens: 90, reasoningTokens: 12),
            seconds: 2.5, prompt: "abc123abc123"))

        let secrets = MemorySecrets([
            ChatGPTAuthenticator.refreshTokenKey: "refresh-secret-123", ChatGPTAuthenticator.clientIDKey: "oaiapp_client_456",
        ])
        let authenticator = ChatGPTAuthenticator(
            secrets: secrets, installationID: UUID(),
            transport: FakeTransport(body: [
                "access_token": "access-secret-789", "refresh_token": "refresh-secret-123", "expires_in": 3600,
                "scope": .string(ChatGPTSignIn.scope),
            ]))
        _ = try await authenticator.accessToken()
        let problems = ProblemLog()
        problems.record("Request", "OpenAI API error (500): server error")

        let report = DiagnosticsReport(
            date: now,
            build: BuildInfo(version: "0.1", build: "12", commit: "abc1234", signing: "Signed ad hoc"),
            dataFolder: root, model: "gpt-6-luna", signIn: await authenticator.status(),
            instructions: "Secret-free instructions.", tools: tools, skills: [],
            threadFile: threadFile, usageLog: log, problems: problems.problems)
        let text = report.plainText()

        #expect(report.thread.entries == 2)
        #expect(report.today.requests == 1)
        #expect(report.today.reasoning == 12)
        #expect(text.contains("2 entries"))
        #expect(text.contains("commit abc1234"))
        #expect(text.contains("4000 in, 75% cached, 90 out, 12 reasoning, 2.5 s, prompt abc123abc123"))
        #expect(text.contains("OpenAI API error (500)"))
        #expect(text.contains("Signed in: yes"))
        for secret in ["taxes", "private", "refresh-secret", "access-secret", "oaiapp_client", "Secret-free instructions"] {
            #expect(!text.contains(secret), "The diagnostics contain \(secret)")
        }
    }
}

@Suite struct FileSecretsTests {
    @Test func aFileKeepsWritesReadsAndDeletesAndOnlyTheOwnerCanReadIt() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "file-secrets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "secrets.json")
        let secrets = FileSecrets(fileURL: file)
        #expect(secrets.read("token") == nil)
        try secrets.write("one", for: "token")
        try secrets.write("two", for: "other")
        #expect(FileSecrets(fileURL: file).read("token") == "one")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        secrets.delete("token")
        #expect(secrets.read("token") == nil)
        #expect(secrets.read("other") == "two")
    }
}
