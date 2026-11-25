import AppKit
import MacOSAgentCore
import SwiftUI
import Testing
@testable import mac_os_agent

/// Stand-ins for Settings, Tools: two MCP tools from a placeholder server, and access that
/// never asks the owner for anything.
@MainActor
enum ToolsSettingsStandIns {
    static var mcpTools: [any AgentTool] {
        [
            MCPTool(
                server: "weather",
                info: MCPToolInfo(name: "get_forecast", description: "The forecast for a city for the next few days.", inputSchema: [
                    "type": "object", "properties": ["city": ["type": "string", "description": "A city name, such as Lisbon."]],
                    "required": ["city"],
                ], readOnly: true),
                name: "weather__get_forecast", pool: .empty),
            MCPTool(
                server: "weather",
                info: MCPToolInfo(name: "add_alert", description: "Adds an alert for severe weather in a city.", inputSchema: [
                    "type": "object", "properties": ["city": ["type": "string"]], "required": ["city"],
                ]),
                name: "weather__add_alert", pool: .empty),
        ]
    }

    struct Access: PrivacyAccessGate {
        func status(_ kind: PrivacyAccessKind) -> PrivacyAccessStatus { kind == .reminders ? .fullAccess : .notDetermined }
        func requestAccess(_ kind: PrivacyAccessKind) async -> PrivacyAccessStatus { status(kind) }
    }

    static func harness() throws -> SettingsWindowHarness {
        try SettingsWindowHarness(section: .tools, additionalTools: mcpTools, privacyAccess: Access())
    }
}

/// The panes of Settings, Tools, checked on the window's model and views since screen capture
/// is not available.
@MainActor
@Suite(.serialized) struct ToolsSettingsTests {
    private func escape() throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    }

    @Test func opensOnTheGroupsWithBuiltInFirstAndMCPAfter() throws {
        let harness = try ToolsSettingsStandIns.harness()
        defer { harness.tearDown() }
        let model = harness.controller.models.tools
        #expect(model.navigation.level == .groups)
        #expect(model.groups.first?.source == .builtIn)
        #expect(model.groups.fromMCPServers.map(\.source.title) == ["weather"])
        // The weather server's add_alert is not read-only, so it asks by default.
        let weather = try #require(model.groups.fromMCPServers.first)
        #expect(model.asksForGoAhead(weather))
        #expect(!model.asksForGoAhead(try #require(model.groups.first { $0.source == .memory })))
    }

    @Test func aPreviewItemOpensItsToolOrGroup() throws {
        let harness = try ToolsSettingsStandIns.harness()
        defer { harness.tearDown() }
        let model = harness.controller.models.tools
        model.show("weather__add_alert")
        #expect(model.navigation.level == .details)
        #expect(model.openGroup?.source.title == "weather")
        #expect(model.openTool?.name == "weather__add_alert")
        model.navigation.goBack(to: .groups)
        model.show(ToolSource.calendar.id)
        #expect(model.navigation.level == .tools)
        #expect(model.openTool == nil)
        model.show("no_such_thing")
        #expect(model.navigation.level == .tools)
    }

    @Test func escapeSlidesOnePaneAwayAndDoesNothingWithOnlyTheGroups() throws {
        let harness = try ToolsSettingsStandIns.harness()
        defer { harness.tearDown() }
        let model = harness.controller.models.tools
        harness.layOut()
        // With only the groups showing, the Tools section does not take Escape.
        #expect(!harness.window.performKeyEquivalent(with: try escape()))
        #expect(model.navigation.level == .groups)

        model.show("run_shell_command")
        harness.layOut()
        #expect(harness.window.performKeyEquivalent(with: try escape()))
        harness.layOut()
        #expect(model.navigation.level == .tools)
        #expect(model.openGroup?.source == .builtIn)
        #expect(harness.window.performKeyEquivalent(with: try escape()))
        harness.layOut()
        #expect(model.navigation.level == .groups)
        #expect(!harness.window.performKeyEquivalent(with: try escape()))
    }
}

/// Renders Settings, Tools, in each of its levels, offscreen, for a pull request when screen
/// capture is not available. Run with MAC_OS_AGENT_RENDER_SETTINGS set to a folder.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MAC_OS_AGENT_RENDER_SETTINGS"] != nil))
struct ToolsSettingsRenders {
    enum State: String, CaseIterable {
        case groups
        case group
        case tool
        case toolAtEnd = "tool-end"
        case narrowTool = "tool-narrow"
    }

    @Test(arguments: State.allCases)
    func rendersTheLevel(state: State) throws {
        let out = URL(filePath: ProcessInfo.processInfo.environment["MAC_OS_AGENT_RENDER_SETTINGS"]!, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for dark in [true, false] {
            let harness = try ToolsSettingsStandIns.harness()
            defer { harness.tearDown() }
            let model = harness.controller.models.tools
            switch state {
            case .groups: break
            case .group: model.show(ToolSource.system.id)
            case .tool, .narrowTool: model.show("find_files")
            case .toolAtEnd:
                model.show("find_files")
                model.detailsStartAtEnd = true
            }
            if state == .narrowTool {
                harness.window.setContentSize(SettingsWindowController.minimumSize)
            }
            harness.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            harness.layOut()
            let frame = try #require(harness.window.contentView?.superview)
            frame.layoutSubtreeIfNeeded()
            let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
            frame.cacheDisplay(in: frame.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: out.appending(path: "settings-tools-\(state.rawValue)-\(dark ? "dark" : "light").png"))
        }
    }
}
