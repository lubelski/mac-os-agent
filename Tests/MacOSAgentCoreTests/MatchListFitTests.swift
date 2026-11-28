import CoreGraphics
import Testing
@testable import MacOSAgentCore

/// How much of the list of matches shows. See `MatchListFit`.
@Suite struct MatchListFitTests {
    let row: CGFloat = 44
    let hairline: CGFloat = 1
    /// 0.4 of a 44 point row, in whole points.
    let part: CGFloat = 17

    private func fit(_ count: Int, room: CGFloat) -> MatchListFit? {
        MatchListFit.fit(rowCount: count, rowHeight: row, reachBeyondRows: hairline, roomBelow: room)
    }

    private func shown(_ rows: Int, _ part: CGFloat) -> MatchListFit {
        MatchListFit(rows: rows, partRowHeight: part)
    }

    @Test func thePartRowIsFourTenthsOfARowInWholePoints() {
        #expect(MatchListFit.partRowHeight(rowHeight: 44) == part)
        #expect(MatchListFit.partRowHeight(rowHeight: 50) == 20)
    }

    @Test func withRoomForEveryRowItShowsThemAll() {
        #expect(fit(7, room: 7 * 44 + 1) == shown(7, 0))
        #expect(fit(7, room: 2000) == shown(7, 0))
        #expect(fit(7, room: .greatestFiniteMagnitude) == shown(7, 0), "no overflow")
        #expect(fit(7, room: 2000)?.scrolls == false)
        #expect(fit(7, room: 2000)?.listHeight(rowHeight: row) == 7 * row)
    }

    @Test func withLessRoomItShowsTheWholeRowsThatFitAndAPartRow() {
        #expect(fit(7, room: 7 * 44) == shown(6, part), "one point short of the last row")
        #expect(fit(7, room: 200) == shown(4, part))
        #expect(fit(7, room: 3 * 44 + part + 1) == shown(3, part))
        #expect(fit(7, room: 3 * 44 + part) == shown(2, part), "a point short of three and a part")
        #expect(fit(7, room: 2 * 44 + part + 1) == shown(2, part), "2.4 rows, the minimum")
        #expect(fit(7, room: 200)?.scrolls == true)
        #expect(fit(7, room: 200)?.listHeight(rowHeight: row) == 4 * 44 + part)
    }

    /// Short of the minimum, which the panel makes room for wherever it can, the list is still
    /// shortened downward: to the rows that fit, down to one and a part. It never opens upward.
    @Test func shortOfTheMinimumItIsShortenedDownToOneRowAndAPart() {
        #expect(fit(7, room: 2 * 44 + part) == shown(1, part), "a point short of 2.4")
        #expect(fit(7, room: 2 * 44 + 1) == shown(1, part))
        #expect(fit(7, room: 44 + part + 1) == shown(1, part))
        #expect(fit(7, room: 44) == shown(1, part), "one row and a part, past the room")
        #expect(fit(7, room: 0) == shown(1, part))
        #expect(fit(7, room: -50) == shown(1, part))
        #expect(fit(7, room: 0)?.scrolls == true)
    }

    @Test func aShortListShowsWholeWhereItFits() {
        #expect(fit(1, room: 44 + 1) == shown(1, 0))
        #expect(fit(1, room: 44) == shown(1, 0), "a single row shows whole, past the room")
        #expect(fit(1, room: 0) == shown(1, 0))
        #expect(fit(2, room: 2 * 44 + 1) == shown(2, 0), "two whole rows need no part")
        #expect(fit(2, room: 2 * 44) == shown(1, part))
        #expect(fit(3, room: 3 * 44) == shown(2, part))
    }

    @Test func noRowsNoList() {
        #expect(fit(0, room: 2000) == nil)
    }

    @Test func thePartCanBeGiven() {
        #expect(MatchListFit.fit(rowCount: 7, rowHeight: 40, reachBeyondRows: 0, roomBelow: 100, partRow: 0.5) == shown(2, 20))
    }

    /// The least room the list is meant to have: every row up to two, and otherwise two rows
    /// and a part, or every row where that is less.
    @Test func theMinimumReachIsTwoRowsAndAPartOrEveryRowWhereLess() {
        func reach(_ count: Int) -> CGFloat {
            MatchListFit.minimumReach(rowCount: count, rowHeight: row, reachBeyondRows: hairline)
        }
        #expect(reach(0) == 0)
        #expect(reach(1) == row + hairline)
        #expect(reach(2) == 2 * row + hairline)
        #expect(reach(3) == 2 * 44 + part + 1)
        #expect(reach(7) == 2 * 44 + part + 1)
        #expect(MatchListFit.minimumReach(rowCount: 7, rowHeight: 44, reachBeyondRows: 0, minimumRows: 4) == 4 * 44 + part)
        // With exactly the minimum reach, the fit shows the minimum, and a point less shows less.
        for count in 2...7 {
            let shownRows = fit(count, room: reach(count))
            let expected = count <= 2 ? shown(count, 0) : shown(2, part)
            #expect(shownRows == expected, "\(count) rows")
            #expect(fit(count, room: reach(count) - 1) != expected, "\(count) rows, a point short")
        }
    }
}

/// Where the panel goes so the list has its room below. See `MatchListRoom`.
@Suite struct MatchListRoomTests {
    let visible = CGRect(x: 0, y: 40, width: 1512, height: 900)
    let margin: CGFloat = 8
    let needed: CGFloat = 106
    let minimumHeight: CGFloat = 300

    private func frame(_ panel: CGRect, _ layout: MatchListRoom.Layout, in visible: CGRect? = nil) -> CGRect {
        MatchListRoom.frame(
            panel: panel, visible: visible ?? self.visible, layout: layout, needed: needed, margin: margin,
            minimumHeight: minimumHeight)
    }

    @Test func theRoomBelowIsLessTheMarginAndNeverNegative() {
        #expect(MatchListRoom.roomBelow(panel: CGRect(x: 0, y: 240, width: 640, height: 560), visible: visible, margin: 8) == 192)
        #expect(MatchListRoom.roomBelow(panel: CGRect(x: 0, y: 40, width: 640, height: 560), visible: visible, margin: 8) == 0)
        #expect(MatchListRoom.roomBelow(panel: CGRect(x: 0, y: 0, width: 640, height: 560), visible: visible, margin: 8) == 0)
    }

    @Test func withTheRoomAlreadyThereNothingMoves() {
        let panel = CGRect(x: 300, y: 40 + margin + needed, width: 640, height: 560)
        #expect(frame(panel, .floating) == panel)
        #expect(frame(panel.offsetBy(dx: 0, dy: 200), .floating) == panel.offsetBy(dx: 0, dy: 200))
        #expect(frame(panel, .pinnedToEdge) == panel)
    }

    /// A centered panel at the very bottom moves up by just the room it lacks, margin and all,
    /// and keeps its size.
    @Test func aFloatingPanelMovesUpJustFarEnough() {
        let bottom = CGRect(x: 300, y: 40, width: 640, height: 560)
        let moved = frame(bottom, .floating)
        #expect(moved == bottom.offsetBy(dx: 0, dy: needed + margin))
        #expect(MatchListRoom.roomBelow(panel: moved, visible: visible, margin: margin) == needed)
        let near = bottom.offsetBy(dx: 0, dy: 50)
        #expect(frame(near, .floating) == bottom.offsetBy(dx: 0, dy: needed + margin), "the same place from nearer")
        let past = bottom.offsetBy(dx: 0, dy: -30)
        #expect(frame(past, .floating).minY == 40 + margin + needed, "from partly off the bottom too")
    }

    /// Its top never goes past the top of the visible area, so a tall panel moves only as far as
    /// that allows, and the list is shortened for the rest.
    @Test func aFloatingPanelNeverMovesPastTheTop() {
        let tall = CGRect(x: 300, y: 40, width: 640, height: 850)
        let moved = frame(tall, .floating)
        #expect(moved.maxY == visible.maxY)
        #expect(moved.size == tall.size)
        #expect(MatchListRoom.roomBelow(panel: moved, visible: visible, margin: margin) == 42)
        let full = CGRect(x: 300, y: 40, width: 640, height: 900)
        #expect(frame(full, .floating) == full, "no room to make")
    }

    /// Slide over is the screen's full height, so its bottom rises and its top stays.
    @Test func aPinnedPanelRisesFromTheBottom() {
        let full = CGRect(x: 1112, y: 40, width: 400, height: 900)
        let shortened = frame(full, .pinnedToEdge)
        #expect(shortened.maxY == full.maxY, "the top stays")
        #expect(shortened.minX == full.minX)
        #expect(shortened.width == full.width)
        #expect(shortened.minY == 40 + needed + margin)
        #expect(MatchListRoom.roomBelow(panel: shortened, visible: visible, margin: margin) == needed)
    }

    /// On a screen too short for both, a pinned panel keeps its least height and the list gets
    /// what is left.
    @Test func aPinnedPanelIsNeverShorterThanItsMinimum() {
        let short = CGRect(x: 0, y: 40, width: 1024, height: 360)
        let screen = CGRect(x: 0, y: 40, width: 1024, height: 360)
        let shortened = frame(short, .pinnedToEdge, in: screen)
        #expect(shortened.height == minimumHeight)
        #expect(shortened.maxY == short.maxY)
        #expect(MatchListRoom.roomBelow(panel: shortened, visible: screen, margin: margin) == 52)
        let tiny = CGRect(x: 0, y: 40, width: 1024, height: 280)
        #expect(frame(tiny, .pinnedToEdge, in: tiny) == tiny, "already shorter than the minimum")
    }
}

/// Where a shortened list is scrolled to as the highlight moves. See `MatchListScroll`.
@Suite struct MatchListScrollTests {
    let row: CGFloat = 44
    let part: CGFloat = 17

    private func walk(rows count: Int, whole: Int, from start: Int = 0, by step: Int, offset: CGFloat = 0) -> [(Int, CGFloat)] {
        let viewport = row * CGFloat(whole) + part
        var offset = offset
        var steps: [(Int, CGFloat)] = []
        var index = start
        while index >= 0, index < count {
            offset = MatchListScroll.offset(showing: index, from: offset, rowCount: count, rowHeight: row, viewport: viewport, margin: part)
            steps.append((index, offset))
            index += step
        }
        return steps
    }

    @Test(arguments: [(7, 2), (7, 3), (7, 6), (9, 2), (3, 2)])
    func arrowingDownAndUpKeepsTheHighlightWhole(_ count: Int, _ whole: Int) {
        let viewport = row * CGFloat(whole) + part
        let down = walk(rows: count, whole: whole, by: 1)
        let up = walk(rows: count, whole: whole, from: count - 1, by: -1, offset: down.last?.1 ?? 0)
        for (index, offset) in down + up {
            #expect(MatchListScroll.isWhole(index, offset: offset, rowHeight: row, viewport: viewport), "row \(index) at \(offset)")
            #expect(offset >= 0 && offset <= CGFloat(count) * row - viewport)
        }
    }

    /// Moving down, the rows below show a part row's worth of themselves until the last row.
    @Test func movingDownAPartRowShowsBelowUntilTheEnd() {
        let viewport = 2 * row + part
        let steps = walk(rows: 7, whole: 2, by: 1)
        #expect(steps.map(\.1) == [0, 0, 44, 88, 132, 176, 7 * 44 - viewport])
        // From the third row on, the highlighted row is the last whole one, with 17 of the next.
        for (index, offset) in steps where index >= 2 && index < 6 {
            #expect(offset + viewport == CGFloat(index + 1) * row + part)
        }
        #expect(steps.last?.1 == 7 * 44 - viewport, "at the end, the part row is at the top")
    }

    /// Moving back up from the end, the list stays put while the highlight is in view, then keeps
    /// a part row of the rows above showing.
    @Test func movingUpAPartRowShowsAbove() {
        let end = 7 * row - (2 * row + part)
        let steps = walk(rows: 7, whole: 2, from: 6, by: -1, offset: end)
        #expect(steps[0].1 == end)
        #expect(steps[1].1 == end, "row 5 is whole, with part of row 4 above")
        #expect(steps[2].1 == 4 * row - part)
        #expect(steps.last?.1 == 0, "the first row goes flush to the top")
    }

    /// Wherever the trackpad left the list, the arrows scroll only as far as the highlight needs.
    @Test func itStartsFromWhereTheTrackpadLeftIt() {
        let viewport = 2 * row + part
        // Scrolled to the end with the highlight on the first row: Down brings row 1 back.
        let end = 7 * row - viewport
        let back = MatchListScroll.offset(showing: 1, from: end, rowCount: 7, rowHeight: row, viewport: viewport, margin: part)
        #expect(back == row - part)
        // Scrolled a little, with the highlight still whole: nothing moves.
        #expect(MatchListScroll.offset(showing: 2, from: 60, rowCount: 7, rowHeight: row, viewport: viewport, margin: part) == 60)
        // A scroll past either end is brought back inside it.
        #expect(MatchListScroll.offset(showing: 0, from: -30, rowCount: 7, rowHeight: row, viewport: viewport, margin: part) == 0)
        #expect(MatchListScroll.offset(showing: 6, from: 900, rowCount: 7, rowHeight: row, viewport: viewport, margin: part) == end)
    }

    @Test func aListThatFitsNeverScrolls() {
        for index in 0..<4 {
            #expect(MatchListScroll.offset(showing: index, from: 0, rowCount: 4, rowHeight: row, viewport: 4 * row, margin: 0) == 0)
        }
    }

    @Test func aRowOutsideTheListLeavesItWhereItIs() {
        #expect(MatchListScroll.offset(showing: 9, from: 44, rowCount: 7, rowHeight: row, viewport: 105, margin: part) == 44)
    }
}

/// The panel's way to where it moves for the list. See `MatchListRoom.Motion`.
@Suite struct MatchListRoomMotionTests {
    @Test func itTakesASlidesTimeAndEndsExactlyThere() {
        let start = CGRect(x: 300, y: 40, width: 640, height: 560)
        let end = start.offsetBy(dx: 0, dy: 114)
        var motion = MatchListRoom.Motion(from: start, to: end)
        #expect(motion.frame == start)
        #expect(MatchListRoom.Motion.duration == PanelSlide.slideDuration)
        var last = start.minY
        var steps = 0
        while !motion.isFinished {
            motion.advance(by: 1.0 / 60)
            steps += 1
            #expect(motion.frame.minY >= last, "it only moves one way")
            #expect(motion.frame.size == start.size, "a raise keeps the size")
            #expect(motion.frame.minY == motion.frame.minY.rounded(), "whole points")
            last = motion.frame.minY
        }
        #expect((18...19).contains(steps), "0.3 seconds at 60 frames a second")
        #expect(motion.frame == end)
    }

    @Test func itEasesOutSoMostOfTheWayIsEarly() {
        let start = CGRect(x: 0, y: 0, width: 400, height: 900)
        let end = CGRect(x: 0, y: 114, width: 400, height: 786)
        var motion = MatchListRoom.Motion(from: start, to: end)
        motion.advance(by: MatchListRoom.Motion.duration / 3)
        #expect(motion.frame.minY > 114 / 2, "past halfway a third of the way in")
        #expect(motion.frame.maxY == 900, "a pinned panel's top stays")
        motion.advance(by: 10)
        #expect(motion.isFinished)
        #expect(motion.frame == end)
    }
}
