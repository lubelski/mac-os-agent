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

    static func harness(paneStack: Bool) throws -> SettingsWindowHarness {
        try SettingsWindowHarness(
            section: .tools, additionalTools: mcpTools, privacyAccess: Access(),
            experiments: paneStack ? [.settingsPaneStack] : [])
    }
}

/// Settings, Tools, as a pane stack, checked on the window's model and key handling since
/// screen capture is not available.
@MainActor
@Suite(.serialized) struct ToolsPaneStackAppTests {
    private func escape() throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    }

    @Test func escapeClosesOnePaneAndWithOnlyTheGroupsMeansWhatItDidBefore() throws {
        // Without the experiment, the Tools section does not take Escape.
        let before = try ToolsSettingsStandIns.harness(paneStack: false)
        before.layOut()
        let escapeBefore = before.window.performKeyEquivalent(with: try escape())
        before.tearDown()
        #expect(!escapeBefore)

        let harness = try ToolsSettingsStandIns.harness(paneStack: true)
        defer { harness.tearDown() }
        let stack = harness.controller.models.tools.stack
        harness.layOut()
        #expect(harness.window.performKeyEquivalent(with: try escape()) == escapeBefore)
        #expect(stack.path.isAtBase)

        harness.controller.models.tools.showInStack("weather__add_alert")
        #expect(stack.path.entries == ["mcp:weather", "weather__add_alert"])
        harness.layOut()
        #expect(harness.window.performKeyEquivalent(with: try escape()))
        harness.layOut()
        #expect(stack.path.entries == ["mcp:weather"])
        #expect(harness.window.performKeyEquivalent(with: try escape()))
        harness.layOut()
        #expect(stack.path.isAtBase)
        #expect(harness.window.performKeyEquivalent(with: try escape()) == escapeBefore)
    }

    @Test func leavingToolsAndComingBackKeepsTheStack() throws {
        let harness = try ToolsSettingsStandIns.harness(paneStack: true)
        defer { harness.tearDown() }
        let tools = harness.controller.models.tools
        tools.showInStack("find_files")
        tools.stack.scrollOffsets["2|system/find_files"] = 180
        harness.layOut()
        harness.controller.models.navigation.section = .general
        harness.layOut()
        harness.controller.models.navigation.section = .tools
        harness.layOut()
        #expect(tools.stack.path.entries == ["system", "find_files"])
        #expect(tools.stack.scrollOffsets["2|system/find_files"] != nil)
    }

    @Test func aPathToSomethingGoneFallsBackWhenToolsShows() throws {
        let harness = try ToolsSettingsStandIns.harness(paneStack: true)
        defer { harness.tearDown() }
        let tools = harness.controller.models.tools
        tools.stack.path = PaneStackPath(["mcp:gone", "gone__tool"])
        harness.layOut()
        #expect(tools.stack.path.isAtBase)
    }

    @Test func theGoAheadSwitchStillWorks() throws {
        let harness = try ToolsSettingsStandIns.harness(paneStack: true)
        defer { harness.tearDown() }
        let tools = harness.controller.models.tools
        let group = try #require(tools.groups.fromMCPServers.first)
        // The weather server's add_alert is not read-only, so it asks by default.
        #expect(tools.asksForGoAhead(group))
        #expect(!tools.asksForGoAhead(try #require(tools.groups.first { $0.source == .memory })))
    }

    @Test func aPreviewItemOpensItsToolOrGroupAndIgnoresTheRest() throws {
        let harness = try ToolsSettingsStandIns.harness(paneStack: true)
        defer { harness.tearDown() }
        let tools = harness.controller.models.tools
        tools.showInStack(ToolSource.calendar.id)
        #expect(tools.stack.path.entries == ["calendar"])
        tools.showInStack("no_such_thing")
        #expect(tools.stack.path.entries == ["calendar"])
    }
}

/// Renders the pane stack offscreen, for a pull request: Tools in the real Settings window at
/// its minimum size, and a stand-in section seven levels deep in a narrow window, which shows
/// older strips giving way. Run with MAC_OS_AGENT_RENDER_SETTINGS set to a folder.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MAC_OS_AGENT_RENDER_SETTINGS"] != nil))
struct PaneStackRenders {
    private var out: URL {
        URL(filePath: ProcessInfo.processInfo.environment["MAC_OS_AGENT_RENDER_SETTINGS"]!, directoryHint: .isDirectory)
    }

    @Test func rendersADeepStackInANarrowPane() throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for dark in [true, false] {
            let state = PaneStackState(path: PaneStackPath(["Documents", "Projects", "Garden", "Plans", "2026", "Spring"]))
            let view = DeepStandIn(state: state).frame(width: 560, height: 480)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: view)
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let content = try #require(window.contentView)
            content.layoutSubtreeIfNeeded()
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: out.appending(path: "pane-stack-deep-narrow-\(dark ? "dark" : "light").png"))
            window.close()
        }
    }

    @Test func rendersAnMCPToolWithItsGoAheadSwitch() throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for dark in [true, false] {
            let harness = try ToolsSettingsStandIns.harness(paneStack: true)
            defer { harness.tearDown() }
            harness.controller.models.tools.showInStack("weather__add_alert")
            harness.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            harness.layOut()
            let frame = try #require(harness.window.contentView?.superview)
            frame.layoutSubtreeIfNeeded()
            let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
            frame.cacheDisplay(in: frame.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: out.appending(path: "pane-stack-mcp-tool-\(dark ? "dark" : "light").png"))
        }
    }

    /// A stand-in section of folders, any depth, built only from the stack's parts, as another
    /// section would adopt it.
    struct DeepStandIn: View {
        let state: PaneStackState

        var body: some View {
            PaneStackView(state: state) { strip in
                strip.isNearest ? 170 : 56
            } title: { level in
                level.item ?? "Home"
            } pane: { level in
                StackPane(title: Text(level.item ?? "Home").font(.headline), subtitle: "Level \(level.depth)") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(["Documents", "Projects", "Garden", "Plans", "2026", "Spring", "Notes"], id: \.self) { name in
                            PaneStackLink(id: name) {
                                HStack {
                                    Image(systemName: "folder")
                                    Text(name)
                                    Spacer()
                                    PaneChevron()
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                            }
                        }
                    }
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}
