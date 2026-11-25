import Foundation
import MacOSAgentCore
import Testing
@testable import mac_os_agent

/// Web search in the app target: the incognito window never gets it, and Settings never shows
/// the Brave key back.
@MainActor
@Suite struct WebSearchAppTests {
    @Test func theIncognitoLoopHasNoWebSearchWhateverTheSetting() {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "mac-os-agent-web-search-app-\(UUID().uuidString)", directoryHint: .isDirectory)
        let prompt = AgentPrompt(
            instructions: InstructionsStore(fileURL: folder.appending(path: "instructions.md")),
            skills: SkillLibrary(folder: folder.appending(path: "skills"), settingsFile: folder.appending(path: "skill-settings.json")))
        let loop = IncognitoWindowController.makeLoop(provider: StandInProvider(), prompt: prompt, usageLog: nil)
        #expect(!loop.webSearch)
        #expect(loop.tools.map(\.definition.name) == BuiltInTools.incognitoNames)
    }

    @Test func settingsSavesAndRemovesTheKeyWithoutReadingItBack() throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "mac-os-agent-web-search-app-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "secrets.json")
        let key = BraveSearchKey(secrets: FileSecrets(fileURL: file))
        let model = WebSearchSettingsModel(context: WebSearchContext(launched: .off, key: key))
        #expect(!model.keySaved)
        model.draft = "  secret-key  "
        model.saveKey()
        #expect(model.keySaved)
        #expect(model.draft.isEmpty)
        #expect(key.read() == "secret-key")
        model.removeKey()
        #expect(!model.keySaved)
        #expect(key.read() == nil)
    }

    @Test func debuggingSaysWhetherAKeyIsSetAndNeverTheKey() throws {
        let defaults = try #require(UserDefaults(suiteName: "web-search-app-\(UUID().uuidString)"))
        WebSearchSetting.set(.openAI, defaults)
        let secrets = FileSecrets(fileURL: FileManager.default.temporaryDirectory
            .appending(path: "mac-os-agent-web-search-app-\(UUID().uuidString)/secrets.json"))
        let key = BraveSearchKey(secrets: secrets)
        try key.save("never-shown")
        let status = WebSearchContext(launched: .brave, key: key).status(defaults)
        #expect(status.text == "Brave, key set, OpenAI from the next launch")
        #expect(!status.text.contains("never-shown"))
    }
}

private struct StandInProvider: ModelProvider {
    func streamReply(to request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
