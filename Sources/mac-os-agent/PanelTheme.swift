import AppKit
import MacOSAgentCore
import SwiftUI

/// The active theme, resolved for how the panel is drawn right now: light or dark, Increase
/// Contrast, and whether glass and blur are allowed. Every view in the panel draws its colors
/// from this, through `\.panelPalette`.
///
/// A theme whose three text levels are all system label colors, as Glass is, leaves the
/// panel's foreground alone, so text keeps the system's vibrancy over the glass and the
/// hierarchical styles `.primary`, `.secondary`, and `.tertiary` mean what they always did.
/// Any other theme sets those three levels to its own text colors at the root of the panel,
/// so a view that draws in `.secondary` draws in the theme's secondary text color.
struct PanelPalette {
    let appearance: ThemeAppearance
    let isDark: Bool
    /// True when the text levels are the system's own label colors.
    let usesSystemText: Bool
    let increasedContrast: Bool
    /// The surface kind as drawn: a glass or blur theme draws solid when glass is off.
    let surfaceKind: ThemeSurfaceKind

    init(theme: Theme, dark: Bool, increasedContrast: Bool = false, allowsGlass: Bool = true) {
        appearance = theme.appearance(dark: dark)
        isDark = theme.fixedAppearance?.isDark ?? dark
        let text = appearance.text
        usesSystemText = text.primary.isSystem && text.secondary.isSystem && text.tertiary.isSystem
        self.increasedContrast = increasedContrast
        surfaceKind = allowsGlass ? appearance.surface.kind : .solid
    }

    /// Glass, light, as the panel draws before anything else is known.
    static let standard = PanelPalette(theme: BuiltInThemes.glass, dark: false)

    // MARK: Text

    var primary: AnyShapeStyle { style(appearance.text.primary) }
    var secondary: AnyShapeStyle { style(appearance.text.secondary) }
    var tertiary: AnyShapeStyle { style(appearance.text.tertiary) }
    var primaryNSColor: NSColor { nsColor(appearance.text.primary) }
    var secondaryNSColor: NSColor { nsColor(appearance.text.secondary) }
    var accentNSColor: NSColor { nsColor(appearance.accent) }

    /// The theme's accent, or nil for the system accent, which the panel leaves to the system.
    var accentOverride: Color? {
        if case .system(.accent, 100) = appearance.accent { return nil }
        return color(appearance.accent)
    }

    // MARK: Boxes and lines

    var ownerFill: AnyShapeStyle { fill(appearance.ownerMessage) }
    var ownerEdge: AnyShapeStyle { edge(appearance.ownerMessage) }
    var agentFill: AnyShapeStyle { fill(appearance.agentReply) }
    var agentEdge: AnyShapeStyle { edge(appearance.agentReply) }
    var goAheadFill: AnyShapeStyle { fill(appearance.goAhead) }
    var goAheadEdge: AnyShapeStyle { edge(appearance.goAhead) }
    /// The text field drawn as a pill, with the panel with bars experiment on: the theme's
    /// `field`, or one derived from its primary text. Increase Contrast strengthens it as it
    /// does the boxes.
    var fieldFill: AnyShapeStyle { fill(appearance.fieldBox) }
    var fieldEdge: AnyShapeStyle { edge(appearance.fieldBox) }
    var incognitoBadge: AnyShapeStyle { style(appearance.incognito.badge) }
    /// The bracket around code and command output.
    var code: AnyShapeStyle { style(appearance.code) }

    /// The hairlines between episodes. Increase Contrast makes them stronger, as it does edges.
    var divider: AnyShapeStyle { style(contrasted(appearance.divider)) }
    /// The line above the text field, which sits closer to the text and is fainter.
    var inputDivider: AnyShapeStyle { style(scaled(appearance.divider, by: 0.36)) }

    /// A box's fill. Increase Contrast makes it a third stronger.
    private func fill(_ box: ThemeBox) -> AnyShapeStyle {
        style(increasedContrast ? scaled(box.fill, by: 1.3) : box.fill)
    }

    /// A box's edge. Increase Contrast draws it at least at 35 percent and two and a half
    /// times as strong, and an edge the theme leaves empty takes the box's fill at full
    /// strength. For Glass this is exactly how the panel drew before themes.
    private func edge(_ box: ThemeBox) -> AnyShapeStyle {
        guard increasedContrast else { return style(box.edge) }
        if box.edge.opacity == 0 { return style(scaled(box.fill, toOpacity: 1)) }
        return style(contrasted(box.edge))
    }

    private func contrasted(_ color: ThemeColor) -> ThemeColor {
        guard increasedContrast else { return color }
        return scaled(color, toOpacity: min(1, max(0.35, color.opacity * 2.5)))
    }

    // MARK: Surface

    /// The tint laid into glass or over blur, with the incognito tint over it while one is on.
    func surfaceTint(incognito: Bool) -> Color? {
        let tint = appearance.surface.tint
        guard incognito else { return tint.map(color) }
        let incognitoTint = appearance.incognito.tint
        guard let tint, case .hex = tint, case .hex = incognitoTint else { return color(incognitoTint) }
        let mixed = incognitoTint.resolved(dark: isDark).over(tint.resolved(dark: isDark))
        return Color(.sRGB, red: mixed.red, green: mixed.green, blue: mixed.blue, opacity: mixed.alpha)
    }

    var fallbackFill: Color { color(appearance.surface.fill) }

    /// The fill of the panel's bars: the top bar, the band with the text field and the footer
    /// under it, and the inspector's bar. The conversation between them keeps the surface, so
    /// the panel reads as bar, conversation, bar. It is a tint laid over the surface, so on
    /// glass and blur the glass shows through it. A theme may set it with `bar`. Without that
    /// it is the primary text at 3 percent, as `textTint` draws it, which is exactly the fill
    /// the suggestions experiment's footer had.
    var bar: AnyShapeStyle {
        appearance.bar.map(style) ?? textTint(ThemeAppearance.derivedBarStrength)
    }
    var incognitoTint: Color { color(appearance.incognito.tint) }

    // MARK: Colors

    /// A theme color as a style. A system label color is a hierarchical style while the
    /// theme's text is the system's, so it keeps the system's vibrancy.
    func style(_ color: ThemeColor) -> AnyShapeStyle {
        switch color {
        case .hex:
            return AnyShapeStyle(self.color(color))
        case .system(let system, let percent):
            let opacity = Double(percent) / 100
            guard usesSystemText else { return AnyShapeStyle(self.color(color)) }
            switch system {
            case .label: return opacity == 1 ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary.opacity(opacity))
            case .secondaryLabel: return opacity == 1 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.secondary.opacity(opacity))
            case .tertiaryLabel: return opacity == 1 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tertiary.opacity(opacity))
            case .accent: return AnyShapeStyle(self.color(color))
            }
        }
    }

    func color(_ color: ThemeColor) -> Color {
        Color(nsColor: nsColor(color))
    }

    func nsColor(_ color: ThemeColor) -> NSColor {
        switch color {
        case .hex(let red, let green, let blue, let alpha):
            return NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: CGFloat(alpha) / 255)
        case .system(let system, let percent):
            // The accent the owner picked, which stays in color while the app is inactive.
            // The panel never activates the app, so `Color.accentColor` would turn gray.
            let base: NSColor = switch system {
            case .label: .labelColor
            case .secondaryLabel: .secondaryLabelColor
            case .tertiaryLabel: .tertiaryLabelColor
            case .accent: .controlAccentColor
            }
            return percent == 100 ? base : base.withAlphaComponent(base.alphaComponent * CGFloat(percent) / 100)
        }
    }

    private func scaled(_ color: ThemeColor, by factor: Double) -> ThemeColor {
        scaled(color, toOpacity: min(1, color.opacity * factor))
    }

    private func scaled(_ color: ThemeColor, toOpacity opacity: Double) -> ThemeColor {
        color.scaled(toOpacity: opacity)
    }

    /// The match card's fill as one opaque, plain color: the field's fill over the bars' fill
    /// over the surface's own fill, over the window background. It is how the pill looks at rest
    /// on a solid surface. Plain, because the system label tints are drawn vibrant inside the
    /// panel's glass, and in slide over that reads as a light gray.
    var matchCardFill: Color {
        let window = isDark ? RGBA(red: 0.118, green: 0.118, blue: 0.118) : RGBA(red: 0.925, green: 0.925, blue: 0.925)
        let field = increasedContrast ? scaled(appearance.fieldBox.fill, by: 1.3) : appearance.fieldBox.fill
        let mixed = [appearance.surface.fill, appearance.barFill, field].reduce(window) { $1.resolved(dark: isDark).over($0) }
        return Color(.sRGB, red: mixed.red, green: mixed.green, blue: mixed.blue, opacity: 1)
    }
}

extension EnvironmentValues {
    /// The active theme as the panel draws it. Set at the panel's root by `SummonView`.
    @Entry var panelPalette = PanelPalette.standard
}

extension View {
    /// Draws the panel's surface from the theme: Liquid Glass, a frosted blur with its tint,
    /// or the solid fill, with the incognito tint while an incognito episode is on.
    /// - Parameter squareEdges: the sides flush against the screen's edge, whose corners are
    ///   square. See `PanelShape.surface(squareEdges:)`.
    /// - Parameter cornerRadius: the panel's outer radius, which the panel with bars
    ///   experiment makes larger. See `PanelFrame.cornerRadius(panelWithBars:)`.
    func panelSurface(
        _ palette: PanelPalette, incognito: Bool, squareEdges: Set<PanelEdge> = [],
        cornerRadius: CGFloat = PanelShape.cornerRadius
    ) -> some View {
        modifier(PanelSurface(
            palette: palette, incognito: incognito,
            shape: PanelShape.surface(squareEdges: squareEdges, radius: cornerRadius)))
    }

    /// Sets the hierarchical text levels and the accent to the theme's own, unless the theme
    /// uses the system's.
    func panelText(_ palette: PanelPalette) -> some View {
        modifier(PanelText(palette: palette))
    }
}

private struct PanelText: ViewModifier {
    let palette: PanelPalette

    func body(content: Content) -> some View {
        if palette.usesSystemText {
            content.tint(palette.accentOverride)
        } else {
            content
                .foregroundStyle(palette.primary, palette.secondary, palette.tertiary)
                .tint(palette.accentOverride)
        }
    }
}

private struct PanelSurface: ViewModifier {
    let palette: PanelPalette
    let incognito: Bool
    let shape: UnevenRoundedRectangle
    /// Within the window, for small previews over a sample backdrop, instead of behind it.
    var blursWithinWindow = false

    func body(content: Content) -> some View {
        // The content is clipped to the surface's shape too, so a fill inside it, such as the
        // bars', never shows past a rounded corner, whether or not the window clips its layer.
        let content = content.clipShape(shape)
        switch palette.surfaceKind {
        case .glass:
            let tint = palette.surfaceTint(incognito: incognito)
            content.glassEffect(tint.map { .regular.tint($0) } ?? .regular, in: shape)
        case .blur:
            content.background {
                ZStack {
                    VisualEffectBackground(dark: palette.isDark, withinWindow: blursWithinWindow)
                    if let tint = palette.surfaceTint(incognito: incognito) {
                        Rectangle().fill(tint)
                    }
                }
                .clipShape(shape)
            }
        case .solid:
            content.background {
                ZStack {
                    Rectangle().fill(palette.fallbackFill)
                    if incognito { Rectangle().fill(palette.incognitoTint) }
                }
                .clipShape(shape)
            }
        }
    }
}

extension View {
    /// The panel's surface for a small preview, blurring the preview's own backdrop.
    func previewSurface(_ palette: PanelPalette, cornerRadius: CGFloat) -> some View {
        modifier(PanelSurface(
            palette: palette, incognito: false,
            shape: UnevenRoundedRectangle(cornerRadii: .init(
                topLeading: cornerRadius, bottomLeading: cornerRadius, bottomTrailing: cornerRadius,
                topTrailing: cornerRadius), style: .continuous),
            blursWithinWindow: true))
    }
}

/// A frosted blur of what is behind the window, for a theme with a blur surface.
struct VisualEffectBackground: NSViewRepresentable {
    let dark: Bool
    var withinWindow = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        update(view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        update(view)
    }

    private func update(_ view: NSVisualEffectView) {
        view.material = dark ? .hudWindow : .popover
        view.blendingMode = withinWindow ? .withinWindow : .behindWindow
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }
}

/// Holds the panel's window to a theme's only appearance, so system controls such as buttons
/// and the text field match it, and lets it follow the Mac again for a theme with both.
struct WindowAppearance: NSViewRepresentable {
    let fixed: ThemeAppearanceKind?

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let appearance = fixed.flatMap { NSAppearance(named: $0 == .dark ? .darkAqua : .aqua) }
        DispatchQueue.main.async {
            if view.window?.appearance != appearance { view.window?.appearance = appearance }
        }
    }
}

extension PanelPalette {
    var tertiaryNSColor: NSColor { nsColor(appearance.text.tertiary) }

    /// The primary text color at a fraction of its strength, for quiet fills such as a selected
    /// row, table striping, and diff lines.
    func textTint(_ opacity: Double) -> AnyShapeStyle {
        let primary = appearance.text.primary
        switch primary {
        case .system where usesSystemText:
            return AnyShapeStyle(.primary.opacity(opacity))
        default:
            return AnyShapeStyle(color(primary).opacity(opacity))
        }
    }
}

extension View {
    /// The root of a window that draws with the active theme, the panel or the inspector beside
    /// it: the palette for the views inside, the text levels and accent, the surface, and the
    /// window held to a theme's only appearance.
    func themedPanel(incognito: Bool = false) -> some View {
        modifier(ThemedPanelRoot(incognito: incognito))
    }

    /// The root of a window that draws with the active theme but has no surface of its own,
    /// such as the part of the match card below the panel: the palette, the text levels and
    /// accent, and the window held to a theme's only appearance.
    func themedWithoutSurface() -> some View {
        modifier(ThemedPanelRoot(incognito: false, drawsSurface: false))
    }
}

private struct ThemedPanelRoot: ViewModifier {
    let incognito: Bool
    var drawsSurface = true
    /// A model of its own for an offscreen render, which must not read the owner's themes
    /// folder. The app sets none, and the panel draws from the shared model.
    @Environment(ThemeModel.self) private var injectedModel: ThemeModel?
    /// The panel's place, to square the corners on a side flush against the screen's edge.
    /// The inspector has none, so its corners are always rounded.
    @Environment(PanelPlacement.self) private var placement: PanelPlacement?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let model = injectedModel ?? ThemeModel.shared
        let theme = model.activeTheme
        let palette = PanelPalette(
            theme: theme, dark: colorScheme == .dark, increasedContrast: contrast == .increased,
            allowsGlass: model.usesGlass && !reduceTransparency)
        if drawsSurface {
            content
                .alwaysAppearsActive()
                .panelText(palette)
                .environment(\.panelPalette, palette)
                .panelSurface(
                    palette, incognito: incognito, squareEdges: placement?.squareEdges ?? [],
                    cornerRadius: placement?.cornerRadius ?? PanelShape.cornerRadius)
                .background(WindowAppearance(fixed: theme.fixedAppearance))
        } else {
            content
                .alwaysAppearsActive()
                .panelText(palette)
                .environment(\.panelPalette, palette)
                .background(WindowAppearance(fixed: theme.fixedAppearance))
        }
    }
}


extension View {
    /// Draws the views inside as they look while their window has keyboard focus, whether or
    /// not it has. The panel looks the same when the owner clicks another app (MAC-88): SwiftUI
    /// otherwise draws controls in an unfocused window in their inactive look, with the accent
    /// and the theme's tint gone gray from prominent buttons, toggles, and pickers.
    ///
    /// It covers what SwiftUI draws from `appearsActive`. Liquid Glass reads the window's own
    /// active look instead, which `ActiveAppearancePanel` holds. Nothing in the app reads
    /// `appearsActive` for behavior, so this changes looks only.
    func alwaysAppearsActive() -> some View {
        environment(\.appearsActive, true)
    }
}
