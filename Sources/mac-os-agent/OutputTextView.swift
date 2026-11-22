import AppKit
import SwiftUI

/// Long monospaced text in a standard read-only text view: selectable, with the system find bar
/// (Command-F), optional line numbers in a gutter, and a choice between wrapping long lines and
/// scrolling sideways. TextKit 2 lays out only what is in view, so very long output scrolls
/// smoothly and setting it does not hold up the conversation.
struct OutputTextView: NSViewRepresentable {
    let text: String
    var wraps: Bool
    var showsLineNumbers: Bool

    static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = false
        textView.font = Self.font
        textView.textColor = .secondaryLabelColor
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.setAccessibilityLabel("Output")

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        scrollView.findBarPosition = .aboveContent
        let ruler = LineNumberRuler(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        context.coordinator.ruler = ruler
        update(scrollView, textView: textView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        update(scrollView, textView: textView, coordinator: context.coordinator)
    }

    private func update(_ scrollView: NSScrollView, textView: NSTextView, coordinator: Coordinator) {
        if coordinator.text != text {
            coordinator.text = text
            let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.secondaryLabelColor]
            textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
            coordinator.ruler?.setLineStarts(for: text)
            textView.scrollToBeginningOfDocument(nil)
        }
        if coordinator.wraps != wraps {
            coordinator.wraps = wraps
            scrollView.hasHorizontalScroller = !wraps
            textView.isHorizontallyResizable = !wraps
            if let container = textView.textContainer {
                container.widthTracksTextView = wraps
                container.containerSize = NSSize(
                    width: wraps ? scrollView.contentSize.width : CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude)
            }
            if wraps {
                textView.frame.size.width = scrollView.contentSize.width
            }
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.needsLayout = true
        }
        scrollView.rulersVisible = showsLineNumbers
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var text: String?
        var wraps: Bool?
        var ruler: LineNumberRuler?
    }
}

/// The gutter of line numbers beside the output. A number marks the first line a logical line
/// takes on screen, so a wrapped line keeps one number.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    /// The UTF-16 offset where each line starts.
    private var lineStarts: [Int] = [0]

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: nil, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 36
        // Without this the default drawing reaches past the gutter, as a line and a band
        // across the rest of the inspector.
        clipsToBounds = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(redraw), name: NSView.frameDidChangeNotification, object: textView)
    }

    required init(coder: NSCoder) { fatalError("not used") }

    func setLineStarts(for text: String) {
        var starts = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 0x0A { starts.append(offset) }
        }
        lineStarts = starts
        let digits = max(3, String(starts.count).count)
        ruleThickness = CGFloat(digits) * 7 + 12
        needsDisplay = true
    }

    @objc private func redraw() { needsDisplay = true }

    override var isOpaque: Bool { false }

    /// Only the numbers: no background and no rule, so the gutter sits on the glass.
    override func draw(_ dirtyRect: NSRect) {
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager
        else { return }
        let visible = textView.visibleRect
        let inset = textView.textContainerInset.height
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let start = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: max(0, visible.minY - inset)))?.rangeInElement.location
            ?? contentManager.documentRange.location
        layoutManager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY + inset > visible.maxY { return false }
            let offset = contentManager.offset(from: contentManager.documentRange.location, to: fragment.rangeInElement.location)
            let line = self.lineIndex(atOffset: offset) + 1
            let firstLine = fragment.textLineFragments.first
            let baseline = (firstLine?.typographicBounds.minY ?? 0) + frame.minY + inset
            let point = self.convert(CGPoint(x: 0, y: baseline), from: textView)
            let label = NSAttributedString(string: String(line), attributes: attributes)
            let size = label.size()
            label.draw(at: CGPoint(x: self.ruleThickness - size.width - 6, y: point.y + 1))
            return true
        }
    }

    private func lineIndex(atOffset offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return low
    }
}
