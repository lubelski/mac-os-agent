import AppKit
import MacOSAgentCore
import SwiftUI

// The panel with bars and an input pill (`Experiment.panelWithBarsAndInputPill`), first slice:
// the frame. The panel reads as bar, conversation, band. See `planning/panel-with-input-pill.md`.
//
// - The title bar is `PanelTopBar` with `style: .titled`: the model's name at the left as a
//   label, "MacOS Agent" centered, and the menu at the right.
// - The band at the bottom is `InputBand`: a slot for a row above the pill (task links, a later
//   slice), the pill, `InputPill`, and the status line, `InputFooter` with `statusLine: true`.
// - The mark at the left of the pill is `LogoMark`, which never changes.
// - The radii are `PanelFrame`'s: an inner radius is the outer radius less the gap.
//
// With the switch on, the suggestions experiment's gray completion, status line, and list are
// on too, whatever that switch says. See `AgentSession.suggestionsInFooter`.

/// The measures of the frame with the experiment on.
enum PanelFrame {
    /// The panel's outer corners.
    static let panelCornerRadius: CGFloat = 16
    /// The gap from the panel's edges to the pill inside the band.
    static let inset: CGFloat = 8
    /// The pill's corners: the panel's radius less the inset.
    static let pillCornerRadius: CGFloat = panelCornerRadius - inset
    /// The pill's height with one line of text.
    static let pillHeight: CGFloat = 38
    /// The space from the pill's side to the mark, and from the text to the pill's far side.
    static let pillPadding: CGFloat = 12
    /// The mark's width, and the gap between it and the text.
    static let markWidth: CGFloat = 12
    static let markGap: CGFloat = 9

    static let pill = RoundedRectangle(cornerRadius: pillCornerRadius, style: .continuous)

    /// The panel's outer radius for a window, with the experiment on or off.
    static func cornerRadius(panelWithBars: Bool) -> CGFloat {
        panelWithBars ? panelCornerRadius : PanelShape.cornerRadius
    }
}

extension AgentSession {
    /// Whether the panel with bars and an input pill is on for this window. Read each time, so
    /// the switch in Settings applies at once.
    var panelWithBars: Bool {
        forcedPanelWithBars ?? Experiment.panelWithBarsAndInputPill.isOn(preferences)
    }
}

/// The band at the bottom of the panel with the experiment on, on the bars' fill under the
/// hairline: a row above the pill when there is one, then the pill. The status line follows it
/// outside this view, so the suggestion list can sit between them as it does in the
/// suggestions experiment.
///
/// `aboveField` is the room for the task links of a later slice. It is drawn only when given,
/// so with none the band starts with the pill.
struct InputBand<AboveField: View, Field: View>: View {
    @ViewBuilder var aboveField: AboveField
    @ViewBuilder var field: Field

    var body: some View {
        VStack(spacing: 0) {
            aboveField
            field
                .padding(.horizontal, PanelFrame.inset)
                .padding(.top, PanelFrame.inset)
        }
        .frame(maxWidth: .infinity)
        .background(PanelBarFill())
    }
}

extension InputBand where AboveField == EmptyView {
    init(@ViewBuilder field: () -> Field) {
        self.init(aboveField: { EmptyView() }, field: field)
    }
}

/// The text field as a pill: the mark at its left, then the text, on the theme's field fill
/// with its edge around it. 38 points tall for one line. A second line makes it a taller box
/// with the same corners, which grows upward because the band is at the bottom of the panel,
/// up to `InputField.maximumLines`, and then the text scrolls inside it. Nothing else goes in it.
///
/// While a match shows, the pill is one end of the match card, `card` says which: the card's top
/// when it opens downward, and its bottom when it opens upward. It is then on the card's opaque
/// fill, with square corners where the rest of the card joins it. See `MatchCard`.
struct InputPill<Field: View>: View {
    var card: MatchCardSide? = nil
    @ViewBuilder var field: Field
    @Environment(\.panelPalette) private var palette

    var body: some View {
        // One chain whatever the state, so the field keeps its identity, and with it keyboard
        // focus, the undo stack, and any text an input method is composing.
        HStack(alignment: .top, spacing: PanelFrame.markGap) {
            LogoMark()
                .frame(width: PanelFrame.markWidth, height: InputFieldMetrics.pill.rowHeight)
            field
        }
        .padding(.horizontal, PanelFrame.pillPadding)
        .frame(minHeight: PanelFrame.pillHeight)
        .background {
            if let card {
                MatchCardFill().clipShape(shape(card))
            } else {
                PanelFrame.pill.fill(palette.fieldFill)
            }
        }
        .overlay {
            if let card {
                // Opening downward, the pill draws the hairline between it and the rows.
                // Opening upward, the rows draw it, so the pill leaves its top open.
                MatchCardEdge(shape: shape(card), openTop: card == .above)
            } else {
                PanelFrame.pill.strokeBorder(palette.fieldEdge, lineWidth: 1)
            }
        }
    }

    private func shape(_ card: MatchCardSide) -> UnevenRoundedRectangle {
        MatchCard.shape(top: card == .below, bottom: card == .above)
    }
}
