import AppKit
import MacOSAgentCore
import SwiftUI
import Testing
@testable import mac_os_agent

/// Stand-in displays the tests can change, as if one were unplugged or changed resolution.
@MainActor
final class StandInScreens {
    static let laptop = SummonPanel.Screen(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visible: CGRect(x: 0, y: 0, width: 1512, height: 949))
    static let external = SummonPanel.Screen(
        frame: CGRect(x: 1512, y: -200, width: 2560, height: 1440),
        visible: CGRect(x: 1512, y: -200, width: 2560, height: 1415))

    var screens = [laptop, external]
    var mouse = CGPoint(x: 700, y: 400)
}

/// The panel's docking, re-centering, and toggling, driven through the real panel with stand-in
/// screens and a defaults suite of its own. The panel is never put on screen, so nothing here
/// takes keyboard focus or shows a window, and the owner's saved frame and dock are untouched.
@MainActor
@Suite(.serialized) struct PanelPlacementTests {
    init() { _ = NSApplication.shared }

    private let suiteName = "mac-os-agent-tests-\(UUID().uuidString)"
    private let standIn = StandInScreens()

    private func makePanel() throws -> (SummonPanel, UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let session = try #require(PanelPreview.session(named: "empty"))
        let standIn = standIn
        let panel = SummonPanel(
            session: session, remembersFrame: false, placementDefaults: defaults,
            screens: { standIn.screens }, mouseLocation: { standIn.mouse })
        panel.setFrame(CGRect(x: 300, y: 200, width: 640, height: 560), display: false)
        return (panel, defaults)
    }

    private func cleanUp(_ defaults: UserDefaults) {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private var laptop: CGRect { StandInScreens.laptop.visible }

    // MARK: - Docking

    @Test(arguments: PanelDock.allCases)
    func dockingPutsThePanelAgainstTheEdgeAndRemembersIt(_ dock: PanelDock) throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        panel.toggleDock(dock)
        #expect(panel.placement.dock == dock)
        #expect(panel.frame == PanelGeometry.dockedFrame(dock, width: 640, minimumWidth: 440, in: laptop))
        #expect(defaults.string(forKey: SummonPanel.dockKey) == dock.rawValue)
        // Only the free edge resizes while docked.
        #expect(panel.contentMinSize.height == panel.frame.height)
        #expect(panel.contentMaxSize.height == panel.frame.height)
    }

    @Test func choosingTheActiveDockAgainUndocksToTheFrameFromBefore() throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        let before = panel.frame
        panel.toggleDock(.left)
        panel.toggleDock(.left)
        #expect(panel.placement.dock == nil)
        #expect(panel.frame == before)
        #expect(defaults.string(forKey: SummonPanel.dockKey) == nil)
        #expect(panel.contentMinSize == SummonPanel.minimumSize)
    }

    @Test func switchingSidesKeepsTheFrameFromBeforeDocking() throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        let before = panel.frame
        panel.toggleDock(.left)
        panel.toggleDock(.right)
        #expect(panel.placement.dock == .right)
        #expect(PanelGeometry.isDocked(panel.frame, at: .right, in: laptop))
        panel.toggleDock(.right)
        #expect(panel.frame == before)
    }

    @Test func recenteringUndocksAtTheDefaultSize() throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        panel.setFrame(CGRect(x: 20, y: 30, width: 900, height: 700), display: false)
        panel.toggleDock(.right)
        panel.recenter()
        #expect(panel.placement.dock == nil)
        #expect(panel.frame == PanelGeometry.defaultFrame(size: SummonPanel.defaultSize, in: laptop))
        #expect(defaults.string(forKey: SummonPanel.dockKey) == nil)
    }

    @Test func recenteringStaysOnTheScreenThePanelIsOn() throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        panel.setFrame(CGRect(x: 2400, y: 300, width: 500, height: 400), display: false)
        panel.recenter()
        #expect(panel.frame == PanelGeometry.defaultFrame(size: SummonPanel.defaultSize, in: StandInScreens.external.visible))
    }

    @Test func recenteringAPanelOffEveryScreenUsesTheScreenWithTheMouse() throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        panel.setFrame(CGRect(x: -5000, y: 300, width: 500, height: 400), display: false)
        standIn.mouse = CGPoint(x: 3000, y: 100)
        panel.recenter()
        #expect(panel.frame == PanelGeometry.defaultFrame(size: SummonPanel.defaultSize, in: StandInScreens.external.visible))
    }

    @Test func draggingADockedPanelAwayUndocksIt() throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        panel.toggleDock(.left)
        let docked = panel.frame
        panel.setFrameOrigin(CGPoint(x: docked.minX + 40, y: docked.minY - 20))
        #expect(panel.placement.dock == nil)
        #expect(defaults.string(forKey: SummonPanel.dockKey) == nil)
        // It keeps the frame it was dragged to.
        #expect(panel.frame.origin == CGPoint(x: docked.minX + 40, y: docked.minY - 20))
        #expect(panel.contentMaxSize.height == .greatestFiniteMagnitude)
    }

    @Test(arguments: PanelDock.allCases)
    func resizingTheFreeEdgeKeepsThePanelDocked(_ dock: PanelDock) throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        panel.toggleDock(dock)
        var wider = panel.frame
        wider.size.width += 120
        if dock == .right { wider.origin.x -= 120 }
        panel.setFrame(wider, display: false)
        #expect(panel.placement.dock == dock)
        #expect(panel.frame == wider)
    }

    @Test func theDockSurvivesHidingAndARelaunch() throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        panel.toggleDock(.right)
        panel.dismiss()
        #expect(panel.placement.dock == .right)

        // A new panel reading the same defaults, as on the next launch, comes up docked.
        let session = try #require(PanelPreview.session(named: "empty"))
        let standIn = standIn
        let relaunched = SummonPanel(
            session: session, remembersFrame: false, placementDefaults: defaults,
            screens: { standIn.screens }, mouseLocation: { standIn.mouse })
        #expect(relaunched.placement.dock == .right)
        #expect(PanelGeometry.isDocked(relaunched.frame, at: .right, in: laptop))
        // Undocking it goes back to the frame from before it docked, in the earlier launch.
        relaunched.toggleDock(.right)
        #expect(relaunched.frame == CGRect(x: 300, y: 200, width: 640, height: 560))
    }

    @Test func aDockedPanelDocksAgainWhenTheScreenChangesSize() throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        panel.toggleDock(.right)
        // A lower resolution, with the Dock now showing along the bottom.
        let smaller = SummonPanel.Screen(
            frame: CGRect(x: 0, y: 0, width: 1280, height: 800),
            visible: CGRect(x: 0, y: 70, width: 1280, height: 697))
        standIn.screens = [smaller, StandInScreens.external]
        panel.screensDidChange()
        #expect(panel.placement.dock == .right)
        #expect(panel.frame == PanelGeometry.dockedFrame(.right, width: 640, minimumWidth: 440, in: smaller.visible))
    }

    @Test func aDockedPanelOnADisplayThatWasUnpluggedDocksOnTheScreenWithTheMouse() throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        panel.setFrame(CGRect(x: 2400, y: 300, width: 640, height: 560), display: false)
        panel.toggleDock(.left)
        #expect(PanelGeometry.isDocked(panel.frame, at: .left, in: StandInScreens.external.visible))
        standIn.screens = [StandInScreens.laptop]
        panel.screensDidChange()
        #expect(panel.placement.dock == .left)
        #expect(PanelGeometry.isDocked(panel.frame, at: .left, in: laptop))
    }

    @Test func aFreePanelLeftOffEveryScreenComesBack() throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        panel.setFrame(CGRect(x: 2400, y: 300, width: 640, height: 560), display: false)
        standIn.screens = [StandInScreens.laptop]
        panel.screensDidChange()
        #expect(PanelGeometry.isReachable(panel.frame, on: [laptop]))
        #expect(laptop.contains(panel.frame))
        #expect(panel.frame.size == CGSize(width: 640, height: 560))
    }

    @Test func aFreePanelStillOnAScreenIsLeftAlone() throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        let frame = CGRect(x: 1300, y: 300, width: 640, height: 560)
        panel.setFrame(frame, display: false)
        standIn.screens = [StandInScreens.laptop]
        panel.screensDidChange()
        #expect(panel.frame == frame)
    }

    // MARK: - Showing and hiding

    @Test func theHotkeyShowsThenFocusesThenHides() {
        #expect(SummonPanel.ToggleAction.given(isVisible: false, isKey: false) == .show)
        #expect(SummonPanel.ToggleAction.given(isVisible: true, isKey: false) == .focus)
        #expect(SummonPanel.ToggleAction.given(isVisible: true, isKey: true) == .hide)
    }

    @Test func aHiddenPanelIsShownByTheToggleDecision() throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        #expect(!panel.isVisible)
        #expect(SummonPanel.ToggleAction.given(isVisible: panel.isVisible, isKey: panel.isKeyWindow) == .show)
    }

    /// Losing keyboard focus to another app no longer hides the panel. The panel is ordered in
    /// far off every display and fully transparent for a moment, without becoming key.
    @Test func losingKeyboardFocusLeavesThePanelUp() throws {
        let (panel, defaults) = try makePanel()
        defer {
            panel.orderOut(nil)
            cleanUp(defaults)
        }
        panel.alphaValue = 0
        panel.setFrameOrigin(CGPoint(x: -30000, y: -30000))
        panel.orderFrontRegardless()
        #expect(panel.isVisible)
        #expect(!panel.isKeyWindow)
        panel.resignKey()
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: panel)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        #expect(panel.isVisible)
        #expect(!panel.hidesOnDeactivate)
    }

    @Test func thePanelFloatsOnEverySpaceAndOverFullScreenApps() throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        #expect(panel.level == .floating)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.styleMask.contains(.nonactivatingPanel))
    }

    // MARK: - The menu bar icon

    private func mouse(_ type: NSEvent.EventType, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    }

    @Test func aLeftClickOnTheIconTogglesThePanel() {
        #expect(StatusItemClick.action(for: mouse(.leftMouseUp)) == .togglePanel)
        #expect(StatusItemClick.action(for: mouse(.leftMouseDown)) == .togglePanel)
    }

    @Test func aRightClickOrControlClickOpensTheMenu() {
        #expect(StatusItemClick.action(for: mouse(.rightMouseUp)) == .showMenu)
        #expect(StatusItemClick.action(for: mouse(.leftMouseUp, .control)) == .showMenu)
    }

    /// VoiceOver's press and the keyboard reach the button without a mouse event.
    @Test func aPressWithoutTheMouseOpensTheMenu() {
        #expect(StatusItemClick.action(for: nil) == .showMenu)
        let key = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)
        #expect(StatusItemClick.action(for: key) == .showMenu)
    }

    // MARK: - The top bar

    @Test(arguments: ["rectangle.center.inset.filled", "rectangle.lefthalf.inset.filled", "rectangle.righthalf.inset.filled"])
    func theBarsSymbolsExist(_ name: String) {
        #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil)
    }

    /// The bar moves the panel everywhere except over its controls.
    @Test func theBarMovesThePanelExceptOverItsControls() async throws {
        let harness = try PanelHarness(draft: "")
        await harness.settle()
        let content = try #require(harness.panel.contentView)
        let drag = try #require(harness.views(named: "DragView").first)
        #expect(drag.frame.height == PanelTopBar.height)
        // Points in the content's own coordinates, then in its superview's, which hit testing takes.
        func hit(x: CGFloat) -> NSView? {
            let y = content.isFlipped ? PanelTopBar.height / 2 : content.bounds.height - PanelTopBar.height / 2
            let point = content.convert(CGPoint(x: x, y: y), to: content.superview)
            return content.hitTest(point)
        }
        // The middle of the bar, and its left end, where the leading area is.
        #expect(hit(x: content.bounds.midX) === drag)
        #expect(hit(x: 20) === drag)
        // Each control, from the right: 12 points of padding, then 22 point buttons 2 apart.
        for index in 0..<3 {
            let x = content.bounds.maxX - 12 - TopBarButton.size / 2 - CGFloat(index) * (TopBarButton.size + 2)
            let view = hit(x: x)
            #expect(view != nil)
            #expect(view !== drag)
        }
    }
}
