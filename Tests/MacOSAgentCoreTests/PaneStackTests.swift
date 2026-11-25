import CoreGraphics
import Foundation
import Testing
@testable import MacOSAgentCore

@Suite struct PaneStackPathTests {
    @Test func opensAnyNumberOfLevelsAndGoesBackOneAtATime() {
        var path = PaneStackPath()
        #expect(path.isAtBase)
        for (index, id) in ["a", "b", "c", "d", "e", "f"].enumerated() {
            path.open(id)
            #expect(path.depth == index + 1)
            #expect(path.entry(at: path.depth) == id)
        }
        #expect(path.entries == ["a", "b", "c", "d", "e", "f"])
        #expect(path.opened(from: 0) == "a")
        #expect(path.opened(from: 5) == "f")
        #expect(path.opened(from: 6) == nil)
        #expect(path.entry(at: 0) == nil)

        var steps = 0
        while path.goBack() { steps += 1 }
        #expect(steps == 6)
        #expect(path.isAtBase)
        // Nothing is open, so going back does nothing and says so.
        let wentBack = path.goBack()
        #expect(!wentBack)
        #expect(path == PaneStackPath())
    }

    @Test func goingBackToADepthClosesEveryPaneAboveIt() {
        var path = PaneStackPath(["a", "b", "c", "d"])
        path.goBack(to: 2)
        #expect(path.entries == ["a", "b"])
        // A depth at or above the top changes nothing.
        path.goBack(to: 2)
        path.goBack(to: 7)
        #expect(path.entries == ["a", "b"])
        path.goBack(to: 0)
        #expect(path.isAtBase)
        path.goBack(to: -1)
        #expect(path.isAtBase)
    }

    @Test func openingFromACoveredPaneReplacesEverythingAboveIt() {
        var path = PaneStackPath(["system", "find_files"])
        path.open("calendar", from: 0)
        #expect(path.entries == ["calendar"])
        path.open("read_events")
        path.open("change_events", from: 1)
        #expect(path.entries == ["calendar", "change_events"])
    }

    @Test func aClickOnAStripOpensAnotherRowOrGoesBack() {
        var path = PaneStackPath(["system", "find_files"])
        // Anywhere on the base's strip that is not a row goes back to the base.
        path.clickStrip(at: 0, on: nil)
        #expect(path.isAtBase)

        path = PaneStackPath(["system", "find_files"])
        // The open group's own row is part of the strip, so it goes back to the base too.
        path.clickStrip(at: 0, on: "system")
        #expect(path.isAtBase)

        path = PaneStackPath(["system", "find_files"])
        // Another group's row opens that group instead.
        path.clickStrip(at: 0, on: "calendar")
        #expect(path.entries == ["calendar"])

        path = PaneStackPath(["system", "find_files"])
        // Another tool in the tools strip opens that tool instead.
        path.clickStrip(at: 1, on: "read_clipboard")
        #expect(path.entries == ["system", "read_clipboard"])
        path.clickStrip(at: 1, on: nil)
        #expect(path.entries == ["system"])
    }

    @Test func thePathDoesNotAssumeWhereItsBaseIs() {
        // A section's id could be the first entry if the sidebar became the base.
        var path = PaneStackPath(["tools", "system", "find_files"])
        #expect(path.prefix(1).entries == ["tools"])
        #expect(path.description == "tools/system/find_files")
        path.replace(with: ["skills"])
        #expect(path.entries == ["skills"])
    }
}

@Suite struct PaneStackLayoutTests {
    @Test func stripsKeepTheirWidthWhenTheTopPaneHasRoom() {
        let widths = PaneStackLayout.stripWidths(preferred: [56, 170], available: 700)
        #expect(widths == [56, 170])
        #expect(PaneStackLayout.leadingEdges(stripWidths: widths) == [0, 56, 226])
        #expect(PaneStackLayout.stripWidths(preferred: [], available: 100) == [])
        #expect(PaneStackLayout.topEdges(stripWidths: widths) == [0, 10, 20])
    }

    @Test func olderStripsCollapseFirst() {
        // 600 wide leaves 280 for strips. 56 + 170 + 170 = 396 is too much.
        let collapsed = PaneStackLayout.collapsedWidth
        let widths = PaneStackLayout.stripWidths(preferred: [56, 170, 170], available: 600)
        #expect(widths == [collapsed, collapsed, 170])
        #expect(widths.reduce(0, +) <= 600 - PaneStackLayout.minimumTopWidth)
    }

    @Test func sliversGoAwayOldestFirstAndTheNearestStripStaysLongest() {
        let collapsed = PaneStackLayout.collapsedWidth
        // Ten levels in 560 points: 240 for strips. 170 + 8 slivers is 362, too much.
        let preferred = [CGFloat](repeating: 56, count: 9) + [170]
        let widths = PaneStackLayout.stripWidths(preferred: preferred, available: 560)
        #expect(widths.last == 170)
        #expect(widths.reduce(0, +) <= 240)
        // The ones that stay are the newest.
        let kept = widths.dropLast().enumerated().filter { $0.element > 0 }.map(\.offset)
        #expect(kept == Array((9 - kept.count)..<9))
        #expect(widths.dropLast().allSatisfy { $0 == 0 || $0 == collapsed })

        // When even the nearest strip alone is too wide, it shrinks to what is left.
        let tight = PaneStackLayout.stripWidths(preferred: [200, 200], available: 400)
        #expect(tight == [0, 80])
        #expect(PaneStackLayout.stripWidths(preferred: [200], available: 100) == [0])

        // Panes over a strip that went away sit on it, without dropping further.
        #expect(PaneStackLayout.topEdges(stripWidths: [0, 0, 24, 170]) == [0, 0, 0, 10, 20])
    }
}

@Suite struct ToolsPaneStackTests {
    private func registry() -> ToolRegistry {
        let store = FakePersonalDataStore()
        return ToolRegistry(
            builtIn: BuiltInTools.make(
                applicationWorkspace: FakeApplicationWorkspace(installed: []), reminders: store, calendar: store,
                system: FakeSystemControl()),
            additional: [MCPTool(
                server: "weather", info: MCPToolInfo(name: "get_forecast", description: "The forecast.", inputSchema: ["type": "object"], readOnly: true),
                name: "weather__get_forecast", pool: .empty)])
    }

    @Test func eachDepthOfThePathIsGroupsAGroupOrATool() throws {
        let groups = registry().groups
        let calendar = try #require(groups.first { $0.source == .calendar })
        let readEvents = try #require(calendar.tools.first { $0.name == "read_events" })
        let path = PaneStackPath([calendar.id, "read_events"])
        #expect(groups.pane(at: 0, of: path) == .groups)
        #expect(groups.pane(at: 1, of: path) == .group(calendar))
        #expect(groups.pane(at: 2, of: path) == .tool(readEvents, in: calendar))
        #expect(groups.pane(at: 3, of: path) == nil)
        #expect(groups.pane(at: 2, of: PaneStackPath([calendar.id])) == nil)
        // A tool that is not in the open group is not shown.
        #expect(groups.pane(at: 2, of: PaneStackPath([calendar.id, "find_files"])) == nil)
        #expect(groups.pane(at: 1, of: path)?.title == "Calendar")
        #expect(groups.pane(at: 0, of: path)?.title == "all tool groups")
    }

    @Test func aPathThatNamesWhatIsGoneFallsBackToWhatIsThere() {
        let groups = registry().groups
        #expect(groups.validPrefix(of: PaneStackPath(["mcp:gone", "x"])) == PaneStackPath())
        #expect(groups.validPrefix(of: PaneStackPath(["calendar", "gone"])) == PaneStackPath(["calendar"]))
        #expect(groups.validPrefix(of: PaneStackPath(["calendar", "read_events", "more"])) == PaneStackPath(["calendar", "read_events"]))
    }

    @Test func anItemOpensItsToolOrGroup() {
        let groups = registry().groups
        #expect(groups.path(showing: "weather__get_forecast") == PaneStackPath(["mcp:weather", "weather__get_forecast"]))
        #expect(groups.path(showing: "system") == PaneStackPath(["system"]))
        #expect(groups.path(showing: "no_such_thing") == nil)
    }

    @Test func groupsSplitIntoBuiltInAndMCPAndFindTheirTools() {
        let groups = registry().groups
        #expect(groups.builtIn.map(\.source) == [.builtIn, .reminders, .calendar, .system, .appearance, .quickActions, .memory])
        #expect(groups.fromMCPServers.map(\.source.title) == ["weather"])
        #expect(groups.group(holding: "read_events")?.source == .calendar)
        #expect(groups.group(holding: "no_such_tool") == nil)
    }

    @Test func aGroupSaysHowManyToolsItHasAndWhetherAnyAsks() throws {
        let groups = registry().groups
        let builtIn = try #require(groups.first)
        #expect(builtIn.countLabel == "\(builtIn.tools.count) tools")
        // The shell tool asks for some commands.
        #expect(builtIn.asksForGoAhead())
        let memory = try #require(groups.first { $0.source == .memory })
        #expect(!memory.asksForGoAhead())
        // The caller's go-ahead wins, as an MCP tool's setting does.
        #expect(memory.asksForGoAhead { _ in .always })
        var one = memory
        one.tools = Array(one.tools.prefix(1))
        #expect(one.countLabel == "1 tool")
    }

    @Test func everySourceHasASymbolAndASummary() {
        let sources: [ToolSource] = [
            .builtIn, .system, .reminders, .calendar, .memory, .quickActions, .appearance, .webSearch, .taskLinks,
            .onDemand, RunScriptTool.scripts,
        ]
        #expect(sources.allSatisfy { $0.symbolName != "wrench.and.screwdriver" && $0.summary != $0.title })
        #expect(Set(sources.map(\.symbolName)).count == sources.count)
        #expect(ToolSource.mcp("weather").summary == "Tools from the weather MCP server")
        #expect(ToolSource(id: "group:settings", title: "Settings Group").symbolName == "square.stack.3d.up")
        #expect(ToolSource(id: "other", title: "Other").summary == "Other")
    }
}
