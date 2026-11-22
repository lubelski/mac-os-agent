import CoreGraphics
import Foundation

/// A slide over panel's way in from its edge or back out past it, as a value that moves on
/// with time and can turn around at any point.
///
/// `progress` is linear in time, 0 hidden and 1 in place. Where the glass is drawn comes from
/// one easing curve applied to it in both directions. Turning around keeps `progress`, so the
/// glass never jumps: summoning during the way out runs it back in from where it is, and
/// hiding during the way in runs it back out.
public struct PanelSlide: Equatable, Sendable {
    /// How the panel comes and goes.
    public enum Style: Sendable {
        /// It slides in from the screen's edge and back out past it.
        case slide
        /// It fades in and out in place. For Reduce Motion.
        case fade
    }

    /// Where the panel is headed.
    public enum Target: Sendable {
        case shown, hidden
    }

    /// The full way in or out. Short and soft, like Notification Center.
    public static let slideDuration: TimeInterval = 0.3
    /// A quick fade for Reduce Motion.
    public static let fadeDuration: TimeInterval = 0.15

    public private(set) var target: Target
    /// 0 is hidden, 1 is in place, linear in time.
    public private(set) var progress: Double
    public let style: Style

    /// A slide that starts fully at one end and heads to the other.
    public init(style: Style, to target: Target) {
        self.style = style
        self.target = target
        progress = target == .shown ? 0 : 1
    }

    public var duration: TimeInterval {
        style == .slide ? Self.slideDuration : Self.fadeDuration
    }

    /// True once it has arrived where it is headed.
    public var isFinished: Bool {
        progress == (target == .shown ? 1 : 0)
    }

    /// Moves on by this much time, toward the target, and stops there.
    public mutating func advance(by seconds: TimeInterval) {
        guard seconds > 0, duration > 0 else { return }
        let step = seconds / duration
        progress = target == .shown ? min(1, progress + step) : max(0, progress - step)
    }

    /// Heads the other way from where it is, or keeps going when already headed there.
    public mutating func retarget(_ target: Target) {
        self.target = target
    }

    /// How far in the panel is, eased: 0 off screen or transparent, 1 in place.
    public var position: Double { Self.ease(progress) }

    /// The share of the way out that the glass is moved, 0 in place and 1 fully past the edge.
    /// Always 0 for a fade.
    public var travel: Double { style == .slide ? 1 - position : 0 }

    /// The panel's opacity. Always 1 for a slide, so the glass keeps its look on the way.
    public var alpha: Double { style == .fade ? position : 1 }

    /// An ease out: quick to start coming in and settling softly into place. Run backward on
    /// the way out, it starts gently and leaves quickly, as a sheet does.
    static func ease(_ t: Double) -> Double {
        let t = min(1, max(0, t))
        return 1 - pow(1 - t, 3)
    }
}

/// Where a slide over panel is drawn at one moment, for a window that follows it, such as an
/// inspector beside the panel. Every rectangle is in AppKit's screen coordinates.
public struct PanelMotionFrame: Equatable, Sendable {
    /// Where the glass is drawn now. Partway, or fully past the edge, while it slides.
    public var glass: CGRect
    /// Where the glass is when in place.
    public var resting: CGRect
    /// The part of the screen that content may show in. The panel is cut off at its edge, so a
    /// follower cuts itself off there too and never shows on the display next door.
    public var clip: CGRect
    /// The panel's opacity, below 1 only while it fades for Reduce Motion.
    public var alpha: Double
    /// 0 hidden, 1 in place, eased.
    public var position: Double

    public init(glass: CGRect, resting: CGRect, clip: CGRect, alpha: Double, position: Double) {
        self.glass = glass
        self.resting = resting
        self.clip = clip
        self.alpha = alpha
        self.position = position
    }

    /// How far the glass is from its resting place, sideways. A follower moves by the same.
    public var offset: CGFloat { glass.minX - resting.minX }
}

extension PanelGeometry {
    /// The window around a slide over panel: the panel's frame widened on its edge side to the
    /// edge of the screen's visible area. The glass slides inside this window and is cut off
    /// at the window's edge, which is the screen's, so on the way out it never shows on a
    /// display beside this one, and with the Dock on that side it goes behind the Dock's edge.
    public static func slideOverWindowFrame(panel: CGRect, edge: PanelEdge, in visible: CGRect) -> CGRect {
        switch edge {
        case .left:
            let minX = min(panel.minX, visible.minX)
            return CGRect(x: minX, y: panel.minY, width: panel.maxX - minX, height: panel.height)
        case .right:
            let maxX = max(panel.maxX, visible.maxX)
            return CGRect(x: panel.minX, y: panel.minY, width: maxX - panel.minX, height: panel.height)
        }
    }

    /// How far the glass moves sideways to be fully past the edge of the visible area: negative
    /// toward the left.
    public static func slideDistance(panel: CGRect, edge: PanelEdge, in visible: CGRect) -> CGFloat {
        switch edge {
        case .left: -(panel.maxX - visible.minX)
        case .right: visible.maxX - panel.minX
        }
    }

    /// The glass's frame a share of the way out, from 0 in place to 1 fully past the edge.
    ///
    /// - Parameter companion: a window that slides with the panel as one unit, such as the
    ///   inspector on the panel's inward side. The way out is then long enough for both to be
    ///   past the edge, so the companion never shows on its own.
    public static func slidFrame(
        panel: CGRect, companion: CGRect? = nil, edge: PanelEdge, in visible: CGRect, travel: Double
    ) -> CGRect {
        panel.offsetBy(dx: slideOffset(panel: panel, companion: companion, edge: edge, in: visible, travel: travel), dy: 0)
    }

    /// How far the panel, and a companion with it, are moved sideways a share of the way out.
    /// Whole points, because a window's frame is in whole points, so a companion window and the
    /// glass inside the panel's window move together to the point.
    public static func slideOffset(
        panel: CGRect, companion: CGRect? = nil, edge: PanelEdge, in visible: CGRect, travel: Double
    ) -> CGFloat {
        let unit = companion.map { panel.union($0) } ?? panel
        return (slideDistance(panel: unit, edge: edge, in: visible) * CGFloat(travel)).rounded()
    }
}
