import CoreGraphics

/// A side of the screen, or of the panel.
public enum PanelEdge: String, Sendable, CaseIterable {
    case left, right

    public var opposite: PanelEdge { self == .left ? .right : .left }
}

/// The name from when the panel docked to an edge. Kept so work written against it still
/// builds. New code says `PanelEdge`.
public typealias PanelDock = PanelEdge

/// Where the summon panel goes, worked out from screen rectangles alone. Every rectangle is in
/// AppKit's screen coordinates, with the origin at the bottom left of the primary screen and y
/// growing upward. A screen's `visible` rectangle leaves out the menu bar and the Dock.
public enum PanelGeometry {
    /// The gap between a slide over panel and the screen's edges, so the glass's soft shadow is
    /// not cut off at the edge of the display and the glass reads as floating.
    public static let slideOverMargin: CGFloat = 10
    /// The name from when the panel docked. New code says `slideOverMargin`.
    public static let dockMargin: CGFloat = slideOverMargin
    /// The least room left around a centered panel.
    public static let screenMargin: CGFloat = 20
    /// A slide over panel is at most this share of the screen's width.
    public static let slideOverWidthShare: CGFloat = 0.5
    /// How far an edge can be from where it belongs and still count as in place.
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

    /// The panel in slide over at one edge of the screen: the full height of the visible area
    /// less the margin, and the width asked for, kept between the minimum and half the screen.
    public static func slideOverFrame(_ edge: PanelEdge, width: CGFloat, minimumWidth: CGFloat, in visible: CGRect) -> CGRect {
        let room = visible.width - 2 * slideOverMargin
        let widest = max(minimumWidth, (visible.width * slideOverWidthShare).rounded(.down))
        let fitted = min(room, max(minimumWidth, min(width, widest))).rounded()
        let x = edge == .left ? visible.minX + slideOverMargin : visible.maxX - slideOverMargin - fitted
        return CGRect(x: x, y: visible.minY + slideOverMargin, width: fitted, height: visible.height - 2 * slideOverMargin)
    }

    /// Whether a frame still sits where a slide over panel at that edge belongs. The edge, the
    /// top, and the bottom must be in place. The free edge can move, so the owner can change
    /// the width.
    public static func isInSlideOver(_ frame: CGRect, at edge: PanelEdge, in visible: CGRect) -> Bool {
        let held = edge == .left
            ? abs(frame.minX - (visible.minX + slideOverMargin))
            : abs(frame.maxX - (visible.maxX - slideOverMargin))
        return held <= tolerance
            && abs(frame.minY - (visible.minY + slideOverMargin)) <= tolerance
            && abs(frame.maxY - (visible.maxY - slideOverMargin)) <= tolerance
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

/// Where the tool call inspector goes beside the panel.
public struct InspectorPlacement: Equatable, Sendable {
    public enum Side: String, Equatable, Sendable {
        case left, right
    }

    public var frame: CGRect
    public var side: Side
    /// True on a screen too narrow for both side by side, where the inspector covers part of
    /// the panel's far side, and leaves the rest of the conversation in view.
    public var overlapsPanel: Bool

    public init(frame: CGRect, side: Side, overlapsPanel: Bool) {
        self.frame = frame
        self.side = side
        self.overlapsPanel = overlapsPanel
    }
}

extension PanelGeometry {
    /// The gap between the panel and the inspector beside it.
    public static let inspectorGap: CGFloat = 8
    /// The narrowest the inspector gets beside the panel.
    public static let inspectorMinimumWidth: CGFloat = 320
    /// The narrowest it gets when it has to cover part of the panel.
    public static let inspectorNarrowestWidth: CGFloat = 260
    /// How much of the conversation stays in view when the inspector covers part of the panel.
    public static let conversationKeptInView: CGFloat = 280

    /// The inspector's frame: the panel's height and top, against the side of the panel that has
    /// room. That is the panel's free side, from `PanelPreset.freeSide`: the right, or the left
    /// when the panel is in slide over at the right. When the free side has no room for the
    /// minimum width, it is the other side. When neither side has room, it goes against the
    /// screen's edge on the side with more room and covers the panel's far side, leaving at
    /// least `conversationKeptInView` of the panel in view when the screen allows it.
    public static func inspectorPlacement(
        panel: CGRect, freeSide: PanelEdge, width: CGFloat, in visible: CGRect
    ) -> InspectorPlacement {
        let margin = slideOverMargin
        let roomRight = visible.maxX - margin - (panel.maxX + inspectorGap)
        let roomLeft = (panel.minX - inspectorGap) - (visible.minX + margin)
        let preferred: InspectorPlacement.Side = freeSide == .left ? .left : .right
        let other: InspectorPlacement.Side = preferred == .right ? .left : .right
        func room(_ side: InspectorPlacement.Side) -> CGFloat { side == .right ? roomRight : roomLeft }
        let wanted = max(width, inspectorMinimumWidth)

        func beside(_ side: InspectorPlacement.Side) -> InspectorPlacement {
            let fitted = min(wanted, room(side)).rounded(.down)
            let x = side == .right ? panel.maxX + inspectorGap : panel.minX - inspectorGap - fitted
            return InspectorPlacement(
                frame: CGRect(x: x, y: panel.minY, width: fitted, height: panel.height), side: side, overlapsPanel: false)
        }
        if room(preferred) >= inspectorMinimumWidth { return beside(preferred) }
        if room(other) >= inspectorMinimumWidth { return beside(other) }

        // Neither side fits: cover the far side of the panel from the edge with more room.
        let side: InspectorPlacement.Side = room(other) > room(preferred) ? other : preferred
        let edge = side == .right ? visible.maxX - margin : visible.minX + margin
        // Keep the conversation's near part in view: the inspector reaches at most this far in.
        let reach = side == .right
            ? edge - (panel.minX + conversationKeptInView)
            : (panel.maxX - conversationKeptInView) - edge
        let fitted = max(inspectorNarrowestWidth, min(wanted, reach, visible.width - 2 * margin)).rounded(.down)
        let x = side == .right ? edge - fitted : edge
        return InspectorPlacement(
            frame: CGRect(x: x, y: panel.minY, width: fitted, height: panel.height), side: side, overlapsPanel: true)
    }
}
