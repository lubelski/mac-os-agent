import MacOSAgentCore
import Testing

@Suite struct PanelLayeringTests {
    private func layer(focus: Bool, onTop: Bool, own: Bool) -> PanelLayer {
        PanelLayering.layer(for: PanelLayeringState(hasFocus: focus, keepsOnTop: onTop, ownWindowInFront: own))
    }

    @Test func aFocusedPanelFloats() {
        #expect(layer(focus: true, onTop: false, own: false) == .floating)
    }

    @Test func anUnfocusedPanelLayersLikeAnOrdinaryWindow() {
        #expect(layer(focus: false, onTop: false, own: false) == .ordinary)
    }

    @Test func keepOnTopFloatsWithoutFocus() {
        #expect(layer(focus: false, onTop: true, own: false) == .floating)
        #expect(layer(focus: true, onTop: true, own: false) == .floating)
    }

    @Test(arguments: [false, true], [false, true])
    func theAppsOwnWindowInFrontAlwaysWins(focus: Bool, onTop: Bool) {
        #expect(layer(focus: focus, onTop: onTop, own: true) == .ordinary)
    }

    @Test func droppingBelowSettingsOrdersBelowIt() {
        #expect(PanelLayering.lowering(from: .floating, to: .ordinary, ownWindowInFront: true, anotherApplicationIsFrontmost: false) == .belowOwnWindow)
        #expect(PanelLayering.lowering(from: .floating, to: .ordinary, ownWindowInFront: true, anotherApplicationIsFrontmost: true) == .belowOwnWindow)
    }

    @Test func droppingForAnotherAppOrdersBelowItsWindow() {
        #expect(PanelLayering.lowering(from: .floating, to: .ordinary, ownWindowInFront: false, anotherApplicationIsFrontmost: true) == .belowFrontmostApplication)
    }

    @Test func droppingWithNothingInFrontStaysInPlace() {
        #expect(PanelLayering.lowering(from: .floating, to: .ordinary, ownWindowInFront: false, anotherApplicationIsFrontmost: false) == .inPlace)
    }

    @Test func noChangeOrRaisingNeedsNoOrdering() {
        #expect(PanelLayering.lowering(from: .ordinary, to: .floating, ownWindowInFront: false, anotherApplicationIsFrontmost: true) == nil)
        #expect(PanelLayering.lowering(from: .ordinary, to: .ordinary, ownWindowInFront: true, anotherApplicationIsFrontmost: true) == nil)
        #expect(PanelLayering.lowering(from: .floating, to: .floating, ownWindowInFront: false, anotherApplicationIsFrontmost: true) == nil)
    }

    @Test func settingsStaysInFrontUntilThePanelTakesFocus() {
        var tracker = OwnWindowInFront<Int>()
        #expect(tracker.window == nil)
        tracker.ownWindowTookFocus(1)
        #expect(tracker.window == 1)
        // A sheet on Settings, then Settings again when the sheet ends.
        tracker.ownWindowTookFocus(2)
        tracker.ownWindowTookFocus(1)
        #expect(tracker.window == 1)
        tracker.panelTookFocus()
        #expect(tracker.window == nil)
    }

    @Test func closingTheWindowInFrontClearsIt() {
        var tracker = OwnWindowInFront<Int>()
        tracker.ownWindowTookFocus(1)
        tracker.windowClosed(2)
        #expect(tracker.window == 1)
        tracker.windowClosed(1)
        #expect(tracker.window == nil)
    }

    /// The owner opens Settings over a panel kept on top, reveals a file in Finder from it, then
    /// closes Settings. Finder is not covered while Settings is open, and the panel floats again
    /// once Settings is closed.
    @Test func aPanelKeptOnTopStaysDownWhileSettingsIsOpen() {
        var tracker = OwnWindowInFront<Int>()
        func current(focus: Bool) -> PanelLayer {
            PanelLayering.layer(for: PanelLayeringState(hasFocus: focus, keepsOnTop: true, ownWindowInFront: tracker.window != nil))
        }
        #expect(current(focus: true) == .floating)
        tracker.ownWindowTookFocus(1)
        #expect(current(focus: false) == .ordinary)
        // Finder takes focus. Settings is still open.
        #expect(current(focus: false) == .ordinary)
        tracker.windowClosed(1)
        #expect(current(focus: false) == .floating)
    }
}
