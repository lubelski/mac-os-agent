import Foundation
import MacOSAgentCore
import Testing
@testable import mac_os_agent

/// The MCP Servers section is in the sidebar only with the MCP servers experiment on.
@MainActor
@Suite struct MCPServersSectionTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "mac-os-agent-mcp-section-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func offHidesTheSection() throws {
        try withDefaults { defaults in
            let navigation = SettingsNavigation(defaults: defaults)
            #expect(!navigation.sections.contains(.mcpServers))
            #expect(navigation.sections == SettingsSection.allCases.filter { $0 != .mcpServers })
        }
    }

    @Test func onShowsItAfterTools() throws {
        try withDefaults { defaults in
            Experiment.mcpServers.set(true, defaults)
            let sections = SettingsNavigation(defaults: defaults).sections
            let tools = try #require(sections.firstIndex(of: .tools))
            #expect(sections[tools + 1] == .mcpServers)
            #expect(sections == SettingsSection.allCases)
        }
    }

    @Test func aRememberedSectionThatIsHiddenFallsBack() throws {
        try withDefaults { defaults in
            defaults.set(SettingsSection.mcpServers.rawValue, forKey: SettingsNavigation.key)
            #expect(SettingsNavigation(defaults: defaults).section == .general)
            #expect(defaults.string(forKey: SettingsNavigation.key) == SettingsSection.mcpServers.rawValue, "the fallback writes nothing")
            Experiment.mcpServers.set(true, defaults)
            #expect(SettingsNavigation(defaults: defaults).section == .mcpServers)
        }
    }

    @Test func turningItOffWhileShowingTheSectionLandsOnExperiments() throws {
        try withDefaults { defaults in
            Experiment.mcpServers.set(true, defaults)
            let navigation = SettingsNavigation(defaults: defaults)
            navigation.section = .mcpServers
            navigation.mcpServersExperimentChanged(false)
            #expect(navigation.section == .experiments)
            #expect(!navigation.sections.contains(.mcpServers))
            navigation.mcpServersExperimentChanged(true)
            #expect(navigation.sections.contains(.mcpServers))
            navigation.section = .tools
            navigation.mcpServersExperimentChanged(false)
            #expect(navigation.section == .tools, "another section stays")
        }
    }

    @Test func aPreviewThatAsksForMCPShowsItWithoutThePreference() throws {
        try withDefaults { defaults in
            let navigation = SettingsNavigation(defaults: defaults, mcpServersOverride: true)
            #expect(navigation.sections.contains(.mcpServers))
            navigation.mcpServersExperimentChanged(false)
            #expect(navigation.sections.contains(.mcpServers))
            #expect(defaults.object(forKey: Experiment.mcpServers.key) == nil, "nothing is written")
        }
    }
}

/// A server's detail has a fixed header over two tabs, Details and Tools.
@MainActor
@Suite struct MCPServerDetailTabTests {
    @Test func detailsComesFirst() {
        let model = MCPServersSettingsModel(pool: .empty, file: URL(filePath: "/dev/null"))
        #expect(model.detailTab == .details)
        #expect(MCPServerDetailTab.allCases == [.details, .tools])
    }

    @Test func theChosenTabStaysWhenAnotherServerIsSelected() {
        let model = MCPServersSettingsModel(pool: .empty, file: URL(filePath: "/dev/null"))
        model.selection = "weather"
        model.detailTab = .tools
        model.selection = "files"
        #expect(model.detailTab == .tools)
    }

    @Test func theToolsTabCarriesItsCountOnceAnyAreKnown() {
        #expect(MCPServerDetailTab.tools.title(toolCount: 0) == "Tools")
        #expect(MCPServerDetailTab.tools.title(toolCount: 78) == "Tools (78)")
        #expect(MCPServerDetailTab.details.title(toolCount: 78) == "Details")
    }

    @Test func aPreviewItemNamesAServerAndATab() {
        let model = MCPServersSettingsModel(pool: .empty, file: URL(filePath: "/dev/null"))
        model.showPreviewItem("example.tools")
        #expect(model.selection == "example")
        #expect(model.detailTab == .tools)
        model.showPreviewItem("weather")
        #expect(model.selection == "weather")
        #expect(model.detailTab == .tools, "a server alone leaves the tab as it is")
        model.showPreviewItem("notes.unknown")
        #expect(model.selection == "notes")
        #expect(model.detailTab == .tools)
        model.showPreviewItem("notes.details")
        #expect(model.detailTab == .details)
        model.showPreviewItem("example.tools.narrow")
        #expect(model.selection == "example")
        #expect(model.detailTab == .tools)
    }
}

/// Display names and a tool's pane in MCP Servers. The names are Settings' own: the rows keep
/// the literal names the model sees beside them.
@MainActor
@Suite struct MCPServerDisplayNameTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "mac-os-agent-mcp-names-app-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func pool(settings file: URL) -> MCPServerPool {
        MCPServerPool(
            config: MCPServerConfig(servers: [MCPServerEntry(name: "weather", command: "/usr/bin/true")]),
            settings: MCPSettingsStore(file: file),
            cache: MCPToolCache(servers: ["weather": .init(tools: [
                MCPToolInfo(name: "get_forecast", description: "The forecast.", inputSchema: ["type": "object"], readOnly: true),
                MCPToolInfo(name: "add alert", description: "Adds an alert.", inputSchema: ["type": "object"]),
            ])]),
            cacheFile: nil, factory: { _ in UnusedConnection() })
    }

    private struct UnusedConnection: MCPServerConnection {
        func connect() async throws { throw MCPConnectionError.notConnected }
        func listTools() async throws -> [MCPToolInfo] { [] }
        func callTool(name: String, arguments: JSONValue) async throws -> MCPCallResult { throw MCPConnectionError.notConnected }
        func stop() async {}
    }

    @Test func namesDefaultAndOverridesShowAtOnce() throws {
        let url = try folder()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = MCPServersSettingsModel(pool: pool(settings: url.appending(path: "mcp-settings.json")), file: URL(filePath: "/dev/null"))
        #expect(model.displayName(of: "weather") == "Weather")
        model.setDisplayName("Forecasts", of: "weather")
        #expect(model.displayName(of: "weather") == "Forecasts")
        #expect(model.displayNameOverride(of: "weather") == "Forecasts")
        model.setDisplayName("", of: "weather")
        #expect(model.displayNameOverride(of: "weather") == nil)
        #expect(model.errorMessage == nil)
    }

    @Test func aToolKeepsTheNameTheModelCallsBesideItsDisplayName() async throws {
        let url = try folder()
        defer { try? FileManager.default.removeItem(at: url) }
        let pool = pool(settings: url.appending(path: "mcp-settings.json"))
        await pool.setActive(true)
        let model = MCPServersSettingsModel(pool: pool, file: URL(filePath: "/dev/null"))
        let status = try #require(await pool.statuses().first)
        let tools = model.toolSummaries(status)
        #expect(tools.map(\.name).first == "weather__get_forecast")
        // A name the model cannot take is changed for it, and the row shows the changed one.
        #expect(tools.map(\.name).last?.hasPrefix("weather__add_alert_") == true)
        let forecast = try #require(tools.first?.mcp)
        #expect(model.displayName(of: forecast) == "Get Forecast")
        model.setDisplayName("Five Days", of: forecast)
        #expect(model.displayName(of: forecast) == "Five Days")
        #expect(model.toolSummaries(status).first?.name == "weather__get_forecast")
    }

    @Test func settingsToolsShowsAnMCPToolsDisplayNamesAndABuiltInToolsOwnName() throws {
        let url = try folder()
        defer { try? FileManager.default.removeItem(at: url) }
        let pool = pool(settings: url.appending(path: "mcp-settings.json"))
        let registry = ToolRegistry(builtIn: [ShellCommandTool()], additional: pool.makeTools())
        let model = ToolsSettingsModel(registry: registry, access: NoAccess(), mcpSettings: pool.settings)
        let weather = try #require(model.groups.first { $0.source.isMCPServer })
        let forecast = try #require(weather.tools.first { $0.name == "weather__get_forecast" })
        let shell = try #require(model.groups.first?.tools.first)
        #expect(model.title(of: weather) == "Weather")
        #expect(model.displayName(of: forecast) == "Get Forecast")
        #expect(model.displayName(of: shell) == nil)
        #expect(model.title(of: model.groups[0]) == model.groups[0].source.title)
        // A rename in MCP Servers shows here at once.
        let before = model.namesRevision
        try pool.settings.setServerDisplayName("Forecasts", server: "weather")
        try pool.settings.setToolDisplayName("Five Days", server: "weather", tool: "get_forecast")
        #expect(model.namesRevision == before + 2)
        #expect(model.title(of: weather) == "Forecasts")
        #expect(model.displayName(of: forecast) == "Five Days")
        // The name the model calls is unchanged, so the row can show it under the display name.
        #expect(forecast.name == "weather__get_forecast")
    }

    private struct NoAccess: PrivacyAccessGate {
        func status(_ kind: PrivacyAccessKind) -> PrivacyAccessStatus { .notDetermined }
        func requestAccess(_ kind: PrivacyAccessKind) async -> PrivacyAccessStatus { .notDetermined }
    }

    @Test func aToolsPaneClosesWithAnotherServerOrTab() {
        let model = MCPServersSettingsModel(pool: .empty, file: URL(filePath: "/dev/null"))
        model.showPreviewItem("weather.tool-get_forecast")
        #expect(model.selection == "weather")
        #expect(model.detailTab == .tools)
        #expect(model.toolStack.path == PaneStackPath(["weather__get_forecast"]))
        model.selection = "weather"
        #expect(model.toolStack.path.depth == 1, "choosing the same server keeps it")
        model.detailTab = .details
        #expect(model.toolStack.path.isAtBase)
        model.showPreviewItem("weather.tool-get_forecast")
        model.selection = "files"
        #expect(model.toolStack.path.isAtBase)
    }
}
