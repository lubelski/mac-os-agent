import AppKit
import SwiftUI

/// The panel's text input: a plain AppKit text view, so it has the whole Mac text system with
/// nothing reimplemented. The Edit menu's commands, the key bindings (Option and Command
/// arrows, Control-A, Control-K, and the rest), input methods, spelling, text replacement,
/// dictation, the emoji picker, Writing Tools, Services, and the context menu all come from
/// `NSTextView` itself.
///
/// It grows a line at a time up to `maximumLines`, then scrolls. Return sends, and Shift-Return
/// and Option-Return add a line.
///
/// A vertical SwiftUI `TextField` was the first choice, and it does most of this. It was set
/// aside because an undo in it changes the text on screen without updating the text it is
/// bound to, so Return after Command-Z sent the text from before the undo.
struct InputField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var isEnabled: Bool
    /// Each new value moves keyboard focus into the field.
    var focusRequest: Int
    var onSubmit: () -> Void
    var onCancel: () -> Void
    /// Up (-1) or Down (1) in an empty field. Returns true when it used the key, such as to move
    /// between tool calls in the inspector. Otherwise the text view handles it as usual.
    var onMove: (Int) -> Bool = { _ in false }

    static let font = NSFont.systemFont(ofSize: 15)
    static let maximumLines = 8
    /// The height of one line of text, and so of the field when it holds one line.
    static let lineHeight = ceil(font.ascender - font.descender + font.leading)
    /// The space above and below the text, so a single line sits centered in a row this tall.
    static let rowHeight: CGFloat = 28
    static let verticalInset = (rowHeight - lineHeight) / 2

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = InputTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let textView = scrollView.documentView as! InputTextView
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = false
        textView.drawsBackground = false
        textView.font = Self.font
        textView.textColor = .labelColor
        textView.typingAttributes = [.font: Self.font, .foregroundColor: NSColor.labelColor]
        textView.textContainerInset = NSSize(width: 0, height: Self.verticalInset)
        textView.textContainer?.lineFragmentPadding = 0
        // Spelling is checked as you type, as in Messages and Mail. The Edit menu and the
        // context menu turn it off. Text replacement, autocorrection, and smart quotes and
        // dashes start from the owner's settings in System Settings > Keyboard, as in any
        // text view.
        textView.isContinuousSpellCheckingEnabled = true
        textView.setAccessibilityLabel(placeholder)
        textView.setAccessibilityPlaceholderValue(placeholder)

        textView.string = text
        context.coordinator.observe(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = scrollView.documentView as? InputTextView else { return }

        // Text set from outside, such as the field clearing after a send. Never while an
        // input method is composing, which would throw away what is being composed.
        if textView.string != text, !textView.hasMarkedText() {
            coordinator.isSettingText = true
            textView.string = text
            coordinator.isSettingText = false
            // The undo stack refers to text that is no longer there. The panel's undo manager
            // serves only this field.
            textView.undoManager?.removeAllActions()
        }
        textView.isEditable = isEnabled
        // The theme's text colors, and its accent for the cursor.
        let palette = context.environment.panelPalette
        let color = isEnabled ? palette.primaryNSColor : palette.secondaryNSColor
        if textView.textColor != color {
            textView.textColor = color
            textView.typingAttributes[.foregroundColor] = color
        }
        if palette.accentOverride != nil {
            textView.insertionPointColor = palette.accentNSColor
        }

        if coordinator.focusRequest != focusRequest {
            coordinator.focusRequest = focusRequest
            coordinator.focusWhenPossible(textView)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scrollView: NSScrollView, context: Context) -> CGSize? {
        guard let textView = scrollView.documentView as? NSTextView, let width = proposal.width ?? Optional(scrollView.frame.width) else {
            return nil
        }
        return CGSize(width: width, height: Self.height(of: textView, width: width))
    }

    /// The field's height for its text at this width: one line at least, `maximumLines` at most.
    static func height(of textView: NSTextView, width: CGFloat) -> CGFloat {
        var textHeight = lineHeight
        if let layout = textView.textLayoutManager, let container = layout.textContainer, width > 0 {
            if container.size.width != width {
                container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
            }
            layout.ensureLayout(for: layout.documentRange)
            textHeight = max(lineHeight, layout.usageBoundsForTextContainer.height)
        }
        let limit = lineHeight * CGFloat(maximumLines)
        return ceil(min(textHeight, limit) + verticalInset * 2)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InputField
        var focusRequest: Int?
        var isSettingText = false
        private var storageObserver: (any NSObjectProtocol)?
        private weak var textView: NSTextView?

        init(_ parent: InputField) {
            self.parent = parent
        }

        /// Every change to the text reaches the binding, whatever made it: typing, paste,
        /// dictation, an input method, or undo and redo, which skip the text view's own change
        /// notifications.
        func observe(_ textView: NSTextView) {
            self.textView = textView
            // Delivered right away on the main thread, where text views post it.
            storageObserver = NotificationCenter.default.addObserver(
                forName: NSTextStorage.didProcessEditingNotification, object: textView.textStorage, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.textDidChangeInStorage() }
            }
        }

        private func textDidChangeInStorage() {
            guard !isSettingText, let string = textView?.string, parent.text != string else { return }
            parent.text = string
        }

        func focusWhenPossible(_ textView: InputTextView) {
            if let window = textView.window {
                window.makeFirstResponder(textView)
            } else {
                textView.takesFocusInWindow = true
            }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let modifiers = (textView as? InputTextView)?.currentKeyModifiers ?? []
            switch InputCommand(selector, modifiers: modifiers, composing: textView.hasMarkedText()) {
            case .send:
                parent.onSubmit()
                return true
            case .newLine:
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            case .cancel:
                parent.onCancel()
                return true
            case .standard:
                if textView.string.isEmpty {
                    if selector == #selector(NSResponder.moveUp(_:)) { return parent.onMove(-1) }
                    if selector == #selector(NSResponder.moveDown(_:)) { return parent.onMove(1) }
                }
                return false
            }
        }
    }
}

/// What a text command from the key bindings does in the input field.
enum InputCommand: Equatable {
    /// Send the text.
    case send
    /// Add a line break.
    case newLine
    /// Hide the panel.
    case cancel
    /// Whatever the text view does with it.
    case standard

    init(_ selector: Selector, modifiers: NSEvent.ModifierFlags, composing: Bool) {
        // An input method that is composing gets every key as usual.
        if composing {
            self = .standard
            return
        }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            // Shift-Return has no binding of its own, so it arrives as Return.
            self = modifiers.intersection(.deviceIndependentFlagsMask).contains(.shift) ? .newLine : .send
        case #selector(NSResponder.insertLineBreak(_:)):
            // Control-Return. A plain line break, not a line separator character.
            self = .newLine
        case #selector(NSResponder.cancelOperation(_:)):
            // Escape. A text view would otherwise offer word completions.
            self = .cancel
        default:
            // Option-Return is insertNewlineIgnoringFieldEditor:, which adds a line on its own.
            self = .standard
        }
    }
}

/// A text view that remembers the modifier keys of the key press it is handling, so a command
/// from the key bindings can tell Return from Shift-Return.
final class InputTextView: NSTextView {
    private(set) var currentKeyModifiers: NSEvent.ModifierFlags = []
    /// Asked for focus before it was in a window.
    var takesFocusInWindow = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if takesFocusInWindow, let window {
            takesFocusInWindow = false
            window.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        currentKeyModifiers = event.modifierFlags
        defer { currentKeyModifiers = [] }
        super.keyDown(with: event)
    }
}
