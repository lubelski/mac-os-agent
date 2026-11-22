import AppKit
import MacOSAgentCore
import SwiftUI
import Testing
@testable import mac_os_agent

/// The inspector driven through the real panel with stand-in screens and a defaults suite of
/// its own. Nothing is put on screen, so nothing takes focus. What only shows on screen, such
/// as the window moving with the panel during a drag, is for the owner to check.
@MainActor
@Suite(.serialized) struct ToolInspectorTests {
    init() { _ = NSApplication.shared }

    private let suiteName = "mac-os-agent-inspector-tests-\(UUID().uuidString)"
    private let standIn = StandInScreens()
    private var laptop: CGRect { StandInScreens.laptop.visible }

    private func makePanel() throws -> (SummonPanel, UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let session = try #require(PanelPreview.session(named: "inspector-json"))
        let standIn = standIn
        let panel = SummonPanel(
            session: session, remembersFrame: false, placementDefaults: defaults,
            screens: { standIn.screens }, mouseLocation: { standIn.mouse })
        panel.setFrame(CGRect(x: 300, y: 200, width: 640, height: 560), display: false)
        return (panel, defaults)
    }

    @Test func openingACallPlacesTheInspectorBesideThePanel() throws {
        let (panel, defaults) = try makePanel()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        panel.inspector.open("call_json")
        panel.placeInspector()
        let frame = panel.inspectorWindow.frame
        #expect(frame.minX == panel.frame.maxX + PanelGeometry.inspectorGap)
        #expect(frame.minY == panel.frame.minY)
        #expect(frame.height == panel.frame.height)
        #expect(frame.width == ToolInspectorWindow.defaultWidth)
        #expect(panel.inspector.side == .right)
        // The panel is not on screen, so the inspector is not either.
        #expect(!panel.inspectorWindow.isVisible)
    }

    @Test func selectingAnotherCallReusesTheOneInspector() throws {
        let (panel, defaults) = try makePanel()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let window = panel.inspectorWindow
        panel.inspector.open("call_json")
        panel.inspector.open("call_table")
        #expect(panel.inspector.selectedCallID == "call_table")
        #expect(panel.inspectorWindow === window)
    }

    @Test func upAndDownMoveBetweenCallsAndStopAtTheEnds() throws {
        let (panel, defaults) = try makePanel()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(!panel.inspector.move(by: 1), "a closed inspector leaves the arrows alone")
        panel.inspector.open("call_json")
        #expect(panel.inspector.move(by: 1))
        #expect(panel.inspector.selectedCallID == "call_table")
        #expect(panel.inspector.move(by: -1))
        #expect(panel.inspector.move(by: -1))
        // The earlier episodes' calls come before, so moving up reaches them.
        #expect(panel.inspector.selectedCallID == "call_3")
        panel.inspector.open("call_running")
        #expect(!panel.inspector.move(by: 1))
        #expect(panel.inspector.selectedCallID == "call_running")
    }

    @Test func escapeClosesTheInspectorBeforeItHidesThePanel() throws {
        let (panel, defaults) = try makePanel()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        panel.inspector.open("call_json")
        panel.escape()
        #expect(!panel.inspector.isOpen)
        // Escape in the inspector's own window closes it too.
        panel.inspector.open("call_diff")
        panel.inspectorWindow.cancelOperation(nil)
        #expect(!panel.inspector.isOpen)
    }

    @Test func eachPresetPutsTheInspectorOnTheInwardSide() throws {
        let (panel, defaults) = try makePanel()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        panel.inspector.open("call_json")
        panel.choose(.slideOverRight)
        #expect(panel.inspector.side == .left)
        #expect(panel.inspectorWindow.frame.maxX == panel.panelFrame.minX - PanelGeometry.inspectorGap)
        #expect(panel.inspectorWindow.frame.height == panel.panelFrame.height)
        #expect(panel.inspectorWindow.frame.minY == panel.panelFrame.minY)
        panel.choose(.slideOverLeft)
        #expect(panel.inspector.side == .right)
        #expect(panel.inspectorWindow.frame.minX == panel.panelFrame.maxX + PanelGeometry.inspectorGap)
        #expect(panel.inspectorWindow.frame.height == panel.panelFrame.height)
        panel.choose(.centered)
        #expect(panel.inspector.side == .right)
        #expect(panel.inspectorWindow.frame.minX == panel.frame.maxX + PanelGeometry.inspectorGap)
        #expect(panel.inspectorWindow.frame.height == panel.frame.height)
    }

    /// In slide over the inspector slides with the panel's glass as one unit, and is cut off
    /// at the same screen edge, even with a display beside that edge.
    @Test(arguments: PanelEdge.allCases)
    func theInspectorSlidesWithThePanelAndIsCutOffAtTheEdge(_ edge: PanelEdge) throws {
        standIn.screens = [StandInScreens.laptop, StandInScreens.leftOfLaptop, StandInScreens.external]
        let (panel, defaults) = try makePanel()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        panel.orderIn = { _, _ in }
        panel.orderAway = { _ in }
        panel.drivesSlidesWithTheDisplay = false
        panel.reduceMotion = { false }
        panel.inspector.open("call_json")
        panel.choose(PanelPreset(slideOver: edge))
        let resting = panel.inspectorWindow.glassFrameOnScreen
        let gap = PanelGeometry.inspectorGap
        panel.summon()
        for step in 0..<8 {
            if step > 0 { panel.advanceSlide(by: PanelSlide.slideDuration / 7) }
            let glass = panel.glassFrameOnScreen
            let inspector = panel.inspectorWindow.glassFrameOnScreen
            // One unit: the same offset from rest, the same gap, the same size.
            #expect(inspector.minX - resting.minX == glass.minX - panel.panelFrame.minX)
            #expect(inspector.size == resting.size)
            if edge == .left {
                #expect(inspector.minX == glass.maxX + gap)
            } else {
                #expect(inspector.maxX == glass.minX - gap)
            }
            // The window never reaches past the laptop's visible area, onto another display.
            let window = panel.inspectorWindow.frame
            #expect(window.minX >= laptop.minX && window.maxX <= laptop.maxX)
        }
        // Nearly out, almost nothing of either is left on the laptop's screen.
        panel.dismiss()
        panel.advanceSlide(by: PanelSlide.slideDuration * 0.999)
        let outPanel = panel.glassFrameOnScreen
        let outInspector = panel.inspectorWindow.glassFrameOnScreen
        if edge == .left {
            #expect(outPanel.maxX <= laptop.minX + 5 && outInspector.maxX <= laptop.minX + 5)
        } else {
            #expect(outPanel.minX >= laptop.maxX - 5 && outInspector.minX >= laptop.maxX - 5)
        }
        panel.summon()
        panel.advanceSlide(by: 1)
        #expect(panel.inspectorWindow.glassFrameOnScreen == resting)
        #expect(panel.inspectorWindow.frame == resting)
        #expect(panel.inspectorWindow.alphaValue == 1)
    }

    @Test func theInspectorFollowsThePanelWhenItMovesOrResizes() throws {
        let (panel, defaults) = try makePanel()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        panel.inspector.open("call_json")
        panel.setFrame(CGRect(x: 100, y: 120, width: 600, height: 500), display: false)
        #expect(panel.inspectorWindow.frame == CGRect(x: 708, y: 120, width: ToolInspectorWindow.defaultWidth, height: 500))
        // Moved near the right edge, it flips to the left.
        panel.setFrame(CGRect(x: 860, y: 120, width: 600, height: 500), display: false)
        #expect(panel.inspector.side == .left)
    }

    @Test func theWidthTheOwnerChoosesIsRemembered() throws {
        let (panel, defaults) = try makePanel()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        panel.inspector.open("call_json")
        panel.placeInspector()
        var frame = panel.inspectorWindow.frame
        frame.size.width = 520
        panel.inspectorWindow.setFrame(frame, display: false)
        #expect(defaults.double(forKey: ToolInspectorWindow.widthKey) == 520)
        #expect(panel.inspectorWindow.frame.width == 520)
        #expect(panel.inspectorWindow.frame.minX == panel.frame.maxX + PanelGeometry.inspectorGap)

        let second = SummonPanel(
            session: try #require(PanelPreview.session(named: "inspector-json")), remembersFrame: false,
            placementDefaults: defaults, screens: { [standIn] in standIn.screens }, mouseLocation: { [standIn] in standIn.mouse })
        #expect(second.inspectorWindow.preferredWidth == 520)
    }

    @Test func theInspectorReadsTheSelectedCallLive() throws {
        let session = try #require(PanelPreview.session(named: "inspector-running"))
        let running = try #require(session.visibleTranscript.toolCall("call_running"))
        #expect(running.status == .running)
        #expect(running.output == nil)
        let reminders = try #require(session.visibleTranscript.toolCall("call_fields"))
        #expect(reminders.goAheadText?.hasPrefix("Asked, approved") == true)
        #expect(reminders.source(lookup: { session.toolSources[$0] }) == "Reminders")
    }
}
