import Foundation

/// How the panel lays out the owner's messages and the agent's replies. A setting in
/// Settings, Appearance, kept with the theme preferences in `ThemePreferences`. It is the same
/// for every theme, and a theme file does not set it.
public enum MessageLayout: String, CaseIterable, Sendable, Identifiable {
    /// The owner's messages in a box on the right and the agent's replies in a box on the left,
    /// each as wide as its text. Time labels and the lines for apps opened and quick actions
    /// run are centered. The default, and how the panel looked before the setting.
    case sides
    /// Both kinds of box start at the left edge and run the full width of the conversation,
    /// with their outline a little fainter. Time labels and the lines for apps opened and
    /// quick actions run sit at the left too.
    case fullWidth

    public var id: String { rawValue }

    /// The choice's name in Settings, Appearance.
    public var title: String {
        switch self {
        case .sides: "Yours on the right, the agent's on the left"
        case .fullWidth: "Full width, aligned left"
        }
    }

    /// Where a line that is not a message sits across the conversation.
    public enum LineAlignment: Sendable, Equatable {
        case center
        case leading
    }

    /// True when the message boxes run the full width of the conversation.
    public var boxesFillWidth: Bool { self == .fullWidth }

    /// Where the time label above a stretch of the owner's messages sits. The owner asked for
    /// the boxes and the quick action lines on the left. Moving the time label with them is a
    /// choice made alongside that, so it is kept in this one place to be easy to change.
    public var timeLabelAlignment: LineAlignment {
        switch self {
        case .sides: .center
        case .fullWidth: .leading
        }
    }

    /// Where the lines for an app opened or a quick action run sit.
    public var conversationLineAlignment: LineAlignment {
        switch self {
        case .sides: .center
        case .fullWidth: .leading
        }
    }

    /// How much of a box's edge strength full width keeps. Two full width boxes in a row read
    /// as a heavier grid than two narrow ones on opposite sides, so the outline is drawn a
    /// little fainter there.
    public static let fullWidthEdgeStrength = 0.6

    /// The share of a theme's edge strength this layout draws.
    public var edgeStrength: Double {
        switch self {
        case .sides: 1
        case .fullWidth: Self.fullWidthEdgeStrength
        }
    }

    /// A message box's edge as this layout draws it. With Increase Contrast on the edge is
    /// left as the theme and the contrast rule make it, since the owner asked the system for
    /// stronger edges.
    public func messageEdge(_ edge: ThemeColor, increasedContrast: Bool) -> ThemeColor {
        guard !increasedContrast, edgeStrength != 1 else { return edge }
        return edge.scaled(toOpacity: edge.opacity * edgeStrength)
    }
}
