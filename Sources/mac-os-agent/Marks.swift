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
enum Mark {
    static let call = "›"
    static let failed = "✗"
    static let branch = "│"
    static let lastBranch = "└"
    static let bracketTop = "┌──"
    static let bracketBottom = "└──"
    static let prompt = "›"
    static let up = "↑"
    static let down = "↓"

    /// The font of tool rows and their marks.
    static let rowFont = Font.system(size: 11, design: .monospaced)
    /// The width of one character of `rowFont`, which is the mark's column.
    static let rowColumn: CGFloat = 13
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
    /// A command as text, with the program in the secondary level and the rest in the tertiary.
    static func text(for command: String) -> Text {
        ToolSignal.command(command).reduce(Text(verbatim: "")) { text, segment in
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
