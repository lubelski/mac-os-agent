import MacOSAgentCore
import SwiftUI

/// The corner radii of the panel and of the shapes inside it, in one place so they can be
/// tuned together. They are the same for every theme. A theme does not set them.
///
/// The steps go from the outside in: the panel, a card, a message box, a small control. An
/// inner shape is never rounder than the one that holds it.
enum PanelShape {
    /// The outer corners of the panel, the incognito window, and the inspector.
    static let cornerRadius: CGFloat = 12
    /// The go-ahead card and the card that asks before discarding an incognito conversation.
    static let cardCornerRadius: CGFloat = 9
    /// The owner's message boxes, the agent's reply boxes, and the outlines that stand in
    /// for them.
    static let messageCornerRadius: CGFloat = 6
    /// The hover and selection fills of small controls: the top bar's buttons and a selected
    /// tool row.
    static let controlCornerRadius: CGFloat = 4

    /// The shape of the panel's surface: the glass, the blur, or the solid fill, with all four
    /// corners rounded.
    static let surface = surface(squareEdges: [])
    static let card = RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
    static let message = RoundedRectangle(cornerRadius: messageCornerRadius, style: .continuous)
    static let control = RoundedRectangle(cornerRadius: controlCornerRadius, style: .continuous)

    /// The surface with square corners on the sides flush against the screen's edge, from
    /// `PanelGeometry.flushEdges`: a slide over panel at the left has its left corners square
    /// and its right ones rounded. The panel is laid out left to right, so leading is left.
    static func surface(squareEdges: Set<PanelEdge>) -> UnevenRoundedRectangle {
        let left: CGFloat = squareEdges.contains(.left) ? 0 : cornerRadius
        let right: CGFloat = squareEdges.contains(.right) ? 0 : cornerRadius
        return UnevenRoundedRectangle(
            topLeadingRadius: left, bottomLeadingRadius: left, bottomTrailingRadius: right, topTrailingRadius: right,
            style: .continuous)
    }

    /// The corners of a layer that stay rounded when the sides in `squareEdges` are square.
    /// Only left and right decide, so whether the layer's y grows up or down does not matter.
    static func roundedCorners(squareEdges: Set<PanelEdge>) -> CACornerMask {
        var corners: CACornerMask = []
        if !squareEdges.contains(.left) { corners.formUnion([.layerMinXMinYCorner, .layerMinXMaxYCorner]) }
        if !squareEdges.contains(.right) { corners.formUnion([.layerMaxXMinYCorner, .layerMaxXMaxYCorner]) }
        return corners
    }

    /// Clips a layer to the surface's shape. The clip and the surface must have the same
    /// radius, the same continuous curve, and the same square sides. When they differ, a faint
    /// square outline of the window shows at the corners, or the glass is cut at a corner it
    /// should fill.
    @MainActor
    static func clipToSurface(_ layer: CALayer, squareEdges: Set<PanelEdge> = []) {
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = surface.style == .continuous ? .continuous : .circular
        layer.maskedCorners = roundedCorners(squareEdges: squareEdges)
        layer.masksToBounds = true
    }
}

/// The hairline that sets the panel's bars apart from the history: under the top bar and
/// above the text field, and between the inspector's input and output. All use this one
/// definition, so they keep the same color, thickness, and width. The color is the theme's
/// divider at a fainter strength than the episode hairlines, which for Glass matches the
/// system separator at half strength that it was before themes.
struct PanelDivider: View {
    @Environment(\.panelPalette) private var palette

    var body: some View {
        Rectangle()
            .fill(palette.inputDivider)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

extension PanelPlacement {
    /// The sides of the panel flush against its screen's edge, whose corners are square: the
    /// edge side in slide over, and none once the owner drags it off. See
    /// `PanelGeometry.flushEdges`. The surface and the clip on the panel's layer both use it.
    var squareEdges: Set<PanelEdge> {
        PanelGeometry.flushEdges(of: panelFrame, in: visibleFrame)
    }
}
