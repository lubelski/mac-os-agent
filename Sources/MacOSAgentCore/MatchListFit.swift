import CoreGraphics

/// Which way the list of matches under the text field opens, and how much of it shows at once.
/// The panel with bars' match card uses it.
///
/// The list opens downward wherever there is room below for `minimumRows` whole rows and a part
/// row. With room for every row it shows them all. With less, it is shortened to the whole rows
/// that fit and a part row, `partRow` of a row cut off at its bottom edge, which shows that more
/// rows are below. The shortened list scrolls. So a shortened list is never less than 2.4 rows
/// tall (the owner's suggestion, 2026-11-27). With room for less than that, as in slide over,
/// where the panel is the screen's full height, a list opening downward would be drawn off the
/// screen or under the Dock, so it opens upward instead. That last case is a default the owner
/// has not settled.
public enum MatchListFit: Equatable, Sendable {
    /// Downward, showing this many whole rows and then `partRowHeight` points of the next one.
    /// The part is 0 when every row shows.
    case below(rows: Int, partRowHeight: CGFloat)
    /// Upward, since there is room below for less than the minimum. How many rows show then is
    /// up to the room above.
    case above

    /// The fewest whole rows a shortened list opening downward shows, before its part row.
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
        rowCount: Int, rowHeight: CGFloat, reachBeyondRows: CGFloat, roomBelow: CGFloat,
        minimumRows: Int = minimumRows, partRow: CGFloat = partRow
    ) -> MatchListFit? {
        guard rowCount > 0, rowHeight > 0 else { return nil }
        let room = roomBelow - reachBeyondRows
        // Compared as a float first, so a room of any size never overflows an Int.
        if room / rowHeight >= CGFloat(rowCount) { return .below(rows: rowCount, partRowHeight: 0) }
        let part = partRowHeight(rowHeight: rowHeight, partRow: partRow)
        let whole = ((room - part) / rowHeight).rounded(.down)
        // `whole` is below `rowCount` here, since the room is short of every row.
        if whole >= CGFloat(max(1, minimumRows)) { return .below(rows: Int(whole), partRowHeight: part) }
        return .above
    }

    /// The height of the list's rows as shown, for rows of `rowHeight`. None opening upward,
    /// where that is the room above's to say.
    public func listHeight(rowHeight: CGFloat) -> CGFloat {
        if case .below(let rows, let part) = self { return rowHeight * CGFloat(rows) + part }
        return 0
    }

    /// Whether a list shows fewer rows than it has, so the rest scroll into view. Opening
    /// upward, that is the room above's to say, so this is false.
    public var scrolls: Bool {
        if case .below(_, let part) = self { return part > 0 }
        return false
    }
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
