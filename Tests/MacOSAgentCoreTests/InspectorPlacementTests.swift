import CoreGraphics
import Testing
@testable import MacOSAgentCore

@Suite struct InspectorPlacementTests {
    let laptop = CGRect(x: 0, y: 0, width: 1512, height: 949)
    let gap = PanelGeometry.inspectorGap

    @Test func aFreePanelGetsTheInspectorOnItsRightAtTheSameHeight() {
        let panel = CGRect(x: 300, y: 260, width: 640, height: 560)
        let placement = PanelGeometry.inspectorPlacement(panel: panel, freeSide: .right, width: 420, in: laptop)
        #expect(placement == InspectorPlacement(
            frame: CGRect(x: panel.maxX + gap, y: 260, width: 420, height: 560), side: .right, overlapsPanel: false))
    }

    @Test func aPanelNearTheRightEdgeGetsItOnTheLeft() {
        let panel = CGRect(x: 800, y: 100, width: 640, height: 560)
        let placement = PanelGeometry.inspectorPlacement(panel: panel, freeSide: .right, width: 420, in: laptop)
        #expect(placement.side == .left)
        #expect(placement.frame.maxX == panel.minX - gap)
        #expect(placement.frame.width == 420)
    }

    @Test func theWidthShrinksToTheRoomButNotBelowTheMinimum() {
        // 1512 - 10 - (1076 + 8) = 418 of room on the right.
        let panel = CGRect(x: 436, y: 0, width: 640, height: 900)
        let placement = PanelGeometry.inspectorPlacement(panel: panel, freeSide: .right, width: 600, in: laptop)
        #expect(placement.side == .right)
        #expect(placement.frame.width == 418)
        #expect(placement.frame.maxX <= laptop.maxX - PanelGeometry.slideOverMargin)
    }

    @Test func slideOverLeftOpensToTheRightAndSlideOverRightOpensToTheLeft() {
        let left = PanelGeometry.slideOverFrame(.left, width: 640, minimumWidth: 440, in: laptop)
        let right = PanelGeometry.slideOverFrame(.right, width: 640, minimumWidth: 440, in: laptop)
        let fromLeft = PanelGeometry.inspectorPlacement(
            panel: left, freeSide: PanelPreset.slideOverLeft.freeSide, width: 420, in: laptop)
        let fromRight = PanelGeometry.inspectorPlacement(
            panel: right, freeSide: PanelPreset.slideOverRight.freeSide, width: 420, in: laptop)
        #expect(fromLeft.side == .right)
        #expect(fromLeft.frame.minX == left.maxX + gap)
        #expect(fromLeft.frame.height == left.height)
        #expect(fromRight.side == .left)
        #expect(fromRight.frame.maxX == right.minX - gap)
        // Slide over right always prefers the left, even when the panel is narrow and the right is
        // the screen's edge.
        #expect(!fromRight.overlapsPanel)
    }

    @Test func aNarrowScreenCoversTheFarSideAndKeepsTheConversationInView() {
        let small = CGRect(x: 0, y: 0, width: 900, height: 700)
        let panel = CGRect(x: 130, y: 50, width: 640, height: 560)
        let placement = PanelGeometry.inspectorPlacement(panel: panel, freeSide: .right, width: 420, in: small)
        #expect(placement.overlapsPanel)
        #expect(placement.side == .right)
        #expect(placement.frame.maxX == small.maxX - PanelGeometry.slideOverMargin)
        #expect(placement.frame.minX - panel.minX >= PanelGeometry.conversationKeptInView)
        #expect(placement.frame.width >= PanelGeometry.inspectorNarrowestWidth)
        #expect(placement.frame.height == panel.height)
    }

    @Test func aTinyScreenStillGivesTheInspectorItsNarrowestWidth() {
        let tiny = CGRect(x: 0, y: 0, width: 500, height: 400)
        let panel = CGRect(x: 20, y: 20, width: 460, height: 360)
        let placement = PanelGeometry.inspectorPlacement(panel: panel, freeSide: .right, width: 420, in: tiny)
        #expect(placement.overlapsPanel)
        #expect(placement.frame.width == PanelGeometry.inspectorNarrowestWidth)
    }

    @Test func aPanelOnASecondScreenPlacesOnThatScreen() {
        let external = CGRect(x: 1512, y: -200, width: 2560, height: 1415)
        let panel = CGRect(x: 2000, y: 0, width: 640, height: 560)
        let placement = PanelGeometry.inspectorPlacement(panel: panel, freeSide: .right, width: 420, in: external)
        #expect(placement.side == .right)
        #expect(external.contains(placement.frame))
    }
}
