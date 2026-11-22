import AppKit
import SwiftUI

/// How prompt text is set, in the instructions editor and in the full prompt beside it: the
/// system's monospaced font, one step under the body size, with a little room between lines.
@MainActor
enum PromptText {
    static let fontSize: CGFloat = NSFont.systemFontSize - 1
    static let lineSpacing: CGFloat = 3
    static let nsFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    static let font = Font.system(size: fontSize, design: .monospaced)

    static var attributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        return [.font: nsFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
    }
}

/// The editor for the agent's instructions. It is plain monospaced text that wraps at the
/// editor's width and scrolls only up and down.
///
/// The text is a prompt, so what is typed is what is saved: smart quotes, smart dashes, text
/// replacement, and autocorrection are off. Spell checking is left as the system has it.
struct PromptEditor: NSViewRepresentable {
    @Binding var text: String
    var accessibilityLabel = "Instructions"

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = Self.makeScrollView()
        let textView = scrollView.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.setAccessibilityLabel(accessibilityLabel)
        Self.setText(text, in: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        // A change from outside the editor, such as Revert or Restore Default.
        Self.setText(text, in: textView)
    }

    /// The editor takes the room it is given. Its size never follows its text, so a long line
    /// cannot widen the section or push the sidebar.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 400, height: 240))
    }

    static func makeScrollView() -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = scrollView.documentView as! NSTextView
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = false
        textView.font = PromptText.nsFont
        textView.textColor = .labelColor
        textView.defaultParagraphStyle = PromptText.attributes[.paragraphStyle] as? NSParagraphStyle
        textView.typingAttributes = PromptText.attributes
        textView.textContainerInset = NSSize(width: 0, height: 2)

        // Long lines wrap at the editor's width.
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        // Nothing rewrites what is typed.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        return scrollView
    }

    static func setText(_ text: String, in textView: NSTextView) {
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: PromptText.attributes))
        textView.typingAttributes = PromptText.attributes
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptEditor

        init(_ parent: PromptEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}
