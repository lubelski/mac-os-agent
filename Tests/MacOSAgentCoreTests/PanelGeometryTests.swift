import CoreGraphics
import Testing
@testable import MacOSAgentCore

@Suite struct PanelGeometryTests {
    /// A 1512 by 982 laptop screen, less a 33 point menu bar, with no Dock showing.
    let laptop = CGRect(x: 0, y: 0, width: 1512, height: 949)
    /// A second display to the right of it.
    let external = CGRect(x: 1512, y: -200, width: 2560, height: 1415)
    let minimum = CGSize(width: 440, height: 300)

    @Test func theDefaultFrameIsCenteredAcrossTheScreenBelowTheMenuBar() {
        let frame = PanelGeometry.defaultFrame(size: CGSize(width: 640, height: 560), in: laptop)
        #expect(frame.size == CGSize(width: 640, height: 560))
        #expect(frame.midX == laptop.midX)
        #expect(frame.maxY < laptop.maxY)
        #expect(frame.minY >= laptop.minY + PanelGeometry.screenMargin)
    }

    @Test func theDefaultFrameShrinksToFitASmallScreen() {
        let small = CGRect(x: 0, y: 0, width: 600, height: 400)
        let frame = PanelGeometry.defaultFrame(size: CGSize(width: 640, height: 560), in: small)
        #expect(frame.width == 560)
        #expect(frame.height == 360)
        #expect(small.contains(frame))
    }

    @Test func theDefaultFrameIsOnTheScreenItIsGiven() {
        let frame = PanelGeometry.defaultFrame(size: CGSize(width: 640, height: 560), in: external)
        #expect(external.contains(frame))
        #expect(frame.midX == external.midX)
    }

    @Test(arguments: PanelEdge.allCases)
    func aSlideOverPanelIsFlushAgainstItsEdgeAtTheFullHeight(_ edge: PanelEdge) {
        let frame = PanelGeometry.slideOverFrame(edge, width: 640, minimumWidth: minimum.width, in: laptop)
        #expect(frame.width == 640)
        #expect(frame.minY == laptop.minY)
        #expect(frame.maxY == laptop.maxY)
        if edge == .left {
            #expect(frame.minX == laptop.minX)
        } else {
            #expect(frame.maxX == laptop.maxX)
        }
        #expect(PanelGeometry.isInSlideOver(frame, at: edge, in: laptop))
        #expect(!PanelGeometry.isInSlideOver(frame, at: edge.opposite, in: laptop))
    }

    /// With the Dock on a side, the visible area stops at the Dock, and the panel is flush
    /// against the Dock rather than under it.
    @Test(arguments: PanelEdge.allCases)
    func aSlideOverPanelIsFlushAgainstTheDockOnItsSide(_ edge: PanelEdge) {
        // The laptop with a 70 point Dock on the side of the panel's edge.
        let visible = edge == .left
            ? CGRect(x: 70, y: 0, width: 1442, height: 949)
            : CGRect(x: 0, y: 0, width: 1442, height: 949)
        let frame = PanelGeometry.slideOverFrame(edge, width: 640, minimumWidth: minimum.width, in: visible)
        if edge == .left {
            #expect(frame.minX == 70)
        } else {
            #expect(frame.maxX == 1442)
        }
        #expect(frame.minY == visible.minY && frame.maxY == visible.maxY)
        #expect(PanelGeometry.flushEdges(of: frame, in: visible) == [edge])
        #expect(PanelGeometry.isInSlideOver(frame, at: edge, in: visible))
    }

    @Test(arguments: PanelEdge.allCases)
    func onlyTheSideAgainstTheScreensEdgeIsSquare(_ edge: PanelEdge) {
        let frame = PanelGeometry.slideOverFrame(edge, width: 640, minimumWidth: minimum.width, in: laptop)
        #expect(PanelGeometry.flushEdges(of: frame, in: laptop) == [edge])
    }

    /// Moved off its edge by a drag, the panel has all four rounded corners again.
    @Test(arguments: PanelEdge.allCases)
    func theCornersComeBackWhenThePanelMovesOffTheEdge(_ edge: PanelEdge) {
        let frame = PanelGeometry.slideOverFrame(edge, width: 640, minimumWidth: minimum.width, in: laptop)
        let inward: CGFloat = edge == .left ? 24 : -24
        #expect(PanelGeometry.flushEdges(of: frame.offsetBy(dx: inward, dy: 0), in: laptop).isEmpty)
        // Partly past the edge is not flush either.
        #expect(PanelGeometry.flushEdges(of: frame.offsetBy(dx: -inward, dy: 0), in: laptop).isEmpty)
        // Within the tolerance it still counts as flush, so rounding never makes it flicker.
        #expect(PanelGeometry.flushEdges(of: frame.offsetBy(dx: inward / 48, dy: 0), in: laptop) == [edge])
        // Moved only up or down, the side is still against the edge.
        #expect(PanelGeometry.flushEdges(of: frame.offsetBy(dx: 0, dy: -40), in: laptop) == [edge])
    }

    @Test func aCenteredPanelHasNoSquareSide() {
        let frame = PanelGeometry.defaultFrame(size: CGSize(width: 640, height: 560), in: laptop)
        #expect(PanelGeometry.flushEdges(of: frame, in: laptop).isEmpty)
        // A panel on another screen is not flush against this one's edges.
        let left = PanelGeometry.slideOverFrame(.left, width: 640, minimumWidth: minimum.width, in: external)
        #expect(PanelGeometry.flushEdges(of: left.offsetBy(dx: 0, dy: 2000), in: external).isEmpty)
    }

    @Test func eachPresetsFrameComesFromOnePlace() {
        let size = CGSize(width: 640, height: 560)
        #expect(PanelGeometry.presetFrame(.centered, centeredSize: size, slideOverWidth: 500, minimumWidth: 440, in: laptop)
            == PanelGeometry.defaultFrame(size: size, in: laptop))
        for edge in PanelEdge.allCases {
            #expect(PanelGeometry.presetFrame(
                PanelPreset(slideOver: edge), centeredSize: size, slideOverWidth: 500, minimumWidth: 440, in: laptop)
                == PanelGeometry.slideOverFrame(edge, width: 500, minimumWidth: 440, in: laptop))
        }
    }

    @Test func aSlideOverPanelIsAtMostHalfTheScreenAndAtLeastTheMinimum() {
        let wide = PanelGeometry.slideOverFrame(.left, width: 1200, minimumWidth: minimum.width, in: laptop)
        #expect(wide.width == 756)
        let narrow = PanelGeometry.slideOverFrame(.right, width: 200, minimumWidth: minimum.width, in: laptop)
        #expect(narrow.width == 440)
    }

    @Test func aSlideOverPanelNeverOverflowsAScreenNarrowerThanTheMinimum() {
        let tiny = CGRect(x: 0, y: 0, width: 400, height: 300)
        let frame = PanelGeometry.slideOverFrame(.right, width: 640, minimumWidth: minimum.width, in: tiny)
        #expect(frame.width == 400)
        #expect(tiny.contains(frame))
    }

    @Test func slideOverUsesTheScreensOwnOrigin() {
        let frame = PanelGeometry.slideOverFrame(.left, width: 640, minimumWidth: minimum.width, in: external)
        #expect(frame.minX == external.minX)
        #expect(frame.minY == external.minY)
    }

    @Test func changingTheFreeEdgeKeepsThePanelEdgeed() {
        let left = PanelGeometry.slideOverFrame(.left, width: 640, minimumWidth: minimum.width, in: laptop)
        var wider = left
        wider.size.width += 80
        #expect(PanelGeometry.isInSlideOver(wider, at: .left, in: laptop))

        let right = PanelGeometry.slideOverFrame(.right, width: 640, minimumWidth: minimum.width, in: laptop)
        // Resizing from the left edge moves the origin and keeps the right edge.
        let resized = CGRect(x: right.minX - 80, y: right.minY, width: right.width + 80, height: right.height)
        #expect(PanelGeometry.isInSlideOver(resized, at: .right, in: laptop))
    }

    @Test func movingThePanelTakesItOutOfSlideOver() {
        let inPlace = PanelGeometry.slideOverFrame(.left, width: 640, minimumWidth: minimum.width, in: laptop)
        #expect(!PanelGeometry.isInSlideOver(inPlace.offsetBy(dx: 30, dy: 0), at: .left, in: laptop))
        #expect(!PanelGeometry.isInSlideOver(inPlace.offsetBy(dx: 0, dy: -30), at: .left, in: laptop))
        // The same frame on a screen that changed size is no longer in slide over there.
        let smaller = CGRect(x: 0, y: 0, width: 1280, height: 767)
        #expect(!PanelGeometry.isInSlideOver(inPlace, at: .left, in: smaller))
    }

    @Test func aFrameThatFitsIsNotMoved() {
        let frame = CGRect(x: 100, y: 100, width: 640, height: 560)
        #expect(PanelGeometry.clamped(frame, minimumSize: minimum, in: laptop) == frame)
    }

    @Test func aFrameOffTheScreenIsMovedBackInside() {
        let frame = CGRect(x: 3000, y: -900, width: 640, height: 560)
        let clamped = PanelGeometry.clamped(frame, minimumSize: minimum, in: laptop)
        #expect(clamped.size == frame.size)
        #expect(laptop.insetBy(dx: PanelGeometry.screenMargin, dy: PanelGeometry.screenMargin).contains(clamped))
    }

    @Test func aFrameTooBigIsShrunkButNotBelowTheMinimum() {
        let small = CGRect(x: 0, y: 0, width: 800, height: 500)
        let clamped = PanelGeometry.clamped(CGRect(x: -50, y: -50, width: 2000, height: 1400), minimumSize: minimum, in: small)
        #expect(clamped == CGRect(x: 20, y: 20, width: 760, height: 460))

        let tiny = CGRect(x: 0, y: 0, width: 420, height: 280)
        let squeezed = PanelGeometry.clamped(CGRect(x: 0, y: 0, width: 640, height: 560), minimumSize: minimum, in: tiny)
        #expect(squeezed.size == CGSize(width: 420, height: 280))
        #expect(squeezed.origin == .zero)
    }

    @Test func aFrameOnAScreenThatIsGoneIsUnreachable() {
        let onExternal = CGRect(x: 2200, y: 300, width: 640, height: 560)
        #expect(PanelGeometry.isReachable(onExternal, on: [laptop, external]))
        #expect(!PanelGeometry.isReachable(onExternal, on: [laptop]))
        // A sliver along the edge of the laptop screen does not count either.
        #expect(!PanelGeometry.isReachable(CGRect(x: 1490, y: 300, width: 640, height: 560), on: [laptop]))
    }

    @Test func theScreenWithTheLargestPartOfTheFrameIsItsScreen() {
        let screens = [laptop, external]
        #expect(PanelGeometry.screenIndex(for: CGRect(x: 1400, y: 100, width: 640, height: 560), among: screens) == 1)
        #expect(PanelGeometry.screenIndex(for: CGRect(x: 1000, y: 100, width: 640, height: 560), among: screens) == 0)
        #expect(PanelGeometry.screenIndex(for: CGRect(x: -2000, y: 100, width: 640, height: 560), among: screens) == nil)
    }

    @Test func theScreenUnderThePointIsFound() {
        let screens = [laptop, external]
        #expect(PanelGeometry.screenIndex(containing: CGPoint(x: 20, y: 20), among: screens) == 0)
        #expect(PanelGeometry.screenIndex(containing: CGPoint(x: 2000, y: 0), among: screens) == 1)
        #expect(PanelGeometry.screenIndex(containing: CGPoint(x: 100, y: 949), among: screens) == 0)
        #expect(PanelGeometry.screenIndex(containing: CGPoint(x: -5, y: 20), among: screens) == nil)
    }
}

@Suite struct BesideFrameTests {
    private let visible = CGRect(x: 0, y: 0, width: 2560, height: 1415)
    private let size = CGSize(width: 480, height: 500)

    @Test func itGoesToTheRightOfThePanelWithItsTopLinedUp() {
        let panel = CGRect(x: 600, y: 500, width: 640, height: 560)
        let frame = PanelGeometry.besideFrame(size: size, beside: panel, in: visible)
        #expect(frame == CGRect(x: 1256, y: 560, width: 480, height: 500))
        #expect(!frame.intersects(panel))
    }

    @Test func itGoesToTheLeftWhenTheRightHasNoRoom() {
        let panel = CGRect(x: 1900, y: 500, width: 640, height: 560)
        let frame = PanelGeometry.besideFrame(size: size, beside: panel, in: visible)
        #expect(frame.maxX == panel.minX - PanelGeometry.besideGap)
        #expect(!frame.intersects(panel))
    }

    @Test func onANarrowScreenItTakesTheRoomierSideAndStaysOnScreen() {
        let laptop = CGRect(x: 0, y: 0, width: 1512, height: 949)
        let panel = CGRect(x: 380, y: 300, width: 640, height: 560)
        let frame = PanelGeometry.besideFrame(size: size, beside: panel, in: laptop)
        #expect(frame.maxX == laptop.maxX - PanelGeometry.screenMargin)
        #expect(laptop.insetBy(dx: PanelGeometry.screenMargin, dy: PanelGeometry.screenMargin).contains(frame))
    }

    @Test func aSlideOverPanelAtTheLeftHasItBesideItsFreeEdge() {
        let panel = PanelGeometry.slideOverFrame(.left, width: 640, minimumWidth: 440, in: visible)
        let frame = PanelGeometry.besideFrame(size: size, beside: panel, in: visible)
        #expect(frame.minX == panel.maxX + PanelGeometry.besideGap)
        #expect(frame.maxY == visible.maxY - PanelGeometry.screenMargin)
    }

    /// Flush against the right edge, the panel has no room on its right, so the incognito
    /// window opens to its left, inside the screen's margin.
    @Test func aSlideOverPanelAtTheRightHasItToTheLeft() {
        let panel = PanelGeometry.slideOverFrame(.right, width: 640, minimumWidth: 440, in: visible)
        let frame = PanelGeometry.besideFrame(size: size, beside: panel, in: visible)
        #expect(frame.maxX == panel.minX - PanelGeometry.besideGap)
        #expect(!frame.intersects(panel))
        #expect(visible.insetBy(dx: PanelGeometry.screenMargin, dy: PanelGeometry.screenMargin).contains(frame))
    }
}
