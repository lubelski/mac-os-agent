import SwiftUI

/// The corner radii of the panel and of the shapes inside it, in one place so they can be
/// tuned together. They are the same for every theme. A theme does not set them.
///
/// The steps go from the outside in: the panel, a card, a message box, a small control. An
/// inner shape is never rounder than the one that holds it.
enum PanelShape {
    /// The outer corners of the panel, the incognito window, and the inspector.
    static let cornerRadius: CGFloat = 18
    /// The go-ahead card and the card that asks before discarding an incognito conversation.
    static let cardCornerRadius: CGFloat = 12
    /// The owner's message boxes, the agent's reply boxes, and the outlines that stand in
    /// for them.
    static let messageCornerRadius: CGFloat = 10
    /// The hover and selection fills of small controls: the top bar's buttons and a selected
    /// tool row.
    static let controlCornerRadius: CGFloat = 6

    /// The shape of the panel's surface: the glass, the blur, or the solid fill.
    static let surface = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    static let card = RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
    static let message = RoundedRectangle(cornerRadius: messageCornerRadius, style: .continuous)
    static let control = RoundedRectangle(cornerRadius: controlCornerRadius, style: .continuous)

    /// Clips a layer to the surface's shape. The clip and the surface must have the same
    /// radius and the same continuous curve. When they differ, a faint square outline of the
    /// window shows at the corners.
    @MainActor
    static func clipToSurface(_ layer: CALayer) {
        layer.cornerRadius = surface.cornerSize.width
        layer.cornerCurve = surface.style == .continuous ? .continuous : .circular
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
