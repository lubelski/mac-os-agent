import CoreGraphics

/// Which way the list of matches under the text field opens, and how many of its rows show at
/// once. The panel with bars' match card uses it. The rows that do not show come into view as
/// the highlight reaches them.
///
/// The list opens downward wherever there is room below for `minimumRows` of it. With room for
/// every row it shows them all. With less, it is shortened to the rows that fit, and scrolls.
/// With room for fewer than `minimumRows`, as in slide over, where the panel is the screen's
/// full height, a list opening downward would be drawn off the screen or under the Dock, so it
/// opens upward instead. That last case is a default the owner has not settled.
public enum MatchListFit: Equatable, Sendable {
    /// Downward, showing this many rows at once.
    case below(rows: Int)
    /// Upward, since there is room below for fewer than the minimum. How many rows show then is
    /// up to the room above.
    case above

    /// The fewest rows a list opening downward is shortened to.
    public static let minimumRows = 2

    /// - Parameters:
    ///   - rowCount: the rows the list has, at most as many as it ever shows at once.
    ///   - rowHeight: each row's height.
    ///   - reachBeyondRows: how far the list reaches below the room's top edge besides its rows,
    ///     such as a hairline.
    ///   - roomBelow: the room below for the list.
    /// - Returns: nil when there are no rows.
    public static func fit(
        rowCount: Int, rowHeight: CGFloat, reachBeyondRows: CGFloat, roomBelow: CGFloat, minimumRows: Int = minimumRows
    ) -> MatchListFit? {
        guard rowCount > 0, rowHeight > 0 else { return nil }
        // Compared as a float first, so a room of any size never overflows an Int.
        let fits = ((roomBelow - reachBeyondRows) / rowHeight).rounded(.down)
        if fits >= CGFloat(rowCount) { return .below(rows: rowCount) }
        let fewest = min(max(1, minimumRows), rowCount)
        if fits >= CGFloat(fewest) { return .below(rows: Int(fits)) }
        return .above
    }

    /// Whether a list of `rowCount` rows shows fewer than it has, so the rest scroll into view.
    /// Opening upward, that is the room above's to say, so this is false.
    public func scrolls(rowCount: Int) -> Bool {
        if case .below(let rows) = self { return rows < rowCount }
        return false
    }
}
