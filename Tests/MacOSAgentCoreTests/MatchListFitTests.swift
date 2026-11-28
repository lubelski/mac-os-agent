import CoreGraphics
import Testing
@testable import MacOSAgentCore

/// Which way the list of matches opens, and how much of it shows. See `MatchListFit`.
@Suite struct MatchListFitTests {
    let row: CGFloat = 44
    let hairline: CGFloat = 1
    /// 0.4 of a 44 point row, in whole points.
    let part: CGFloat = 17

    private func fit(_ count: Int, room: CGFloat) -> MatchListFit? {
        MatchListFit.fit(rowCount: count, rowHeight: row, reachBeyondRows: hairline, roomBelow: room)
    }

    @Test func thePartRowIsFourTenthsOfARowInWholePoints() {
        #expect(MatchListFit.partRowHeight(rowHeight: 44) == part)
        #expect(MatchListFit.partRowHeight(rowHeight: 50) == 20)
    }

    @Test func withRoomForEveryRowItOpensDownwardWhole() {
        #expect(fit(7, room: 7 * 44 + 1) == .below(rows: 7, partRowHeight: 0))
        #expect(fit(7, room: 2000) == .below(rows: 7, partRowHeight: 0))
        #expect(fit(7, room: .greatestFiniteMagnitude) == .below(rows: 7, partRowHeight: 0), "no overflow")
        #expect(fit(7, room: 2000)?.scrolls == false)
        #expect(fit(7, room: 2000)?.listHeight(rowHeight: row) == 7 * row)
    }

    @Test func withLessRoomItShowsTheWholeRowsThatFitAndAPartRow() {
        #expect(fit(7, room: 7 * 44) == .below(rows: 6, partRowHeight: part), "one point short of the last row")
        #expect(fit(7, room: 200) == .below(rows: 4, partRowHeight: part))
        #expect(fit(7, room: 3 * 44 + part + 1) == .below(rows: 3, partRowHeight: part))
        #expect(fit(7, room: 3 * 44 + part) == .below(rows: 2, partRowHeight: part), "a point short of three and a part")
        #expect(fit(7, room: 200)?.scrolls == true)
        #expect(fit(7, room: 200)?.listHeight(rowHeight: row) == 4 * 44 + part)
    }

    @Test func itIsNeverShortenedBelowTwoRowsAndAPart() {
        #expect(fit(7, room: 2 * 44 + part + 1) == .below(rows: 2, partRowHeight: part), "2.4 rows, the fewest")
        #expect(fit(7, room: 2 * 44 + part) == .above, "a point short of it")
        #expect(fit(7, room: 2 * 44 + 1) == .above, "room for two whole rows is not enough")
        #expect(fit(7, room: 44 + 1) == .above)
        #expect(fit(7, room: 0) == .above, "slide over, or the very bottom of the screen")
        #expect(fit(7, room: -50) == .above)
        #expect(MatchListFit.above.scrolls == false)
        #expect(MatchListFit.above.listHeight(rowHeight: row) == 0)
    }

    @Test func aShortListShowsWholeWhereItFits() {
        #expect(fit(1, room: 44 + 1) == .below(rows: 1, partRowHeight: 0))
        #expect(fit(1, room: 44) == .above)
        #expect(fit(2, room: 2 * 44 + 1) == .below(rows: 2, partRowHeight: 0), "two whole rows need no part")
        #expect(fit(2, room: 2 * 44) == .above, "and two shortened would be less than 2.4")
        #expect(fit(3, room: 3 * 44) == .below(rows: 2, partRowHeight: part))
    }

    @Test func noRowsNoList() {
        #expect(fit(0, room: 2000) == nil)
    }

    @Test func theMinimumAndThePartCanBeGiven() {
        #expect(MatchListFit.fit(rowCount: 7, rowHeight: 44, reachBeyondRows: 1, roomBelow: 44 + 18, minimumRows: 1) == .below(rows: 1, partRowHeight: 17))
        #expect(MatchListFit.fit(rowCount: 7, rowHeight: 44, reachBeyondRows: 1, roomBelow: 4 * 44, minimumRows: 4) == .above)
        #expect(MatchListFit.fit(rowCount: 7, rowHeight: 40, reachBeyondRows: 0, roomBelow: 100, partRow: 0.5) == .below(rows: 2, partRowHeight: 20))
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
