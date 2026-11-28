import CoreGraphics
import Testing
@testable import MacOSAgentCore

/// Which way the list of matches opens, and how many rows it shows. See `MatchListFit`.
@Suite struct MatchListFitTests {
    let row: CGFloat = 44
    let hairline: CGFloat = 1

    private func fit(_ count: Int, room: CGFloat) -> MatchListFit? {
        MatchListFit.fit(rowCount: count, rowHeight: row, reachBeyondRows: hairline, roomBelow: room)
    }

    @Test func withRoomForEveryRowItOpensDownwardWhole() {
        #expect(fit(7, room: 7 * 44 + 1) == .below(rows: 7))
        #expect(fit(7, room: 2000) == .below(rows: 7))
        #expect(fit(7, room: .greatestFiniteMagnitude) == .below(rows: 7), "no overflow")
        #expect(fit(7, room: 2000)?.scrolls(rowCount: 7) == false)
    }

    @Test func withLessRoomItOpensDownwardShortenedAndScrolls() {
        #expect(fit(7, room: 7 * 44) == .below(rows: 6), "one point short of the last row")
        #expect(fit(7, room: 3 * 44 + 1) == .below(rows: 3))
        #expect(fit(7, room: 3 * 44 + 40) == .below(rows: 3), "a part row does not count")
        #expect(fit(7, room: 3 * 44 + 1)?.scrolls(rowCount: 7) == true)
    }

    @Test func itIsNeverShortenedBelowTwoRows() {
        #expect(fit(7, room: 2 * 44 + 1) == .below(rows: 2))
        #expect(fit(7, room: 2 * 44) == .above, "room for one row and a bit")
        #expect(fit(7, room: 44 + 1) == .above)
        #expect(fit(7, room: 0) == .above, "slide over, or the very bottom of the screen")
        #expect(fit(7, room: -50) == .above)
        #expect(MatchListFit.above.scrolls(rowCount: 7) == false)
    }

    @Test func aListOfOneRowNeedsRoomForOne() {
        #expect(fit(1, room: 44 + 1) == .below(rows: 1))
        #expect(fit(1, room: 44) == .above)
        #expect(fit(2, room: 2 * 44 + 1) == .below(rows: 2))
    }

    @Test func noRowsNoList() {
        #expect(fit(0, room: 2000) == nil)
    }

    @Test func theMinimumCanBeGiven() {
        #expect(MatchListFit.fit(rowCount: 7, rowHeight: 44, reachBeyondRows: 1, roomBelow: 44 + 1, minimumRows: 1) == .below(rows: 1))
        #expect(MatchListFit.fit(rowCount: 7, rowHeight: 44, reachBeyondRows: 1, roomBelow: 4 * 44, minimumRows: 4) == .above)
    }
}
