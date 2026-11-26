import CoreGraphics
import Foundation

/// Where a stack of panes is: the items opened above its base, in order.
///
/// A stack shows a base pane, and each entry of the path opens one more pane over the one
/// before it. The path holds only item ids, any number of them. It says nothing about what an
/// id means or where the base is: a Settings section uses it from inside the section today, and
/// the same path could start with the section's id if the sidebar became the base.
///
/// Depth counts panes above the base: depth 0 is the base alone, and depth 2 is the base with
/// two panes over it, the second of which is on top.
public struct PaneStackPath: Sendable, Equatable, Hashable, CustomStringConvertible {
    /// The opened items, oldest first. `entries[0]` is the item opened from the base.
    public private(set) var entries: [String]

    public init(_ entries: [String] = []) {
        self.entries = entries
    }

    /// How many panes are open above the base.
    public var depth: Int { entries.count }

    /// True when only the base shows.
    public var isAtBase: Bool { entries.isEmpty }

    /// The item whose pane shows at a depth, or nil for the base and for a depth not open.
    public func entry(at depth: Int) -> String? {
        guard depth >= 1, depth <= entries.count else { return nil }
        return entries[depth - 1]
    }

    /// The item opened from the pane at a depth, which that pane marks as open. Nil when nothing
    /// is open from it, as on the top pane.
    public func opened(from depth: Int) -> String? {
        entry(at: depth + 1)
    }

    /// The path up to a depth: what the stack shows when that pane is on top.
    public func prefix(_ depth: Int) -> PaneStackPath {
        PaneStackPath(Array(entries.prefix(max(0, depth))))
    }

    /// Opens an item from the pane at a depth: the panes above that depth close and the item's
    /// pane goes on top. From the top pane this pushes one more pane. From a covered pane it
    /// replaces everything above it, such as a click on another group in a covered strip.
    public mutating func open(_ id: String, from depth: Int) {
        entries = Array(entries.prefix(max(0, depth))) + [id]
    }

    /// Opens an item from the top pane, one level deeper.
    public mutating func open(_ id: String) {
        open(id, from: depth)
    }

    /// Closes the top pane. Returns false when only the base shows, so there was nothing to
    /// close and the key that asked can mean what it meant before.
    @discardableResult
    public mutating func goBack() -> Bool {
        guard !entries.isEmpty else { return false }
        entries.removeLast()
        return true
    }

    /// Closes every pane above a depth, so the pane at that depth is on top. A depth at or
    /// above the top changes nothing.
    public mutating func goBack(to depth: Int) {
        if depth < entries.count { entries = Array(entries.prefix(max(0, depth))) }
    }

    /// A click on a covered pane's strip. On an item other than the one already open from that
    /// pane, it opens that item instead, replacing everything above the pane. Anywhere else,
    /// the open item's row included, it goes back to that pane.
    public mutating func clickStrip(at depth: Int, on item: String?) {
        if let item, item != opened(from: depth) {
            open(item, from: depth)
        } else {
            goBack(to: depth)
        }
    }

    /// Replaces the whole path, such as to open a stand-in state for a preview.
    public mutating func replace(with entries: [String]) {
        self.entries = entries
    }

    /// The path as one string, entries joined by `/`, for a key such as a pane's scroll place.
    public var description: String { entries.joined(separator: "/") }
}

/// What a change of path does to the stack, so the view can pick its motion.
///
/// Opening a pane where none was open and going back are moves across the stack, and slide
/// from the side. A swap is neither: the item open at some depth is replaced by another item
/// from the same list, and any panes above that depth close. A swap moves up or down, following
/// the two items' order in the list they were picked from.
public enum PaneStackChange: Equatable, Sendable {
    /// The path did not change.
    case none
    /// Panes opened over the ones already showing, which stay as they were.
    case open
    /// Panes closed, and the ones left are as they were.
    case back
    /// The item at `depth` was replaced by another. Panes above that depth closed, and any the
    /// new path opens above it are new.
    case swap(depth: Int, direction: PaneSwapDirection)

    /// What changed from one path to another.
    ///
    /// - Parameters:
    ///   - old: The path before the change.
    ///   - new: The path after it.
    ///   - rows: The ids a pane lists, top to bottom, given the path that shows that pane on top.
    ///     It is asked only on a swap, for the pane the swapped item was picked from.
    public init(from old: PaneStackPath, to new: PaneStackPath, rows: (PaneStackPath) -> [String]) {
        guard old != new else { self = .none; return }
        let shared = zip(old.entries, new.entries).prefix { $0 == $1 }.count
        if shared == old.depth { self = .open; return }
        if shared == new.depth { self = .back; return }

        // Both paths have an entry just past what they share, and the two differ.
        let list = rows(new.prefix(shared))
        guard let from = list.firstIndex(of: old.entries[shared]),
              let to = list.firstIndex(of: new.entries[shared]) else {
            self = .swap(depth: shared + 1, direction: .inPlace)
            return
        }
        self = .swap(depth: shared + 1, direction: to > from ? .fromBelow : .fromAbove)
    }

    /// The depth a swap replaced, or nil for any other change.
    public var swapDepth: Int? {
        if case .swap(let depth, _) = self { depth } else { nil }
    }

    /// Which way a swap's new content comes in, or nil for any other change.
    public var swapDirection: PaneSwapDirection? {
        if case .swap(_, let direction) = self { direction } else { nil }
    }
}

/// Every motion value a pane stack uses, in one place, so they can be tuned together.
public struct PaneStackMotion: Equatable, Sendable {
    /// How long a pane takes to slide in from the right or back out, in seconds.
    public var slideDuration: Double = 0.28
    /// The slide's spring bounce. 0 has none.
    public var slideBounce: Double = 0
    /// How long any change takes with Reduce Motion on, where panes and swaps only fade.
    public var reduceMotionFadeDuration: Double = 0.2
    /// How far a swap's content moves up or down while it crossfades, in points.
    public var swapDistance: CGFloat = 16
    /// How long a swap takes, in seconds, on an ease out.
    public var swapDuration: Double = 0.2

    public init() {}

    /// The values the stack uses.
    public static let standard = PaneStackMotion()
}

/// Which way a swap's new content comes in.
public enum PaneSwapDirection: Equatable, Sendable {
    /// The new item is lower in the list, so its content rises from below.
    case fromBelow
    /// The new item is higher in the list, so its content comes down from above.
    case fromAbove
    /// An item is not in the list, so there is no order to follow: the content only fades.
    case inPlace
}

/// How wide each covered pane's strip is, so the top pane always has room.
///
/// Each covered pane shows a strip at its leading edge, the part the pane above it does not
/// cover. A section asks for a width per strip. When those widths leave the top pane less than
/// its minimum, strips give way oldest first:
///
/// 1. Each older strip narrows to a sliver (`collapsedWidth`), starting with the base's.
/// 2. If that is not enough, slivers go away entirely, again oldest first.
/// 3. Only then does the strip just under the top pane give way, shrinking to what is left.
///    It is the usual way back, so it keeps its full width longest.
///
/// Escape still closes one pane at a time, so a strip that went away is still reachable.
public enum PaneStackLayout {
    /// The top pane's minimum width before older strips give way.
    public static let minimumTopWidth: CGFloat = 320
    /// The width of a strip that has collapsed to a sliver.
    public static let collapsedWidth: CGFloat = 24

    /// The width of each covered pane's strip, oldest first.
    ///
    /// - Parameters:
    ///   - preferred: The width the section asks for each strip, oldest (the base's) first.
    ///   - available: The width the whole stack has.
    public static func stripWidths(
        preferred: [CGFloat], available: CGFloat,
        minimumTopWidth: CGFloat = minimumTopWidth, collapsedWidth: CGFloat = collapsedWidth
    ) -> [CGFloat] {
        var widths = preferred.map { max(0, $0) }
        let budget = max(0, available - minimumTopWidth)
        func fits() -> Bool { widths.reduce(0, +) <= budget }
        guard !fits() else { return widths }

        for index in widths.indices.dropLast() where !fits() {
            widths[index] = min(widths[index], collapsedWidth)
        }
        for index in widths.indices.dropLast() where !fits() {
            widths[index] = 0
        }
        if !fits(), let last = widths.indices.last {
            widths[last] = max(0, budget - widths.dropLast().reduce(0, +))
        }
        return widths
    }

    /// How far each pane sits below the one under it.
    public static let drop: CGFloat = 10

    /// Where each pane's top edge sits, from the base (at 0) to the top pane. A pane drops below
    /// the one under it only when that one's strip shows, so panes whose strips went away sit
    /// exactly on each other and a deep stack does not eat the window's height.
    public static func topEdges(stripWidths: [CGFloat], drop: CGFloat = drop) -> [CGFloat] {
        stripWidths.reduce(into: [0]) { edges, width in edges.append(edges.last! + (width > 0 ? drop : 0)) }
    }

    /// Where each pane's leading edge sits, from the base (at 0) to the top pane.
    public static func leadingEdges(stripWidths: [CGFloat]) -> [CGFloat] {
        stripWidths.reduce(into: [0]) { edges, width in edges.append(edges.last! + width) }
    }
}
