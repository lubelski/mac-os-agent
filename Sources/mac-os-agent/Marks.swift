import MacOSAgentCore
import SwiftUI

/// The marks the conversation uses in place of icons: plain characters in the text color, at
/// secondary and tertiary levels, never in green or red.
///
/// They come from the owner's Pi customizations (agent-customizations, `pi/lib/ui/tools.ts`
/// and `pi/lib/ui/code.ts`):
/// - `›` starts a tool call's one-line row.
/// - `✗` starts the row of a call that failed, in place of `›`.
/// - `│` and `└` branch from a row, beneath the start of its command, for the line that says
///   what is happening or why it failed.
/// - A code block is held by an open bracket: its label or `┌──` above, a `│` rule down its
///   left side, and `└──` below.
/// - `↑`, `↓`, and `↵` stand in for arrows, as in Pi's footer hints.
///
/// The text field's own mark is the one symbol among them: the SF Symbol `sparkle`, the single
/// four-pointed star, drawn by `PromptMark`.
enum Mark {
    static let call = "›"
    static let failed = "✗"
    static let branch = "│"
    static let lastBranch = "└"
    static let bracketTop = "┌──"
    static let bracketBottom = "└──"
    /// The SF Symbol the text field starts with: one four-pointed star, not `sparkles`.
    static let promptSymbol = "sparkle"
    static let up = "↑"
    static let down = "↓"
    static let returnKey = "↵"
    static let commandReturn = "⌘↵"

    /// The font of tool rows and their marks.
    static let rowFont = Font.system(size: 11, design: .monospaced)
    /// The width of one character of `rowFont`, which is the mark's column.
    static let rowColumn: CGFloat = 13
}

/// The text field's resting mark, the four-pointed sparkle, in the secondary level. The field,
/// the list's Ask row, and the theme samples in Settings all draw this one view, so every
/// picture of the field matches the field.
struct PromptMark: View {
    /// The point size of the symbol.
    var size: CGFloat = 13

    var body: some View {
        Image(systemName: Mark.promptSymbol)
            .font(.system(size: size))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }
}

extension ToolSignal.Tone {
    /// Tool rows sit a level below the prose: what a reader scans for in the secondary level,
    /// everything else in the tertiary level.
    var style: HierarchicalShapeStyle {
        switch self {
        case .text: .secondary
        case .dim: .tertiary
        }
    }
}

extension ToolSignal {
    /// A tool call's summary as text, with its first word in the secondary level and the rest
    /// in the tertiary.
    static func text(for summary: String, lead: String? = nil) -> Text {
        ToolSignal.summary(summary, lead: lead).reduce(Text(verbatim: "")) { text, segment in
            Text("\(text)\(Text(verbatim: segment.text).foregroundStyle(segment.tone.style))")
        }
    }
}

/// Code or command text held by an open bracket on its left, in the scheme of Pi's code
/// blocks: the label, or `┌──` when there is none, then a `│` rule beside each line, then `└──`.
/// The text scrolls sideways instead of wrapping, so lines keep their shape.
struct CodeBracket<Content: View, Accessory: View>: View {
    @Environment(\.panelPalette) private var palette
    var label: String?
    var font: Font = .system(size: 11, design: .monospaced)
    /// False lets the bracket hug its content instead of taking the width it is offered.
    var fillsWidth = true
    @ViewBuilder var content: Content
    /// Sits on the label's line, after the label, such as a copy control.
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: label?.isEmpty == false ? label! : Mark.bracketTop)
                    .foregroundStyle(palette.code)
                    .accessibilityHidden(label == nil)
                accessory
            }
            // The rule is drawn beside the content and takes its height, never more.
            content
                .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(palette.code)
                        .frame(width: 1)
                        .padding(.leading, 3)
                        .accessibilityHidden(true)
                }
            Text(verbatim: Mark.bracketBottom)
                .foregroundStyle(palette.code)
                .accessibilityHidden(true)
        }
        .font(font)
    }
}

extension CodeBracket where Accessory == EmptyView {
    init(label: String? = nil, font: Font = .system(size: 11, design: .monospaced), fillsWidth: Bool = true,
         @ViewBuilder content: () -> Content)
    {
        self.init(label: label, font: font, fillsWidth: fillsWidth, content: content, accessory: { EmptyView() })
    }
}

/// One line that branches from a tool row: `└` beneath the start of the command, then text.
struct BranchLine: View {
    let text: String
    var style: HierarchicalShapeStyle = .tertiary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: Mark.lastBranch)
                .foregroundStyle(.tertiary)
                .frame(width: Mark.rowColumn, alignment: .leading)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .foregroundStyle(style)
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
        }
        .font(Mark.rowFont)
        .padding(.leading, Mark.rowColumn)
    }
}

/// The app's new logo: a plain triangle pointing right, close to equilateral, with slightly
/// rounded tips. Drawn as a shape, with no image, so it is sharp at any size and takes any
/// color. It fits the largest such triangle in the rect, centered.
struct LogoTriangle: Shape {
    /// How round the tips are, as a fraction of a side.
    var tipRoundness: CGFloat = 0.14

    func path(in rect: CGRect) -> Path {
        // An equilateral triangle pointing right is √3/2 of its side wide and a side tall.
        let width = (3.0 as CGFloat).squareRoot() / 2
        let side = min(rect.height, rect.width / width)
        let size = CGSize(width: side * width, height: side)
        let origin = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        let top = origin
        let tip = CGPoint(x: origin.x + size.width, y: rect.midY)
        let bottom = CGPoint(x: origin.x, y: origin.y + size.height)
        let radius = side * tipRoundness
        var path = Path()
        // Start halfway along the left side, so every tip is rounded by the same arc.
        path.move(to: CGPoint(x: origin.x, y: rect.midY))
        path.addArc(tangent1End: top, tangent2End: tip, radius: radius)
        path.addArc(tangent1End: tip, tangent2End: bottom, radius: radius)
        path.addArc(tangent1End: bottom, tangent2End: top, radius: radius)
        path.closeSubpath()
        return path
    }
}

/// The mark at the left of the pill with the panel with bars experiment on: the logo, in the
/// theme's accent. It never changes. It does not become the icon of what Return will act on.
struct LogoMark: View {
    /// The triangle's height, its longest extent.
    var size: CGFloat = 12
    @Environment(\.panelPalette) private var palette

    var body: some View {
        LogoTriangle()
            .fill(palette.color(palette.appearance.accent))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
