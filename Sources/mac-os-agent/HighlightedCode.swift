import MacOSAgentCore
import SwiftUI

/// Colors for `CodeHighlighting`'s spans, after Xcode's default theme in each appearance, so
/// code reads the way it does in Apple's own tools. Text outside a span keeps the primary
/// color, and punctuation is quieter.
enum HighlightedCode {
    /// The text with its spans colored. The characters are the text's own, so selecting and
    /// copying it gives back exactly what was shown.
    static func attributed(_ text: String, spans: [CodeHighlighting.Span], dark: Bool) -> AttributedString {
        var result = AttributedString(text)
        for span in spans {
            guard let range = Range(span.range, in: result) else { continue }
            if span.kind == .heading {
                result[range].inlinePresentationIntent = .stronglyEmphasized
            } else {
                result[range].foregroundColor = color(span.kind, dark: dark)
            }
        }
        return result
    }

    static func color(_ kind: CodeHighlighting.Kind, dark: Bool) -> Color {
        switch kind {
        case .command: hex(dark ? 0xFF7AB2 : 0x9B2393)
        case .variable: hex(dark ? 0x67B7A4 : 0x326D74)
        case .string: hex(dark ? 0xFC6A5D : 0xC41A16)
        case .comment: hex(dark ? 0x7F8C98 : 0x5D6C79)
        case .option: hex(dark ? 0xFD8F3F : 0x643820)
        case .number, .literal: hex(dark ? 0xD9C97C : 0x1C00CF)
        case .type, .inlineCode: hex(dark ? 0x5DD8FF : 0x0B4F79)
        case .key: hex(dark ? 0x4EB0CC : 0x0F68A0)
        case .punctuation: .secondary
        case .heading: .primary
        }
    }

    private static func hex(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}

/// Monospaced text with best-effort highlighting, selectable, wrapping at the view's width.
struct HighlightedCodeText: View {
    let text: String
    let spans: [CodeHighlighting.Span]
    var size: CGFloat = 11

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(HighlightedCode.attributed(text, spans: spans, dark: colorScheme == .dark))
            .font(.system(size: size, design: .monospaced))
            .lineSpacing(2.5)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
