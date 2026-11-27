import AppKit
import MacOSAgentCore
import Testing
@testable import mac_os_agent

/// With the first click experiment on, a click on the panel while it does not have focus gives
/// it focus and then reaches what was clicked, so a link in a reply opens on the first click.
/// Off, the panel does nothing before AppKit handles the click. See `SummonPanel.sendEvent`.
struct PanelFirstClickTests {
    @Test func aPressWithoutFocusTakesFocusFirst() {
        #expect(SummonPanel.takesFocusFirst(for: .leftMouseDown, hasFocus: false, isVisible: true, actsOnFirstClick: true))
    }

    @Test func withTheExperimentOffAPressWithoutFocusIsHandledAsItIs() {
        #expect(!SummonPanel.takesFocusFirst(for: .leftMouseDown, hasFocus: false, isVisible: true, actsOnFirstClick: false))
    }

    @Test(arguments: [true, false])
    func aPressWithFocusIsHandledAsItIs(_ actsOnFirstClick: Bool) {
        #expect(!SummonPanel.takesFocusFirst(
            for: .leftMouseDown, hasFocus: true, isVisible: true, actsOnFirstClick: actsOnFirstClick))
    }

    @Test(arguments: [true, false])
    func aHiddenPanelNeverTakesFocus(_ actsOnFirstClick: Bool) {
        #expect(!SummonPanel.takesFocusFirst(
            for: .leftMouseDown, hasFocus: false, isVisible: false, actsOnFirstClick: actsOnFirstClick))
    }

    @Test(arguments: [NSEvent.EventType.leftMouseUp, .leftMouseDragged, .rightMouseDown, .mouseMoved, .scrollWheel, .keyDown])
    func otherEventsLeaveFocusAlone(_ type: NSEvent.EventType) {
        #expect(!SummonPanel.takesFocusFirst(for: type, hasFocus: false, isVisible: true, actsOnFirstClick: true))
    }
}

/// The step the real panel's `sendEvent` takes before AppKit handles a press, with the switch
/// read from a defaults suite of the tests' own. The panel is never ordered in: it stands in
/// that it is on screen, and records focus instead of taking it, so nothing shows and nothing
/// takes focus.
@MainActor
@Suite(.serialized) struct PanelFirstClickAppTests {
    init() { _ = NSApplication.shared }

    private let suiteName = "mac-os-agent-first-click-tests-\(UUID().uuidString)"

    /// Counts the times the panel took focus.
    @MainActor final class FocusRecorder { var taken = 0 }

    private func makePanel(role: SummonPanel.Role, experimentOn: Bool?) throws
        -> (SummonPanel, FocusRecorder, UserDefaults)
    {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        if let experimentOn { Experiment.firstClickActsOnPanel.set(experimentOn, defaults) }
        let session = AgentSession(previewEntries: [], incognito: role == .incognito)
        session.preferences = defaults
        let panel = SummonPanel(
            session: session, role: role, remembersFrame: false, placementDefaults: defaults,
            screens: { [StandInScreens.laptop] }, mouseLocation: { CGPoint(x: 700, y: 400) })
        panel.orderIn = { _, _ in }
        panel.orderAway = { _ in }
        panel.isOnScreenForAFirstClick = { _ in true }
        let recorder = FocusRecorder()
        panel.takeFocusForAFirstClick = { _ in recorder.taken += 1 }
        return (panel, recorder, defaults)
    }

    private func cleanUp(_ defaults: UserDefaults) {
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test(arguments: [SummonPanel.Role.main, .incognito])
    func offByDefaultAPressDoesNotTakeFocusFirst(_ role: SummonPanel.Role) throws {
        let (panel, focus, defaults) = try makePanel(role: role, experimentOn: nil)
        defer { cleanUp(defaults) }
        panel.takeFocusBeforeAFirstClick(.leftMouseDown)
        #expect(focus.taken == 0)
    }

    @Test(arguments: [SummonPanel.Role.main, .incognito])
    func turnedOffAPressDoesNotTakeFocusFirst(_ role: SummonPanel.Role) throws {
        let (panel, focus, defaults) = try makePanel(role: role, experimentOn: false)
        defer { cleanUp(defaults) }
        panel.takeFocusBeforeAFirstClick(.leftMouseDown)
        #expect(focus.taken == 0)
    }

    @Test(arguments: [SummonPanel.Role.main, .incognito])
    func turnedOnAPressTakesFocusFirst(_ role: SummonPanel.Role) throws {
        let (panel, focus, defaults) = try makePanel(role: role, experimentOn: true)
        defer { cleanUp(defaults) }
        panel.takeFocusBeforeAFirstClick(.leftMouseDown)
        #expect(focus.taken == 1)
        panel.takeFocusBeforeAFirstClick(.rightMouseDown)
        #expect(focus.taken == 1, "a right click keeps opening its menu without taking focus")
    }

    /// The switch is read at each press, so it takes effect without a relaunch.
    @Test func turningTheSwitchTakesEffectAtTheNextPress() throws {
        let (panel, focus, defaults) = try makePanel(role: .main, experimentOn: false)
        defer { cleanUp(defaults) }
        panel.takeFocusBeforeAFirstClick(.leftMouseDown)
        #expect(focus.taken == 0)
        Experiment.firstClickActsOnPanel.set(true, defaults)
        panel.takeFocusBeforeAFirstClick(.leftMouseDown)
        #expect(focus.taken == 1)
        Experiment.firstClickActsOnPanel.set(false, defaults)
        panel.takeFocusBeforeAFirstClick(.leftMouseDown)
        #expect(focus.taken == 1)
    }
}
