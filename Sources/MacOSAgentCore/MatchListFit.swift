import CoreGraphics
import Foundation

/// How much of the list of matches under the text field shows at once. The list always opens
/// downward, past the panel's bottom edge (the owner's direction, 2026-11-27). The panel with
/// bars' match card uses it.
///
/// With room below for every row it shows them all. With less, it is shortened to the whole rows
/// that fit and a part row, `partRow` of a row cut off at its bottom edge, which shows that more
/// rows are below. The shortened list scrolls.
///
/// A shortened list is meant to be at least `minimumRows` whole rows and the part row, 2.4 rows
/// (the owner's suggestion, 2026-11-27). Where the room below is less than that, the panel makes
/// room first, by `MatchListRoom`, so the list gets its minimum. Only where even that cannot make
/// enough room, as on a very short screen, is the list shortened further: to the whole rows that
/// fit and the part row, down to one row and the part, which then reaches past the room. It
/// never opens upward.
public struct MatchListFit: Equatable, Sendable {
    /// The whole rows that show.
    public var rows: Int
    /// How much of the next row shows after them. 0 when every row shows.
    public var partRowHeight: CGFloat

    public init(rows: Int, partRowHeight: CGFloat) {
        self.rows = rows
        self.partRowHeight = partRowHeight
    }

    /// The fewest whole rows a shortened list is meant to show, before its part row.
    public static let minimumRows = 2
    /// How much of a row the part row at a shortened list's edge shows.
    public static let partRow: CGFloat = 0.4

    /// The part row's height for rows of `rowHeight`, in whole points, so the list's edge falls on
    /// a point.
    public static func partRowHeight(rowHeight: CGFloat, partRow: CGFloat = partRow) -> CGFloat {
        max(0, (rowHeight * partRow).rounded(.down))
    }

    /// - Parameters:
    ///   - rowCount: the rows the list has, at most as many as it ever shows at once.
    ///   - rowHeight: each row's height.
    ///   - reachBeyondRows: how far the list reaches below the room's top edge besides its rows,
    ///     such as a hairline.
    ///   - roomBelow: the room below for the list.
    /// - Returns: nil when there are no rows.
    public static func fit(
        rowCount: Int, rowHeight: CGFloat, reachBeyondRows: CGFloat, roomBelow: CGFloat, partRow: CGFloat = partRow
    ) -> MatchListFit? {
        guard rowCount > 0, rowHeight > 0 else { return nil }
        let room = roomBelow - reachBeyondRows
        // Compared as a float first, so a room of any size never overflows an Int.
        if room / rowHeight >= CGFloat(rowCount) { return MatchListFit(rows: rowCount, partRowHeight: 0) }
        // A single row has nothing past it to hint at, so it shows whole, past the room.
        guard rowCount > 1 else { return MatchListFit(rows: 1, partRowHeight: 0) }
        let part = partRowHeight(rowHeight: rowHeight, partRow: partRow)
        // Below `rowCount` here, since the room is short of every row.
        let whole = ((room - part) / rowHeight).rounded(.down)
        return MatchListFit(rows: Int(max(1, whole)), partRowHeight: part)
    }

    /// The room below a list of `rowCount` rows needs for the least of it that is meant to show:
    /// every row when that is no more than `minimumRows`, and otherwise `minimumRows` whole rows
    /// and the part row, whichever is less, with `reachBeyondRows`. With less room than this, the
    /// panel makes room (`MatchListRoom`).
    public static func minimumReach(
        rowCount: Int, rowHeight: CGFloat, reachBeyondRows: CGFloat, minimumRows: Int = minimumRows,
        partRow: CGFloat = partRow
    ) -> CGFloat {
        guard rowCount > 0 else { return 0 }
        let every = rowHeight * CGFloat(rowCount)
        guard rowCount > minimumRows else { return every + reachBeyondRows }
        let shortened = rowHeight * CGFloat(max(1, minimumRows)) + partRowHeight(rowHeight: rowHeight, partRow: partRow)
        return min(every, shortened) + reachBeyondRows
    }

    /// The height of the list's rows as shown, for rows of `rowHeight`.
    public func listHeight(rowHeight: CGFloat) -> CGFloat {
        rowHeight * CGFloat(rows) + partRowHeight
    }

    /// Whether a list shows fewer rows than it has, so the rest scroll into view.
    public var scrolls: Bool { partRowHeight > 0 }
}

/// Where a shortened list of matches is scrolled to as the highlight moves, so the highlighted
/// row is always whole. A row with others past it keeps a part row's worth of them in view
/// too, so the list still shows there are more: moving down, the highlighted row stops a part
/// row short of the bottom edge, and moving up, a part row short of the top. The first and last
/// rows go flush to the edge. Where the highlight is already in view with that margin, the list
/// stays where it is, wherever the trackpad left it.
public enum MatchListScroll {
    /// - Parameters:
    ///   - index: the highlighted row.
    ///   - current: where the list is scrolled to now, the distance from the first row's top to
    ///     the list's top edge.
    ///   - rowCount: the rows the list has.
    ///   - rowHeight: each row's height.
    ///   - viewport: the list's height as shown.
    ///   - margin: how much of the rows past the highlighted one to keep in view, usually the
    ///     part row's height.
    /// - Returns: where to scroll to, between the top and the end.
    public static func offset(
        showing index: Int, from current: CGFloat, rowCount: Int, rowHeight: CGFloat, viewport: CGFloat, margin: CGFloat
    ) -> CGFloat {
        let end = max(0, CGFloat(rowCount) * rowHeight - viewport)
        var offset = min(max(0, current), end)
        guard index >= 0, index < rowCount, rowHeight > 0 else { return offset }
        let top = CGFloat(index) * rowHeight
        let bottom = top + rowHeight
        let above = index > 0 ? margin : 0
        let below = index < rowCount - 1 ? margin : 0
        if top - above < offset {
            offset = top - above
        } else if bottom + below > offset + viewport {
            offset = bottom + below - viewport
        }
        // The row itself whole, even in a list too short for the margins.
        offset = max(min(offset, top), bottom - viewport)
        return min(max(0, offset), end)
    }

    /// Whether row `index` is whole in a list scrolled to `offset`.
    public static func isWhole(_ index: Int, offset: CGFloat, rowHeight: CGFloat, viewport: CGFloat) -> Bool {
        let top = CGFloat(index) * rowHeight
        return top >= offset && top + rowHeight <= offset + viewport
    }
}

/// Where the panel goes while the list of matches under its text field is open, so the list
/// opens downward with room for at least its minimum, `MatchListFit.minimumReach`, wherever
/// the panel is (the owner's direction, 2026-11-27: "always downward").
///
/// - A floating panel, the centered layout, moves up just far enough, keeping its size. Its top
///   never goes past the top of the screen's visible area, so a panel nearly as tall as the
///   screen moves only as far as that allows.
/// - A panel pinned to a screen edge at full height, slide over, cannot move up, so its bottom
///   edge rises instead and its top stays where it is. It is never made shorter than
///   `minimumHeight`.
///
/// Where it already has the room, or cannot make any, the frame is unchanged. Where it can make
/// only part of it, the list is shortened below its minimum by `MatchListFit`.
public enum MatchListRoom {
    /// How the panel is placed, which says how it can make room.
    public enum Layout: Equatable, Sendable {
        /// Moved and sized by the owner: it moves up.
        case floating
        /// Flush against a screen edge at the screen's full height: its bottom rises.
        case pinnedToEdge
    }

    /// The room below a panel for the list: from its bottom edge to the bottom of its screen's
    /// visible area, less `margin`, so the list never ends flush with the screen's edge. Never
    /// less than none.
    public static func roomBelow(panel: CGRect, visible: CGRect, margin: CGFloat) -> CGFloat {
        max(0, panel.minY - visible.minY - margin)
    }

    /// The panel's frame while the list is open.
    /// - Parameters:
    ///   - panel: the panel's frame where it is, in screen coordinates with a bottom-left origin.
    ///   - visible: its screen's visible area.
    ///   - needed: the room below the panel the list should have.
    ///   - margin: the room left between the list and the bottom of the visible area.
    ///   - minimumHeight: the least height a pinned panel is shortened to.
    public static func frame(
        panel: CGRect, visible: CGRect, layout: Layout, needed: CGFloat, margin: CGFloat, minimumHeight: CGFloat
    ) -> CGRect {
        // Not clamped at none, so a panel flush with the bottom, or past it, makes up the margin too.
        let shortfall = needed - (panel.minY - visible.minY - margin)
        guard shortfall > 0 else { return panel }
        switch layout {
        case .floating:
            let up = min(shortfall, max(0, visible.maxY - panel.maxY))
            return panel.offsetBy(dx: 0, dy: up)
        case .pinnedToEdge:
            let rise = min(shortfall, max(0, panel.height - minimumHeight))
            return CGRect(x: panel.minX, y: panel.minY + rise, width: panel.width, height: panel.height - rise)
        }
    }
}

extension MatchListRoom {
    /// The panel's way to the frame it moves to for the list, and back, as a value that moves on
    /// with time. It is a slide over panel's slide: the same length and the same ease out
    /// (`PanelSlide`), so it is quick to start and settles softly. With Reduce Motion the panel
    /// moves at once instead.
    public struct Motion: Equatable, Sendable {
        public static let duration = PanelSlide.slideDuration

        public let start: CGRect
        public let end: CGRect
        /// 0 at `start` and 1 at `end`, linear in time.
        public private(set) var progress: Double = 0

        public init(from start: CGRect, to end: CGRect) {
            self.start = start
            self.end = end
        }

        public var isFinished: Bool { progress >= 1 }

        /// Moves on by this much time, and stops at the end.
        public mutating func advance(by seconds: TimeInterval) {
            guard seconds > 0 else { return }
            progress = min(1, progress + seconds / Self.duration)
        }

        /// Where the panel is now, in whole points, so the glass's edges stay sharp. Exactly
        /// `end` once finished.
        public var frame: CGRect {
            if isFinished { return end }
            let t = CGFloat(PanelSlide.ease(progress))
            func step(_ from: CGFloat, _ to: CGFloat) -> CGFloat { (from + (to - from) * t).rounded() }
            let minY = step(start.minY, end.minY)
            let maxY = step(start.maxY, end.maxY)
            let minX = step(start.minX, end.minX)
            let maxX = step(start.maxX, end.maxX)
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }
}
