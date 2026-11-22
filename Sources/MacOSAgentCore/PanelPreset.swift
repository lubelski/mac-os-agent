import CoreGraphics

/// Where the panel lives, chosen from the layout menu in its top bar. Choosing a preset moves
/// the panel there. The menu lists `allCases` in order, so a new preset is one more case here,
/// with its title, its symbol, and its frame in `SummonPanel`.
public enum PanelPreset: String, Sendable, CaseIterable, Identifiable {
    /// A floating panel the owner can move and resize. It appears and disappears in place.
    case centered
    /// Full height and flush against the left edge of its screen, with its left corners square. It slides in from the edge when
    /// summoned and back out past it when hidden.
    case slideOverLeft
    /// The same against the right edge.
    case slideOverRight

    public var id: String { rawValue }

    /// The name in the layout menu.
    public var title: String {
        switch self {
        case .centered: "Centered"
        case .slideOverLeft: "Slide Over Left"
        case .slideOverRight: "Slide Over Right"
        }
    }

    /// The SF Symbol for the layout control while this preset is on.
    public var symbol: String {
        switch self {
        case .centered: "rectangle.center.inset.filled"
        case .slideOverLeft: "rectangle.lefthalf.inset.filled"
        case .slideOverRight: "rectangle.righthalf.inset.filled"
        }
    }

    /// The screen edge a slide over preset lives at, or nil for one that does not slide.
    public var slideOverEdge: PanelEdge? {
        switch self {
        case .centered: nil
        case .slideOverLeft: .left
        case .slideOverRight: .right
        }
    }

    public init(slideOver edge: PanelEdge) {
        self = edge == .left ? .slideOverLeft : .slideOverRight
    }

    /// The side of the panel with room beside it, for something that attaches to the panel,
    /// such as an inspector: the right, unless the panel is against the right edge.
    public var freeSide: PanelEdge {
        slideOverEdge?.opposite ?? .right
    }

    /// The preset an owner had before presets, from the dock state PR #17 stored under
    /// `SummonPanelDock`: docked left or right becomes slide over at that edge. Nil when the
    /// value is missing or unknown, which leaves the panel centered.
    public init?(legacyDock value: String?) {
        guard let value, let edge = PanelEdge(rawValue: value) else { return nil }
        self.init(slideOver: edge)
    }
}

extension PanelGeometry {
    /// How much room there is beside the panel on one side, inside the screen's visible area
    /// less the margin a window beside the panel keeps from the screen's edge. Never negative.
    public static func room(on side: PanelEdge, of panel: CGRect, in visible: CGRect) -> CGFloat {
        let room = side == .right
            ? (visible.maxX - windowEdgeMargin) - panel.maxX
            : panel.minX - (visible.minX + windowEdgeMargin)
        return max(0, room)
    }
}
