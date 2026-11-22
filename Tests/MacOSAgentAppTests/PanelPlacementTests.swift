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
    /// A display to the left of the laptop.
    static let leftOfLaptop = SummonPanel.Screen(
        frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
        visible: CGRect(x: -1920, y: 0, width: 1920, height: 1047))

    var screens = [laptop, external]
    var mouse = CGPoint(x: 700, y: 400)
}

/// Counts what the panel asks of the window server, in place of showing a window.
@MainActor
final class WindowRecorder {
    var orderedIn: [Bool] = []
    var orderedAway = 0
}

/// The panel's presets, slides, and toggling, driven through the real panel with stand-in
/// screens and a defaults suite of its own. The panel is never put on screen: ordering in and
/// out is recorded instead, and slides are moved on by hand, so nothing here takes keyboard
/// focus or shows a window, and the owner's saved frame and preset are untouched.
@MainActor
@Suite(.serialized) struct PanelPlacementTests {
    init() { _ = NSApplication.shared }

    private let suiteName = "mac-os-agent-tests-\(UUID().uuidString)"
    private let standIn = StandInScreens()
    private let recorder = WindowRecorder()

    private func makePanel(defaults existing: UserDefaults? = nil, frame: CGRect? = CGRect(x: 300, y: 200, width: 640, height: 560))
        throws -> (SummonPanel, UserDefaults)
    {
        let defaults = try existing ?? #require(UserDefaults(suiteName: suiteName))
        let session = try #require(PanelPreview.session(named: "empty"))
        let standIn = standIn
        let recorder = recorder
        let panel = SummonPanel(
            session: session, remembersFrame: false, placementDefaults: defaults,
            screens: { standIn.screens }, mouseLocation: { standIn.mouse })
        panel.orderIn = { _, makeKey in recorder.orderedIn.append(makeKey) }
        panel.orderAway = { _ in recorder.orderedAway += 1 }
        panel.drivesSlidesWithTheDisplay = false
        panel.reduceMotion = { false }
        if let frame { panel.setFrame(frame, display: false) }
        return (panel, defaults)
    }

    private func cleanUp(_ defaults: UserDefaults) {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private var laptop: CGRect { StandInScreens.laptop.visible }

    private func slideOver(_ edge: PanelEdge, width: CGFloat = 640, in visible: CGRect? = nil) -> CGRect {
        PanelGeometry.slideOverFrame(edge, width: width, minimumWidth: 440, in: visible ?? laptop)
    }

    // MARK: - Presets

    @Test(arguments: PanelEdge.allCases)
    func slideOverPutsThePanelAgainstTheEdgeAndRemembersIt(_ edge: PanelEdge) throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        let preset = PanelPreset(slideOver: edge)
        panel.choose(preset)
        #expect(panel.placement.preset == preset)
        #expect(panel.panelFrame == slideOver(edge))
        #expect(panel.glassFrameOnScreen == panel.panelFrame)
        // The window reaches the screen's edge, so the glass is cut off there as it slides.
        #expect(panel.frame == PanelGeometry.slideOverWindowFrame(panel: slideOver(edge), edge: edge, in: laptop))
        #expect(defaults.string(forKey: SummonPanel.presetKey) == preset.rawValue)
        // Only the free edge resizes.
        #expect(panel.contentMinSize.height == panel.frame.height)
        #expect(panel.contentMaxSize.height == panel.frame.height)
    }

    @Test func centeredComesBackToTheFrameFromBeforeSlideOver() throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        let before = panel.frame
        panel.choose(.slideOverLeft)
        panel.choose(.centered)
        #expect(panel.placement.preset == .centered)
        #expect(panel.frame == before)
        #expect(panel.panelFrame == before)
        #expect(defaults.string(forKey: SummonPanel.presetKey) == PanelPreset.centered.rawValue)
        #expect(panel.contentMinSize == SummonPanel.minimumSize)
    }

    @Test func switchingSidesKeepsTheCenteredFrame() throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        let before = panel.frame
        panel.choose(.slideOverLeft)
        panel.choose(.slideOverRight)
        #expect(panel.placement.preset == .slideOverRight)
        #expect(PanelGeometry.isInSlideOver(panel.panelFrame, at: .right, in: laptop))
        panel.choose(.centered)
        #expect(panel.frame == before)
    }

    @Test func centeredWhenAlreadyCenteredGoesToTheDefaultSizeInTheMiddle() throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        panel.setFrame(CGRect(x: 20, y: 30, width: 900, height: 700), display: false)
        panel.choose(.centered)
        #expect(panel.frame == PanelGeometry.defaultFrame(size: SummonPanel.defaultSize, in: laptop))
    }

    @Test func centeringStaysOnTheScreenThePanelIsOn() throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        panel.setFrame(CGRect(x: 2400, y: 300, width: 500, height: 400), display: false)
        panel.choose(.centered)
        #expect(panel.frame == PanelGeometry.defaultFrame(size: SummonPanel.defaultSize, in: StandInScreens.external.visible))
    }

    @Test func centeringAPanelOffEveryScreenUsesTheScreenWithTheMouse() throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        panel.setFrame(CGRect(x: -5000, y: 300, width: 500, height: 400), display: false)
        standIn.mouse = CGPoint(x: 3000, y: 100)
        panel.choose(.centered)
        #expect(panel.frame == PanelGeometry.defaultFrame(size: SummonPanel.defaultSize, in: StandInScreens.external.visible))
    }

    @Test(arguments: PanelEdge.allCases)
    func draggingASlideOverPanelAwayMakesItCenteredWhereItWasDropped(_ edge: PanelEdge) throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        panel.choose(PanelPreset(slideOver: edge))
        let glass = panel.panelFrame
        let window = panel.frame
        panel.setFrameOrigin(CGPoint(x: window.minX + 40, y: window.minY - 20))
        #expect(panel.placement.preset == .centered)
        #expect(defaults.string(forKey: SummonPanel.presetKey) == PanelPreset.centered.rawValue)
        // The glass stays where it was dropped, and the window shrinks to it once the drag ends.
        let dropped = glass.offsetBy(dx: 40, dy: -20)
        #expect(panel.panelFrame == dropped)
        #expect(panel.frame == dropped)
        #expect(panel.glassFrameOnScreen == dropped)
        #expect(panel.contentMaxSize.height == .greatestFiniteMagnitude)
    }

    @Test(arguments: PanelEdge.allCases)
    func resizingTheFreeEdgeKeepsSlideOverAndRemembersTheWidth(_ edge: PanelEdge) throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        panel.choose(PanelPreset(slideOver: edge))
        var wider = panel.frame
        wider.size.width += 120
        if edge == .right { wider.origin.x -= 120 }
        panel.setFrame(wider, display: false)
        #expect(panel.placement.preset == PanelPreset(slideOver: edge))
        #expect(panel.frame == wider)
        #expect(panel.panelFrame.width == 760)
        #expect(PanelGeometry.isInSlideOver(panel.panelFrame, at: edge, in: laptop))
        #expect(defaults.double(forKey: SummonPanel.slideOverWidthKey) == 760)

        // The width comes back after Centered, and on the next launch.
        panel.choose(.centered)
        panel.choose(PanelPreset(slideOver: edge))
        #expect(panel.panelFrame == slideOver(edge, width: 760))
        let (relaunched, _) = try makePanel(defaults: defaults, frame: nil)
        #expect(relaunched.panelFrame == slideOver(edge, width: 760))
    }

    @Test func thePresetSurvivesHidingAndARelaunch() throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        panel.choose(.slideOverRight)
        panel.summon()
        panel.advanceSlide(by: 1)
        panel.dismiss()
        panel.advanceSlide(by: 1)
        #expect(panel.placement.preset == .slideOverRight)

        // A new panel reading the same defaults, as on the next launch, comes up in slide over.
        let (relaunched, _) = try makePanel(defaults: defaults, frame: nil)
        #expect(relaunched.placement.preset == .slideOverRight)
        #expect(PanelGeometry.isInSlideOver(relaunched.panelFrame, at: .right, in: laptop))
        // Centered goes back to the frame from before slide over, in the earlier launch.
        relaunched.choose(.centered)
        #expect(relaunched.frame == CGRect(x: 300, y: 200, width: 640, height: 560))
    }

    @Test func aSlideOverPanelGoesBackInPlaceWhenTheScreenChangesSize() throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        panel.choose(.slideOverRight)
        // A lower resolution, with the Dock now showing along the bottom.
        let smaller = SummonPanel.Screen(
            frame: CGRect(x: 0, y: 0, width: 1280, height: 800),
            visible: CGRect(x: 0, y: 70, width: 1280, height: 697))
        standIn.screens = [smaller, StandInScreens.external]
        panel.screensDidChange()
        #expect(panel.placement.preset == .slideOverRight)
        #expect(panel.panelFrame == slideOver(.right, in: smaller.visible))
        #expect(panel.frame.maxX == smaller.visible.maxX)
    }

    @Test func aSlideOverPanelOnADisplayThatWasUnpluggedGoesToTheScreenWithTheMouse() throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        panel.setFrame(CGRect(x: 2400, y: 300, width: 640, height: 560), display: false)
        panel.choose(.slideOverLeft)
        #expect(PanelGeometry.isInSlideOver(panel.panelFrame, at: .left, in: StandInScreens.external.visible))
        standIn.screens = [StandInScreens.laptop]
        panel.screensDidChange()
        #expect(panel.placement.preset == .slideOverLeft)
        #expect(PanelGeometry.isInSlideOver(panel.panelFrame, at: .left, in: laptop))
    }

    @Test func aScreenChangeDuringASlideOutFinishesHiding() throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        panel.choose(.slideOverLeft)
        panel.summon()
        panel.advanceSlide(by: 1)
        panel.dismiss()
        panel.advanceSlide(by: 0.05)
        panel.screensDidChange()
        #expect(panel.slide == nil)
        #expect(!panel.isOrderedIn)
        #expect(recorder.orderedAway == 1)
        #expect(panel.glassFrameOnScreen == panel.panelFrame)
    }

    @Test func aCenteredPanelLeftOffEveryScreenComesBack() throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        panel.setFrame(CGRect(x: 2400, y: 300, width: 640, height: 560), display: false)
        standIn.screens = [StandInScreens.laptop]
        panel.screensDidChange()
        #expect(PanelGeometry.isReachable(panel.frame, on: [laptop]))
        #expect(laptop.contains(panel.frame))
        #expect(panel.frame.size == CGSize(width: 640, height: 560))
    }

    @Test func aCenteredPanelStillOnAScreenIsLeftAlone() throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        let frame = CGRect(x: 1300, y: 300, width: 640, height: 560)
        panel.setFrame(frame, display: false)
        standIn.screens = [StandInScreens.laptop]
        panel.screensDidChange()
        #expect(panel.frame == frame)
    }

    // MARK: - Moving the stored dock state from PR #17

    @Test(arguments: [("left", PanelPreset.slideOverLeft), ("right", PanelPreset.slideOverRight)])
    func anOwnerWhoHadDockedFindsTheMatchingSlideOver(_ dock: String, _ preset: PanelPreset) throws {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { cleanUp(defaults) }
        let undocked = CGRect(x: 250, y: 150, width: 700, height: 500)
        defaults.set(dock, forKey: SummonPanel.legacyDockKey)
        defaults.set(NSStringFromRect(undocked), forKey: SummonPanel.legacyUndockedFrameKey)

        let (panel, _) = try makePanel(defaults: defaults, frame: nil)
        #expect(panel.placement.preset == preset)
        #expect(PanelGeometry.isInSlideOver(panel.panelFrame, at: preset.slideOverEdge!, in: laptop))
        #expect(defaults.string(forKey: SummonPanel.presetKey) == preset.rawValue)
        #expect(defaults.object(forKey: SummonPanel.legacyDockKey) == nil)
        #expect(defaults.object(forKey: SummonPanel.legacyUndockedFrameKey) == nil)
        // The frame from before docking is the centered frame to come back to.
        panel.choose(.centered)
        #expect(panel.frame == undocked)
    }

    @Test func anOwnerWhoHadUndockedStaysCentered() throws {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { cleanUp(defaults) }
        defaults.set(nil as String?, forKey: SummonPanel.legacyDockKey)
        let (panel, _) = try makePanel(defaults: defaults)
        #expect(panel.placement.preset == .centered)
        #expect(panel.frame == CGRect(x: 300, y: 200, width: 640, height: 560))
    }

    @Test func theMoveFromTheDockStateLeavesAChosenPresetAlone() throws {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { cleanUp(defaults) }
        defaults.set(PanelPreset.centered.rawValue, forKey: SummonPanel.presetKey)
        defaults.set("left", forKey: SummonPanel.legacyDockKey)
        SummonPanel.migrateLegacyDock(in: defaults)
        #expect(defaults.string(forKey: SummonPanel.presetKey) == PanelPreset.centered.rawValue)
        #expect(defaults.object(forKey: SummonPanel.legacyDockKey) == nil)
    }

    // MARK: - Sliding

    @Test(arguments: PanelEdge.allCases)
    func summoningASlideOverPanelSlidesItInFromItsEdge(_ edge: PanelEdge) throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        panel.choose(PanelPreset(slideOver: edge))
        let focusBefore = panelSession(panel).focusRequest
        panel.summon()
        // Ordered in with keyboard focus at once, and the text field asked to take it, before
        // the slide has moved at all.
        #expect(recorder.orderedIn == [true])
        #expect(panelSession(panel).focusRequest == focusBefore + 1)
        #expect(panel.slide != nil)
        // It starts fully past the edge, outside the window, so nothing of it shows.
        let start = panel.glassFrameOnScreen
        #expect(panel.frame.intersection(start).width <= 0 || panel.frame.intersection(start).isNull)
        #expect(start.size == panel.panelFrame.size)

        var last = start
        for _ in 0..<5 {
            panel.advanceSlide(by: PanelSlide.slideDuration / 6)
            let now = panel.glassFrameOnScreen
            // It moves steadily inward, never past its place, at its full size.
            if edge == .left { #expect(now.minX > last.minX) } else { #expect(now.minX < last.minX) }
            #expect(now.size == panel.panelFrame.size)
            #expect(now.minY == panel.panelFrame.minY)
            last = now
        }
        panel.advanceSlide(by: PanelSlide.slideDuration)
        #expect(panel.slide == nil)
        #expect(panel.glassFrameOnScreen == panel.panelFrame)
        #expect(panel.alphaValue == 1)
    }

    @Test func hidingASlideOverPanelSlidesItOutThenOrdersItOut() throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        panel.choose(.slideOverLeft)
        panel.summon()
        panel.advanceSlide(by: 1)
        panel.dismiss()
        #expect(panel.isOrderedIn)
        #expect(!panel.isPresented)
        #expect(recorder.orderedAway == 0)
        panel.advanceSlide(by: PanelSlide.slideDuration / 2)
        #expect(panel.glassFrameOnScreen.minX < panel.panelFrame.minX)
        panel.advanceSlide(by: PanelSlide.slideDuration)
        #expect(recorder.orderedAway == 1)
        #expect(!panel.isOrderedIn)
        // Back in place, ready for the next slide in.
        #expect(panel.glassFrameOnScreen == panel.panelFrame)
    }

    @Test func summoningDuringASlideOutTurnsItAroundFromWhereItIs() throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        panel.choose(.slideOverRight)
        panel.summon()
        panel.advanceSlide(by: 1)
        panel.dismiss()
        panel.advanceSlide(by: PanelSlide.slideDuration * 0.4)
        let partway = panel.glassFrameOnScreen
        #expect(partway.minX > panel.panelFrame.minX)

        // The hotkey sees a panel on its way out as hidden, and shows it.
        #expect(SummonPanel.ToggleAction.given(isVisible: panel.isPresented && panel.isOrderedIn, isKey: true) == .show)
        panel.toggle()
        #expect(panel.isPresented)
        #expect(recorder.orderedIn.last == true)
        // No jump: it is where it was, then heads back in.
        #expect(panel.glassFrameOnScreen == partway)
        panel.advanceSlide(by: 0.02)
        #expect(panel.glassFrameOnScreen.minX < partway.minX)
        panel.advanceSlide(by: 1)
        #expect(panel.glassFrameOnScreen == panel.panelFrame)
        #expect(recorder.orderedAway == 0)
    }

    @Test func hidingDuringASlideInTurnsItBackOut() throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        panel.choose(.slideOverLeft)
        panel.summon()
        panel.advanceSlide(by: PanelSlide.slideDuration * 0.3)
        let partway = panel.glassFrameOnScreen
        panel.dismiss()
        #expect(panel.glassFrameOnScreen == partway)
        panel.advanceSlide(by: 0.02)
        #expect(panel.glassFrameOnScreen.minX < partway.minX)
        panel.advanceSlide(by: 1)
        #expect(recorder.orderedAway == 1)
        #expect(!panel.isOrderedIn)
    }

    @Test func slidingOffTheLeftEdgeNeverReachesTheDisplayToTheLeft() throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        standIn.screens = [StandInScreens.laptop, StandInScreens.leftOfLaptop]
        panel.choose(.slideOverLeft)
        panel.summon()
        panel.advanceSlide(by: 1)
        panel.dismiss()
        let other = StandInScreens.leftOfLaptop.frame
        for _ in 0..<12 {
            panel.advanceSlide(by: PanelSlide.slideDuration / 10)
            // The window, which cuts the glass off, never covers any of the other display.
            let overlap = panel.frame.intersection(other)
            #expect(overlap.isNull || overlap.width <= 0)
        }
        #expect(recorder.orderedAway == 1)
    }

    @Test func reduceMotionFadesInPlace() throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        panel.reduceMotion = { true }
        panel.choose(.slideOverRight)
        panel.summon()
        #expect(panel.alphaValue == 0)
        #expect(panel.glassFrameOnScreen == panel.panelFrame)
        panel.advanceSlide(by: PanelSlide.fadeDuration / 2)
        #expect(panel.alphaValue > 0 && panel.alphaValue < 1)
        #expect(panel.glassFrameOnScreen == panel.panelFrame)
        panel.advanceSlide(by: PanelSlide.fadeDuration)
        #expect(panel.alphaValue == 1)
        panel.dismiss()
        panel.advanceSlide(by: PanelSlide.fadeDuration)
        #expect(recorder.orderedAway == 1)
        #expect(panel.alphaValue == 1)
    }

    @Test func aCenteredPanelAppearsAndHidesInPlace() throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        panel.summon()
        #expect(panel.slide == nil)
        #expect(recorder.orderedIn == [true])
        panel.dismiss()
        #expect(panel.slide == nil)
        #expect(recorder.orderedAway == 1)
    }

    @Test func choosingASlideOverWhileShowingSlidesItInFromThatEdge() throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        panel.summon()
        panel.choose(.slideOverRight)
        #expect(panel.slide != nil)
        #expect(panel.glassFrameOnScreen.minX >= laptop.maxX)
        panel.advanceSlide(by: 1)
        #expect(panel.glassFrameOnScreen == panel.panelFrame)
        // Back to Centered appears in place, with no slide.
        panel.choose(.centered)
        #expect(panel.slide == nil)
    }

    @Test func aFollowerHearsEveryFrameOfASlideAndWhereItComesToRest() throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        panel.choose(.slideOverLeft)
        var frames: [PanelMotionFrame] = []
        panel.placement.onMotion = { frames.append($0) }
        panel.summon()
        for _ in 0..<4 { panel.advanceSlide(by: PanelSlide.slideDuration / 4) }
        #expect(frames.count >= 5)
        #expect(frames.first?.position == 0)
        #expect(frames.last?.position == 1)
        #expect(frames.last?.offset == 0)
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $0.position <= $1.position })
        #expect(frames.allSatisfy { $0.clip == laptop && $0.resting == panel.panelFrame })
        // The glass in each frame is where the panel drew it.
        frames.removeAll()
        panel.dismiss()
        panel.advanceSlide(by: PanelSlide.slideDuration / 2)
        #expect(frames.last?.glass == panel.glassFrameOnScreen)
        panel.advanceSlide(by: 1)
        #expect(frames.last?.position == 0)
    }

    @Test func theFreeSideAndItsRoomFollowThePreset() throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        #expect(panel.placement.freeSide == .right)
        panel.choose(.slideOverRight)
        #expect(panel.placement.freeSide == .left)
        let glass = panel.panelFrame
        #expect(panel.placement.roomOnFreeSide == glass.minX - (laptop.minX + PanelGeometry.slideOverMargin))
        panel.choose(.slideOverLeft)
        #expect(panel.placement.freeSide == .right)
        #expect(panel.placement.roomOnFreeSide == laptop.maxX - PanelGeometry.slideOverMargin - panel.panelFrame.maxX)
    }

    private func panelSession(_ panel: SummonPanel) -> AgentSession {
        // The session is private to the panel. The text field's focus request is read through
        // the content's environment in the app, and through this mirror in tests.
        Mirror(reflecting: panel).children.first { $0.label == "session" }!.value as! AgentSession
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
        #expect(SummonPanel.ToggleAction.given(isVisible: panel.isPresented, isKey: panel.isKeyWindow) == .show)
    }

    @Test func theCloseButtonHidesThePanelAsEscapeDoes() throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        panel.summon()
        panel.placement.close()
        #expect(recorder.orderedAway == 1)
        #expect(!panel.isPresented)
        panel.summon()
        panel.cancelOperation(nil)
        #expect(recorder.orderedAway == 2)
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

    @Test func theBarsSymbolsExist() {
        for name in ["xmark"] + PanelPreset.allCases.map(\.symbol) {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
        }
    }

    @Test func theLayoutMenuListsThePresetsWithACheckOnTheCurrentOne() {
        var chosen: [PanelPreset] = []
        let layout = LayoutMenu(current: .slideOverRight) { chosen.append($0) }
        let items = layout.menu.items
        #expect(items.map(\.title) == ["Centered", "Slide Over Left", "Slide Over Right"])
        #expect(items.map(\.state) == [.off, .off, .on])
        #expect(items.allSatisfy { $0.keyEquivalent.isEmpty && $0.isEnabled && $0.image != nil })
        layout.chosen(items[1])
        #expect(chosen == [.slideOverLeft])
    }

    @Test func choosingFromTheLayoutMenuMovesThePanel() throws {
        let (panel, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        let layout = LayoutMenu(current: panel.placement.preset, choose: panel.placement.choose)
        layout.chosen(layout.menu.items[2])
        #expect(panel.placement.preset == .slideOverRight)
        #expect(PanelGeometry.isInSlideOver(panel.panelFrame, at: .right, in: laptop))
    }

    /// The menu runs its own tracking. When it closes, the text field has focus again, so the
    /// owner can type straight away.
    @Test func afterTheMenuClosesTheTextFieldHasFocusAgain() async throws {
        let harness = try PanelHarness(draft: "")
        await harness.settle()
        let editor = harness.editor
        #expect(harness.panel.firstResponder === editor)
        harness.panel.makeFirstResponder(nil)
        MenuAnchor.restoreFocus(in: harness.panel, wasKey: false, responder: editor)
        #expect(harness.panel.firstResponder === editor)
    }

    /// The bar moves the panel everywhere except over its controls: the close button at the
    /// left, and the layout menu at the right.
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
        // The middle of the bar, and just after the close button, where labels will go.
        #expect(hit(x: content.bounds.midX) === drag)
        #expect(hit(x: PanelTopBar.sidePadding + TopBarButton.size + 30) === drag)
        // The close button and the layout menu.
        for x in [PanelTopBar.sidePadding + TopBarButton.size / 2, content.bounds.maxX - PanelTopBar.sidePadding - TopBarButton.size / 2] {
            let view = hit(x: x)
            #expect(view != nil)
            #expect(view !== drag)
        }
    }
}
