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
