import Foundation
import Testing
@testable import MacOSAgentCore

/// The recipes in `docs/quick-action-recipes.md` are files the owner copies, so each one must
/// read as a quick action and fit its tools as the app checks a save.
@Suite struct QuickActionRecipeTests {
    private static let page = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "docs/quick-action-recipes.md")

    /// The text of each `json` block on the page.
    private static func recipes() throws -> [String] {
        let text = try String(contentsOf: page, encoding: .utf8)
        return text.components(separatedBy: "```json\n").dropFirst().compactMap { $0.components(separatedBy: "\n```").first }
    }

    private static let slack = InstalledApplication(
        name: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap",
        url: URL(filePath: "/Applications/Slack.app", directoryHint: .isDirectory))

    @Test func everyRecipeReadsAndFitsItsTools() throws {
        let recipes = try Self.recipes()
        #expect(!recipes.isEmpty)
        let tools = [OpenItemTool(system: FakeSystemControl(), applications: FakeApplicationWorkspace(installed: [Self.slack])).definition]
        for (index, text) in recipes.enumerated() {
            let action = try QuickAction.parse(text, id: "recipe-\(index + 1)")
            #expect(QuickActionValidation.problems(action, tools: tools).isEmpty, "recipe \(index + 1)")
        }
    }

    @Test func theSlackRecipeOpensTheChannelLinkInSlack() async throws {
        let text = try #require(try Self.recipes().first { $0.contains("slack://channel") })
        let action = try QuickAction.parse(text, id: "open-example-channel")
        let step = try #require(action.steps.first)
        #expect(action.steps.count == 1)
        #expect(step.tool == OpenItemTool.name)
        let system = FakeSystemControl()
        let tool = OpenItemTool(system: system, applications: FakeApplicationWorkspace(installed: [Self.slack]))
        let output = await tool.run(arguments: step.arguments, context: ToolRunContext(callID: "c", confirm: { _ in false }))
        #expect(output == "Opened slack://channel?team=T0123456789&id=C0123456789 with Slack.")
        #expect(system.opened.first?.0 == [URL(string: "slack://channel?team=T0123456789&id=C0123456789")!])
        #expect(system.opened.first?.1?.path == "/Applications/Slack.app")
    }
}
