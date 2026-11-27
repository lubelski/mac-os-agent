import Foundation
import Testing
@testable import MacOSAgentCore

/// These run the real helper, `mac-os-agent-script-runner`, which SwiftPM builds next to the
/// test bundle, against stand-in tools. Nothing here touches the owner's data.
@Suite struct RunScriptToolTests {
    /// `MAC_OS_AGENT_SCRIPT_RUNNER` runs these against another build of the helper, such as
    /// the signed and sandboxed one in `build/mac-os-agent.app`.
    static let helper: URL = {
        if let path = ProcessInfo.processInfo.environment["MAC_OS_AGENT_SCRIPT_RUNNER"] { return URL(filePath: path) }
        let bundle = Bundle.allBundles.first { $0.bundleURL.pathExtension == "xctest" }
        return (bundle?.bundleURL.deletingLastPathComponent() ?? URL(filePath: ".build/debug"))
            .appending(path: ScriptRunner.helperName)
    }()

    /// A tool that answers with a closure and records what it was called with.
    struct StandInTool: AgentTool {
        var name: String
        var calls = Calls()
        var answer: @Sendable (JSONValue, ToolRunContext) async -> String

        var definition: ToolDefinition {
            ToolDefinition(name: name, description: "A stand-in called \(name).", parameters: ["type": "object", "properties": [:]])
        }

        func summary(arguments: JSONValue) -> String { name }

        func run(arguments: JSONValue, context: ToolRunContext) async -> String {
            calls.add(arguments)
            return await answer(arguments, context)
        }
    }

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [JSONValue] = []
        func add(_ value: JSONValue) { lock.withLock { values.append(value) } }
        var all: [JSONValue] { lock.withLock { values } }
    }

    final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [ConfirmationRequest] = []
        func add(_ request: ConfirmationRequest) { lock.withLock { requests.append(request) } }
        var all: [ConfirmationRequest] { lock.withLock { requests } }
    }

    func run(
        _ code: String, tools: [any AgentTool] = [], answer: Bool = true, asked: Asked = Asked(),
        wait: Duration = .zero
    ) async -> String {
        let tool = RunScriptTool(tools: tools, helper: Self.helper)
        let context = ToolRunContext(callID: "call_script") { request in
            asked.add(request)
            if wait > .zero { try? await Task.sleep(for: wait) }
            return answer
        }
        return await tool.run(arguments: ["code": .string(code)], context: context)
    }

    @Test func helperIsBuilt() {
        #expect(FileManager.default.isExecutableFile(atPath: Self.helper.path))
    }

    @Test func outputAndReturnValueReachTheModel() async {
        let result = await run("text('first')\nconsole.log('second', {a: 1})\nreturn [1, 2]")
        let lines = result.split(separator: "\n").map(String.init)
        #expect(lines.first?.hasPrefix("Script completed in ") == true)
        #expect(Array(lines.dropFirst()) == ["first", "second {\"a\":1}", "[1,2]"])
    }

    @Test func aScriptWithNoOutputSaysSo() async {
        let result = await run("const x = 1")
        #expect(result.hasSuffix("\n(no output)"))
    }

    @Test func callsGoThroughTheToolWithTheirArguments() async {
        let calls = Calls()
        let tool = StandInTool(name: "read_events", calls: calls) { arguments, _ in
            "events for \(arguments["day"]?.stringValue ?? "?")"
        }
        let result = await run(
            "const a = await tools.read_events({day: 'Mon'})\nconst b = await tools.read_events({day: 'Tue'})\nreturn a + ' / ' + b",
            tools: [tool])
        #expect(calls.all == [["day": "Mon"], ["day": "Tue"]])
        #expect(result.hasSuffix("\nevents for Mon / events for Tue"))
    }

    @Test func aReadOnlyScriptAsksNothing() async {
        let asked = Asked()
        let tool = StandInTool(name: "read_clipboard") { _, _ in "clip" }
        _ = await run("return await tools.read_clipboard({})", tools: [tool], asked: asked)
        #expect(asked.all.isEmpty)
    }

    @Test func aCallThatAsksAsksWithTheScriptsCallAndADeclineRejects() async {
        let asked = Asked()
        let tool = StandInTool(name: "change_reminders") { _, context in
            let approved = await context.confirm(ConfirmationRequest(callID: context.callID, command: "x", reason: "deletes a reminder"))
            return approved ? "Deleted." : "The person declined. Nothing changed."
        }
        let result = await run(
            "try { await tools.change_reminders({}) } catch (error) { text('caught: ' + error.message) }",
            tools: [tool], answer: false, asked: asked)
        #expect(asked.all.map(\.callID) == ["call_script"])
        #expect(asked.all.map(\.prompt) == ["Run this command? It deletes a reminder. A script is asking."])
        #expect(result.hasSuffix("\ncaught: The person declined. Nothing changed."))
    }

    @Test func aToolErrorRejects() async {
        let tool = StandInTool(name: "weather__forecast") { _, _ in "Error: the server is not connected." }
        let result = await run("return await tools.weather__forecast({})", tools: [tool])
        #expect(result.contains("Script failed after "))
        #expect(result.contains("Script error: Error: the server is not connected."))
        #expect(result.hasSuffix("[The 1 tool call it made before ending were not undone.]"))
    }

    @Test func aHyphenInANameBecomesAnUnderscore() async {
        let tool = StandInTool(name: "my-server__look-up") { _, _ in "found" }
        let result = await run("return [await tools.my_server__look_up({}), await tools['my-server__look-up']({}), ALL_TOOLS[0].name]", tools: [tool])
        #expect(result.hasSuffix("\n[\"found\",\"found\",\"my_server__look_up\"]"))
    }

    @Test func anErrorGivesItsLineInTheScript() async {
        let result = await run("text('before')\nconst x = 2\nnull.foo")
        #expect(result.contains("\nbefore\n"))
        #expect(result.contains("Script error: TypeError: null is not an object (evaluating 'null.foo') (line 3)"))
    }

    @Test func aSyntaxErrorFails() async {
        let result = await run("let = = 1")
        #expect(result.contains("Script error: SyntaxError"))
    }

    @Test func theScriptHasNoWayOutButTools() async {
        let result = await run("return [typeof fetch, typeof setTimeout, typeof require, typeof process, typeof XMLHttpRequest, typeof __call].join(' ')")
        #expect(result.hasSuffix("\nundefined undefined undefined undefined undefined undefined"))
    }

    @Test func aCallItDidNotWaitForNeverRuns() async {
        let calls = Calls()
        let tool = StandInTool(name: "quit_or_hide_application", calls: calls) { _, _ in "Quit." }
        let result = await run("tools.quit_or_hide_application({})\nreturn 'done'", tools: [tool])
        #expect(result.hasSuffix("\ndone"))
        #expect(calls.all.isEmpty)
    }

    @Test func waitingOnNothingFailsAtOnce() async {
        let result = await run("await new Promise(() => {})")
        #expect(result.contains("can never finish"))
    }

    @Test func aScriptThatNeverEndsIsStoppedAtItsLimit() async {
        let started = ContinuousClock.now
        let result = await run("// @options: {\"timeout_ms\": 500}\nwhile (true) {}")
        #expect(result.hasPrefix("Script stopped at its 0.5 second limit."))
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    /// The wait is longer than the limit, so the script finishes only if the wait is left out.
    /// The limit still has to cover starting the helper and passing the call both ways, which
    /// can take most of a second while the other tests run in parallel, so it is not tight.
    @Test func timeWaitingForTheOwnerDoesNotCount() async {
        let tool = StandInTool(name: "change_events") { _, context in
            _ = await context.confirm(ConfirmationRequest(callID: context.callID, command: "x", reason: "deletes an event"))
            return "Done."
        }
        let result = await run(
            "// @options: {\"timeout_ms\": 2000}\nreturn await tools.change_events({})", tools: [tool], wait: .milliseconds(2500))
        #expect(result.hasPrefix("Script completed"))
        #expect(result.hasSuffix("\nDone."))
    }

    @Test func stoppingTheTaskEndsTheScript() async {
        let tool = RunScriptTool(tools: [], helper: Self.helper)
        let task = Task {
            await tool.run(arguments: ["code": "while (true) {}"], context: ToolRunContext(callID: "c") { _ in true })
        }
        try? await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let result = await task.value
        #expect(result.hasPrefix("The task was stopped while this script ran."))
    }

    @Test func optionsAreChecked() {
        #expect(RunScriptTool.timeout(in: "return 1") == .success(RunScriptTool.defaultTimeout))
        #expect(RunScriptTool.timeout(in: "// @options: {\"timeout_ms\": 120000}\nx") == .success(.seconds(120)))
        #expect(RunScriptTool.timeout(in: "// @options: {\"timeout_ms\": 9999999}") == .success(RunScriptTool.longestTimeout))
        #expect((try? RunScriptTool.timeout(in: "// @options: {\"max_output_tokens\": 5}").get()) == nil)
        #expect((try? RunScriptTool.timeout(in: "// @options: nope").get()) == nil)
    }

    @Test func aMissingHelperSaysSo() async {
        let tool = RunScriptTool(tools: [], helper: URL(filePath: "/nonexistent/runner"))
        let result = await tool.run(arguments: ["code": "return 1"], context: ToolRunContext(callID: "c") { _ in true })
        #expect(result == "Error: the script runner is missing from the app, so scripts cannot run.")
    }

    @Test func itsRowShowsTheFirstLineOfCode() {
        let tool = RunScriptTool(tools: [])
        #expect(tool.summary(arguments: ["code": "// @options: {\"timeout_ms\": 1}\n\nconst a = 1\nreturn a"]) == "Tools const a = 1")
    }

    // MARK: The tool list

    @Test func offTheListIsUnchanged() {
        let registry = ToolRegistry(builtIn: BuiltInTools.make())
        let names = registry.addingRunScript(false).definitions.map(\.name)
        #expect(names == BuiltInTools.names)
        #expect(registry.addingRunScript(false).definitions == registry.definitions)
    }

    @Test func onItGoesLastAndCanCallEveryOtherTool() {
        let mcp = StandInTool(name: "zebra__look_up") { _, _ in "" }
        let registry = ToolRegistry(builtIn: BuiltInTools.make(), additional: [mcp]).addingRunScript(true)
        let names = registry.definitions.map(\.name)
        #expect(names == BuiltInTools.names + ["zebra__look_up", RunScriptTool.name])
        let tool = registry.tools.last as? RunScriptTool
        #expect(tool?.tools.map(\.definition.name) == BuiltInTools.names + ["zebra__look_up"])
    }

    @Test func theIncognitoWindowHasNoScripts() {
        #expect(!BuiltInTools.makeIncognito().map(\.definition.name).contains(RunScriptTool.name))
    }

    @Test func theExperimentIsOffByDefault() {
        let defaults = UserDefaults(suiteName: "run-script-tests-\(UUID().uuidString)")!
        #expect(!Experiment.scripts.isOn(defaults))
    }
}
