import Foundation
import Testing
@testable import MacOSAgentCore

@Suite struct ToolsNavigationTests {
    @Test func opensAGroupThenAToolAndGoesBackOneLevelAtATime() {
        var navigation = ToolsNavigation()
        #expect(navigation.level == .groups)
        navigation.openGroup("calendar")
        #expect(navigation.level == .tools)
        #expect(navigation.groupID == "calendar")
        navigation.openTool("read_events", in: "calendar")
        #expect(navigation.level == .details)
        #expect(navigation.toolID == "read_events")

        var wentBack = navigation.goBack()
        #expect(wentBack)
        #expect(navigation.level == .tools)
        #expect(navigation.groupID == "calendar")
        #expect(navigation.toolID == nil)
        wentBack = navigation.goBack()
        #expect(wentBack)
        #expect(navigation.level == .groups)
        #expect(navigation.groupID == nil)
        // Nothing is open, so going back does nothing and says so.
        wentBack = navigation.goBack()
        #expect(!wentBack)
        #expect(navigation == ToolsNavigation())
    }

    @Test func goingBackToALevelClosesEveryPaneAboveIt() {
        var navigation = ToolsNavigation()
        navigation.openTool("read_events", in: "calendar")
        navigation.goBack(to: .tools)
        #expect(navigation.level == .tools)
        #expect(navigation.groupID == "calendar")
        navigation.goBack(to: .tools)
        #expect(navigation.level == .tools)

        navigation.openTool("change_events", in: "calendar")
        navigation.goBack(to: .groups)
        #expect(navigation == ToolsNavigation())
        navigation.goBack(to: .details)
        #expect(navigation.level == .groups)
    }

    @Test func openingAnotherGroupClosesTheOpenTool() {
        var navigation = ToolsNavigation()
        navigation.openTool("read_events", in: "calendar")
        navigation.openGroup("reminders")
        #expect(navigation.level == .tools)
        #expect(navigation.groupID == "reminders")
        #expect(navigation.toolID == nil)
    }

    @Test func groupsSplitIntoBuiltInAndMCPAndFindTheirTools() {
        let store = FakePersonalDataStore()
        let registry = ToolRegistry(
            builtIn: BuiltInTools.make(
                applicationWorkspace: FakeApplicationWorkspace(installed: []), reminders: store, calendar: store,
                system: FakeSystemControl()),
            additional: [MCPTool(
                server: "weather", info: MCPToolInfo(name: "get_forecast", description: "The forecast.", inputSchema: ["type": "object"], readOnly: true),
                name: "weather__get_forecast", pool: .empty)])
        let groups = registry.groups
        #expect(groups.builtIn.map(\.source) == [.builtIn, .reminders, .calendar, .system, .appearance, .quickActions, .memory])
        #expect(groups.fromMCPServers.map(\.source.title) == ["weather"])
        #expect(groups.group(holding: "read_events")?.source == .calendar)
        #expect(groups.group(holding: "weather__get_forecast")?.source.isMCPServer == true)
        #expect(groups.group(holding: "no_such_tool") == nil)
    }

    @Test func aGroupSaysHowManyToolsItHasAndWhetherAnyAsks() throws {
        let store = FakePersonalDataStore()
        let groups = ToolRegistry(builtIn: BuiltInTools.make(
            applicationWorkspace: FakeApplicationWorkspace(installed: []), reminders: store, calendar: store,
            system: FakeSystemControl())).groups
        let builtIn = try #require(groups.first)
        #expect(builtIn.countLabel == "\(builtIn.tools.count) tools")
        // The shell tool asks for some commands.
        #expect(builtIn.asksForGoAhead())
        let memory = try #require(groups.first { $0.source == .memory })
        #expect(!memory.asksForGoAhead())
        // The caller's go-ahead wins, as an MCP tool's setting does.
        #expect(memory.asksForGoAhead { _ in .always })
        #expect(!builtIn.asksForGoAhead { _ in .never })

        var one = memory
        one.tools = Array(one.tools.prefix(1))
        #expect(one.countLabel == "1 tool")
    }

    @Test func everySourceHasASymbolAndASummary() {
        let sources: [ToolSource] = [
            .builtIn, .system, .reminders, .calendar, .memory, .quickActions, .appearance, .webSearch, .taskLinks,
        ]
        #expect(sources.allSatisfy { $0.symbolName != "wrench.and.screwdriver" && $0.summary != $0.title })
        #expect(Set(sources.map(\.symbolName)).count == sources.count)
        #expect(ToolSource.mcp("weather").summary == "Tools from the weather MCP server")
        #expect(ToolSource.mcp("weather").symbolName == "server.rack")
        #expect(ToolSource(id: "other", title: "Other").summary == "Other")
    }
}
