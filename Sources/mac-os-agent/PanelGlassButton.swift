import SwiftUI

extension View {
    /// The panel's Liquid Glass button: `.glass`, or `.glassProminent` for the default choice.
    ///
    /// An offscreen render cannot draw either one. The glass and the vibrant label need the
    /// window server, so `PreviewRender` gets no capsule and a black label, even in dark mode.
    /// While rendering, a stand-in with an opaque capsule and the appearance's own label color is
    /// drawn instead, so a preview shows the light text the app shows in dark mode.
    func panelGlassButton(prominent: Bool = false) -> some View {
        modifier(PanelGlassButton(prominent: prominent, standIn: PreviewRender.isRendering))
    }
}

struct PanelGlassButton: ViewModifier {
    let prominent: Bool
    let standIn: Bool

    func body(content: Content) -> some View {
        if standIn {
            content.buttonStyle(GlassStandInStyle(prominent: prominent))
        } else if prominent {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.glass)
        }
    }
}

/// What a glass button looks like in the app, drawn with opaque colors so it renders offscreen:
/// a capsule with the label in the primary color, or tinted with the accent and a white label.
struct GlassStandInStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let small = controlSize == .small || controlSize == .mini
        configuration.label
            .foregroundStyle(prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, small ? 8 : 12)
            .padding(.vertical, small ? 2 : 5)
            .background(
                prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.fill.secondary),
                in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
