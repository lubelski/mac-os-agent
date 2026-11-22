import CoreGraphics

/// The screen edge the panel is docked to.
public enum PanelDock: String, Sendable, CaseIterable {
    case left, right
}

/// Where the summon panel goes, worked out from screen rectangles alone. Every rectangle is in
/// AppKit's screen coordinates, with the origin at the bottom left of the primary screen and y
/// growing upward. A screen's `visible` rectangle leaves out the menu bar and the Dock.
public enum PanelGeometry {
    /// The gap between a docked panel and the screen's edges, so the glass's soft shadow is not
    /// cut off at the edge of the display.
    public static let dockMargin: CGFloat = 10
    /// The least room left around an undocked panel.
    public static let screenMargin: CGFloat = 20
    /// A docked panel is at most this share of the screen's width when it docks.
    public static let dockedWidthShare: CGFloat = 0.5
    /// How far a docked edge can be from where it belongs and still count as docked.
    public static let tolerance: CGFloat = 1

    /// The panel's default place: centered across the screen, with its top a little below the
    /// menu bar. The size shrinks to fit a small screen.
    public static func defaultFrame(size: CGSize, in visible: CGRect) -> CGRect {
        let width = min(size.width, visible.width - 2 * screenMargin)
        let height = min(size.height, visible.height - 2 * screenMargin)
        let top = visible.maxY - visible.height * 0.12
        return CGRect(
            x: (visible.midX - width / 2).rounded(),
            y: max(visible.minY + screenMargin, top - height).rounded(),
            width: width, height: height)
    }

    /// The panel docked to one edge of the screen: the full height of the visible area less
    /// the margin, and the width it has now, kept between the minimum and half the screen.
    public static func dockedFrame(_ dock: PanelDock, width: CGFloat, minimumWidth: CGFloat, in visible: CGRect) -> CGRect {
        let room = visible.width - 2 * dockMargin
        let widest = max(minimumWidth, (visible.width * dockedWidthShare).rounded(.down))
        let docked = min(room, max(minimumWidth, min(width, widest))).rounded()
        let x = dock == .left ? visible.minX + dockMargin : visible.maxX - dockMargin - docked
        return CGRect(x: x, y: visible.minY + dockMargin, width: docked, height: visible.height - 2 * dockMargin)
    }

    /// Whether a frame still sits where a docked panel belongs. The docked edge, the top, and
    /// the bottom must be in place. The free edge can move, so the owner can change the width.
    public static func isDocked(_ frame: CGRect, at dock: PanelDock, in visible: CGRect) -> Bool {
        let edge = dock == .left
            ? abs(frame.minX - (visible.minX + dockMargin))
            : abs(frame.maxX - (visible.maxX - dockMargin))
        return edge <= tolerance
            && abs(frame.minY - (visible.minY + dockMargin)) <= tolerance
            && abs(frame.maxY - (visible.maxY - dockMargin)) <= tolerance
    }

    /// The frame moved and shrunk as little as needed to fit inside the screen, with a margin.
    /// It never shrinks below the minimum size unless the screen itself is smaller.
    public static func clamped(_ frame: CGRect, minimumSize: CGSize, in visible: CGRect) -> CGRect {
        let room = visible.insetBy(dx: screenMargin, dy: screenMargin)
        let width = max(min(frame.width, room.width), min(minimumSize.width, visible.width))
        let height = max(min(frame.height, room.height), min(minimumSize.height, visible.height))
        func place(_ origin: CGFloat, _ length: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            // Centered when it does not fit between the margins.
            if length > high - low { return (low + high) / 2 - length / 2 }
            return min(max(origin, low), high - length)
        }
        return CGRect(
            x: place(frame.minX, width, room.minX, room.maxX),
            y: place(frame.minY, height, room.minY, room.maxY),
            width: width, height: height)
    }

    /// Whether enough of the frame is on a screen for the owner to see it and grab it.
    public static func isReachable(_ frame: CGRect, on visibleFrames: [CGRect]) -> Bool {
        visibleFrames.contains { $0.intersection(frame).height >= 60 && $0.intersection(frame).width >= 120 }
    }

    /// The index of the screen that holds the largest part of the frame, or nil when no screen
    /// holds any of it.
    public static func screenIndex(for frame: CGRect, among screenFrames: [CGRect]) -> Int? {
        var best: (index: Int, area: CGFloat)?
        for (index, screen) in screenFrames.enumerated() {
            let overlap = screen.intersection(frame)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { continue }
            let area = overlap.width * overlap.height
            if area > (best?.area ?? 0) { best = (index, area) }
        }
        return best?.index
    }

    /// The index of the screen under a point, such as the mouse, or nil when it is on none.
    public static func screenIndex(containing point: CGPoint, among screenFrames: [CGRect]) -> Int? {
        // A screen's frame includes its bottom and left edges. The mouse can sit on the top edge.
        screenFrames.firstIndex { $0.contains(point) || ($0.minX...$0.maxX ~= point.x && point.y == $0.maxY) }
    }
}
