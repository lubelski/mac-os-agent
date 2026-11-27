import AppKit
import Testing
@testable import mac_os_agent

/// A click on the panel while it does not have focus gives it focus and then reaches what was
/// clicked, so a link in a reply opens on the first click. See `SummonPanel.sendEvent`.
struct PanelFirstClickTests {
    @Test func aPressWithoutFocusTakesFocusFirst() {
        #expect(SummonPanel.takesFocusFirst(for: .leftMouseDown, hasFocus: false, isVisible: true))
    }

    @Test func aPressWithFocusIsHandledAsItIs() {
        #expect(!SummonPanel.takesFocusFirst(for: .leftMouseDown, hasFocus: true, isVisible: true))
    }

    @Test func aHiddenPanelNeverTakesFocus() {
        #expect(!SummonPanel.takesFocusFirst(for: .leftMouseDown, hasFocus: false, isVisible: false))
    }

    @Test(arguments: [NSEvent.EventType.leftMouseUp, .leftMouseDragged, .rightMouseDown, .mouseMoved, .scrollWheel, .keyDown])
    func otherEventsLeaveFocusAlone(_ type: NSEvent.EventType) {
        #expect(!SummonPanel.takesFocusFirst(for: type, hasFocus: false, isVisible: true))
    }
}
