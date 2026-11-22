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

    @Test(arguments: PanelDock.allCases)
    func aDockedPanelIsFullHeightAgainstItsEdgeWithAMargin(_ dock: PanelDock) {
        let frame = PanelGeometry.dockedFrame(dock, width: 640, minimumWidth: minimum.width, in: laptop)
        let margin = PanelGeometry.dockMargin
        #expect(frame.width == 640)
        #expect(frame.minY == laptop.minY + margin)
        #expect(frame.maxY == laptop.maxY - margin)
        if dock == .left {
            #expect(frame.minX == laptop.minX + margin)
        } else {
            #expect(frame.maxX == laptop.maxX - margin)
        }
        #expect(PanelGeometry.isDocked(frame, at: dock, in: laptop))
        #expect(!PanelGeometry.isDocked(frame, at: dock == .left ? .right : .left, in: laptop))
    }

    @Test func aDockedPanelIsAtMostHalfTheScreenAndAtLeastTheMinimum() {
        let wide = PanelGeometry.dockedFrame(.left, width: 1200, minimumWidth: minimum.width, in: laptop)
        #expect(wide.width == 756)
        let narrow = PanelGeometry.dockedFrame(.right, width: 200, minimumWidth: minimum.width, in: laptop)
        #expect(narrow.width == 440)
    }

    @Test func aDockedPanelNeverOverflowsAScreenNarrowerThanTheMinimum() {
        let tiny = CGRect(x: 0, y: 0, width: 400, height: 300)
        let frame = PanelGeometry.dockedFrame(.right, width: 640, minimumWidth: minimum.width, in: tiny)
        #expect(frame.width == 380)
        #expect(tiny.contains(frame))
    }

    @Test func dockingUsesTheScreensOwnOrigin() {
        let frame = PanelGeometry.dockedFrame(.left, width: 640, minimumWidth: minimum.width, in: external)
        #expect(frame.minX == external.minX + PanelGeometry.dockMargin)
        #expect(frame.minY == external.minY + PanelGeometry.dockMargin)
    }

    @Test func changingTheFreeEdgeKeepsThePanelDocked() {
        let left = PanelGeometry.dockedFrame(.left, width: 640, minimumWidth: minimum.width, in: laptop)
        var wider = left
        wider.size.width += 80
        #expect(PanelGeometry.isDocked(wider, at: .left, in: laptop))

        let right = PanelGeometry.dockedFrame(.right, width: 640, minimumWidth: minimum.width, in: laptop)
        // Resizing from the left edge moves the origin and keeps the right edge.
        let resized = CGRect(x: right.minX - 80, y: right.minY, width: right.width + 80, height: right.height)
        #expect(PanelGeometry.isDocked(resized, at: .right, in: laptop))
    }

    @Test func movingThePanelUndocksIt() {
        let docked = PanelGeometry.dockedFrame(.left, width: 640, minimumWidth: minimum.width, in: laptop)
        #expect(!PanelGeometry.isDocked(docked.offsetBy(dx: 30, dy: 0), at: .left, in: laptop))
        #expect(!PanelGeometry.isDocked(docked.offsetBy(dx: 0, dy: -30), at: .left, in: laptop))
        // The same frame on a screen that changed size is no longer docked there.
        let smaller = CGRect(x: 0, y: 0, width: 1280, height: 767)
        #expect(!PanelGeometry.isDocked(docked, at: .left, in: smaller))
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
