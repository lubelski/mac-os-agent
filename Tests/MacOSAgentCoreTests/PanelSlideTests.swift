import CoreGraphics
import Testing
@testable import MacOSAgentCore

@Suite struct PanelPresetTests {
    let laptop = CGRect(x: 0, y: 0, width: 1512, height: 949)

    @Test func theMenuListsCenteredThenEachSlideOver() {
        #expect(PanelPreset.allCases.map(\.title) == ["Centered", "Slide Over Left", "Slide Over Right"])
        #expect(PanelPreset.centered.slideOverEdge == nil)
        #expect(PanelPreset.slideOverLeft.slideOverEdge == .left)
        #expect(PanelPreset.slideOverRight.slideOverEdge == .right)
        for edge in PanelEdge.allCases {
            #expect(PanelPreset(slideOver: edge).slideOverEdge == edge)
        }
    }

    @Test func theFreeSideIsTheRightUnlessThePanelIsAgainstTheRightEdge() {
        #expect(PanelPreset.centered.freeSide == .right)
        #expect(PanelPreset.slideOverLeft.freeSide == .right)
        #expect(PanelPreset.slideOverRight.freeSide == .left)
    }

    @Test func aDockFromBeforePresetsBecomesTheMatchingSlideOver() {
        #expect(PanelPreset(legacyDock: "left") == .slideOverLeft)
        #expect(PanelPreset(legacyDock: "right") == .slideOverRight)
        #expect(PanelPreset(legacyDock: nil) == nil)
        #expect(PanelPreset(legacyDock: "top") == nil)
    }

    @Test func theRoomBesideThePanelStopsAtTheMargin() {
        let left = PanelGeometry.slideOverFrame(.left, width: 640, minimumWidth: 440, in: laptop)
        let margin = PanelGeometry.slideOverMargin
        #expect(PanelGeometry.room(on: .right, of: left, in: laptop) == laptop.maxX - margin - left.maxX)
        #expect(PanelGeometry.room(on: .left, of: left, in: laptop) == 0)
        // A panel hanging past the edge has no room on that side, not less than none.
        #expect(PanelGeometry.room(on: .left, of: left.offsetBy(dx: -100, dy: 0), in: laptop) == 0)
    }
}

@Suite struct PanelSlideTests {
    /// A laptop screen with a second display to its left, the case where a slide out past the
    /// left edge must not be seen crossing the other display.
    let laptop = CGRect(x: 0, y: 0, width: 1512, height: 949)
    let displayToTheLeft = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    /// A laptop screen with the Dock on its left, which the visible area leaves out.
    let dockOnTheLeft = CGRect(x: 64, y: 0, width: 1448, height: 949)

    @Test func aSlideInRunsFromOffScreenToInPlaceAndStops() {
        var slide = PanelSlide(style: .slide, to: .shown)
        #expect(slide.position == 0)
        #expect(slide.travel == 1)
        slide.advance(by: PanelSlide.slideDuration / 2)
        #expect(slide.position > 0.5)
        #expect(!slide.isFinished)
        slide.advance(by: PanelSlide.slideDuration)
        #expect(slide.isFinished)
        #expect(slide.position == 1)
        #expect(slide.travel == 0)
        #expect(slide.alpha == 1)
    }

    @Test func aSlideOutStartsGentlyAndEndsFullyOut() {
        var slide = PanelSlide(style: .slide, to: .hidden)
        #expect(slide.position == 1)
        slide.advance(by: PanelSlide.slideDuration * 0.25)
        // Run backward, the ease out starts slowly: a quarter of the time moves it less than a quarter.
        #expect(slide.travel < 0.25)
        slide.advance(by: PanelSlide.slideDuration)
        #expect(slide.isFinished)
        #expect(slide.travel == 1)
    }

    @Test func summoningDuringASlideOutTurnsItAroundWithoutAJump() {
        var slide = PanelSlide(style: .slide, to: .hidden)
        slide.advance(by: PanelSlide.slideDuration * 0.4)
        let before = slide.position
        slide.retarget(.shown)
        #expect(slide.position == before)
        #expect(!slide.isFinished)
        slide.advance(by: 0.01)
        #expect(slide.position > before)
        slide.advance(by: PanelSlide.slideDuration)
        #expect(slide.isFinished)
        #expect(slide.position == 1)
    }

    @Test func hidingDuringASlideInTurnsItAroundWithoutAJump() {
        var slide = PanelSlide(style: .slide, to: .shown)
        slide.advance(by: PanelSlide.slideDuration * 0.3)
        let before = slide.position
        slide.retarget(.hidden)
        #expect(slide.position == before)
        slide.advance(by: 0.01)
        #expect(slide.position < before)
        // It takes only as long to get out as it had come in.
        slide.advance(by: PanelSlide.slideDuration * 0.3)
        #expect(slide.isFinished)
        #expect(slide.position == 0)
    }

    @Test func retargetingToWhereItIsHeadedChangesNothing() {
        var slide = PanelSlide(style: .slide, to: .shown)
        slide.advance(by: 0.1)
        let copy = slide
        slide.retarget(.shown)
        #expect(slide == copy)
    }

    @Test func reduceMotionFadesInPlaceQuickly() {
        var slide = PanelSlide(style: .fade, to: .shown)
        #expect(slide.travel == 0)
        #expect(slide.alpha == 0)
        #expect(PanelSlide.fadeDuration < PanelSlide.slideDuration)
        slide.advance(by: PanelSlide.fadeDuration)
        #expect(slide.isFinished)
        #expect(slide.alpha == 1)
        #expect(slide.travel == 0)
    }

    @Test func noTimeOrNegativeTimeMovesNothing() {
        var slide = PanelSlide(style: .slide, to: .shown)
        slide.advance(by: 0)
        slide.advance(by: -1)
        #expect(slide.progress == 0)
    }

    @Test(arguments: PanelEdge.allCases)
    func theWindowReachesTheScreensEdgeAndNoFurther(_ edge: PanelEdge) {
        let panel = PanelGeometry.slideOverFrame(edge, width: 640, minimumWidth: 440, in: laptop)
        let window = PanelGeometry.slideOverWindowFrame(panel: panel, edge: edge, in: laptop)
        #expect(window.contains(panel))
        #expect(window.width == panel.width + PanelGeometry.slideOverMargin)
        #expect(window.height == panel.height)
        if edge == .left {
            #expect(window.minX == laptop.minX)
            #expect(window.maxX == panel.maxX)
        } else {
            #expect(window.maxX == laptop.maxX)
            #expect(window.minX == panel.minX)
        }
        // The window that cuts the glass off never covers any of the display beside it.
        #expect(window.intersection(displayToTheLeft).width <= 0 || window.intersection(displayToTheLeft).isNull)
    }

    @Test(arguments: PanelEdge.allCases)
    func fullyOutTheGlassIsPastTheEdgeOfTheWindow(_ edge: PanelEdge) {
        let panel = PanelGeometry.slideOverFrame(edge, width: 640, minimumWidth: 440, in: laptop)
        let window = PanelGeometry.slideOverWindowFrame(panel: panel, edge: edge, in: laptop)
        let out = PanelGeometry.slidFrame(panel: panel, edge: edge, in: laptop, travel: 1)
        // Nothing of the glass is left inside the window, so nothing of it shows.
        #expect(window.intersection(out).width <= 0 || window.intersection(out).isNull)
        if edge == .left {
            #expect(out.maxX == laptop.minX)
        } else {
            #expect(out.minX == laptop.maxX)
        }
        #expect(out.size == panel.size)
        #expect(out.minY == panel.minY)
        #expect(PanelGeometry.slidFrame(panel: panel, edge: edge, in: laptop, travel: 0) == panel)
    }

    @Test func partwayTheGlassMovesTowardItsEdge() {
        let panel = PanelGeometry.slideOverFrame(.left, width: 640, minimumWidth: 440, in: laptop)
        let half = PanelGeometry.slidFrame(panel: panel, edge: .left, in: laptop, travel: 0.5)
        #expect(half.minX < panel.minX)
        #expect(half.minX == panel.minX - (panel.maxX - laptop.minX) / 2)
        let right = PanelGeometry.slideOverFrame(.right, width: 640, minimumWidth: 440, in: laptop)
        #expect(PanelGeometry.slidFrame(panel: right, edge: .right, in: laptop, travel: 0.5).minX > right.minX)
    }

    @Test func withTheDockOnThatSideTheGlassIsCutOffAtTheDock() {
        let panel = PanelGeometry.slideOverFrame(.left, width: 640, minimumWidth: 440, in: dockOnTheLeft)
        let window = PanelGeometry.slideOverWindowFrame(panel: panel, edge: .left, in: dockOnTheLeft)
        #expect(window.minX == dockOnTheLeft.minX)
        let out = PanelGeometry.slidFrame(panel: panel, edge: .left, in: dockOnTheLeft, travel: 1)
        #expect(out.maxX == dockOnTheLeft.minX)
    }

    @Test func aFollowerMovesByTheGlasssOffset() {
        let resting = CGRect(x: 10, y: 10, width: 640, height: 929)
        let frame = PanelMotionFrame(
            glass: resting.offsetBy(dx: -200, dy: 0), resting: resting, clip: laptop, alpha: 1, position: 0.6)
        #expect(frame.offset == -200)
    }
}
