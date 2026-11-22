import SwiftUI

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
