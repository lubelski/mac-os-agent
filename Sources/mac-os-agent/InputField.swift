import AppKit
import MacOSAgentCore
import SwiftUI

/// The panel's text input: a plain AppKit text view, so it has the whole Mac text system with
/// nothing reimplemented. The Edit menu's commands, the key bindings (Option and Command
/// arrows, Control-A, Control-K, and the rest), input methods, spelling, text replacement,
/// dictation, the emoji picker, Writing Tools, Services, and the context menu all come from
/// `NSTextView` itself.
///
/// It grows a line at a time up to `maximumLines`, then scrolls. Return sends, or takes the
/// instant action the row above offers. Command-Return always sends to the agent. Shift-Return
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
    /// Command-Return: sends the text to the agent even when Return would take an instant action.
    var onSubmitToAgent: () -> Void = {}
    /// Up, Shift-Tab (-1) or Down, Tab (1) while the field has text. Returns true when it used
    /// the key, to choose between instant action matches. Otherwise the key does what it always does.
    var onChoose: (Int) -> Bool = { _ in false }
    /// Tab while the field has text, before `onChoose`. Returns true when it used the key, to
    /// complete the command chosen in the list of slash commands.
    var onComplete: () -> Bool = { false }
    /// Up (-1) with the insertion point on the field's first line, or Down (1) on its last line,
    /// after the command list, the instant action row, and the inspector have passed on the
    /// key. Returns true when it put other text in the field, such as an earlier message.
    /// Otherwise the insertion point moves as usual. See `AgentSession.recallMessage(by:)`.
    var onRecall: (Int) -> Bool = { _ in false }
    /// Control-C. Returns true when it used the key, to stop the task or clear the field.
    /// Otherwise the key goes to the text view as before. Command-C is never this.
    var onInterrupt: () -> Bool = { false }
    /// Delete twice in quick succession with the field already empty, both distinct presses
    /// and neither a key repeat. Returns true when it used the key, to start a new episode as
    /// `/new` does. Otherwise the key goes to the text view as before. See `DoubleDelete`.
    var onDoubleDelete: () -> Bool = { false }
    /// Called with true when an input method starts composing in the field, and with false when
    /// it stops. While it composes, the field's text holds what is being composed, such as the
    /// Latin letters a pinyin or romaji input method shows, which are not yet what was typed.
    var onComposingChange: (Bool) -> Void = { _ in }
    /// Gray text after the insertion point, from the suggestions-in-the-field experiment. It is
    /// drawn only, never part of the text. See `InputTextView.inlineCompletion`.
    var inlineCompletion: InlineCompletion? = nil

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
        textView.onCommandReturn = { [weak coordinator = context.coordinator] in coordinator?.parent.onSubmitToAgent() }
        textView.onControlC = { [weak coordinator = context.coordinator] in coordinator?.parent.onInterrupt() ?? false }
        textView.onDoubleDelete = { [weak coordinator = context.coordinator] in coordinator?.parent.onDoubleDelete() ?? false }
        textView.onComposingChange = { [weak coordinator = context.coordinator] in coordinator?.parent.onComposingChange($0) }
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
        textView.inlineCompletionColor = palette.tertiaryNSColor
        if textView.inlineCompletion != inlineCompletion {
            textView.inlineCompletion = inlineCompletion
        }

        if coordinator.focusRequest != focusRequest {
            coordinator.focusRequest = focusRequest
            // The window was shown again, or something asked for the field: a Delete before
            // it is not the first of two.
            textView.resetDoubleDelete()
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
            // Any change to the text between two presses of Delete, from typing, paste, recall,
            // or the session, starts the count over.
            (textView as? InputTextView)?.resetDoubleDelete()
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
            case .sendToAgent:
                parent.onSubmitToAgent()
                return true
            case .newLine:
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            case .cancel:
                parent.onCancel()
                return true
            case .standard:
                if !textView.string.isEmpty, !textView.hasMarkedText(), selector == #selector(NSResponder.insertTab(_:)),
                   parent.onComplete()
                {
                    return true
                }
                if !textView.string.isEmpty, !textView.hasMarkedText(), let offset = Self.choiceOffset(selector),
                   parent.onChoose(offset)
                {
                    return true
                }
                if textView.string.isEmpty {
                    if selector == #selector(NSResponder.moveUp(_:)), parent.onMove(-1) { return true }
                    if selector == #selector(NSResponder.moveDown(_:)), parent.onMove(1) { return true }
                }
                if !textView.hasMarkedText(), let offset = Self.recallOffset(selector, in: textView), parent.onRecall(offset) {
                    showRecalled(in: textView, movingUp: offset < 0)
                    return true
                }
                return false
            }
        }

        /// Up with the insertion point on the first line, or Down on the last, with nothing
        /// selected. Anywhere else the arrows move the insertion point as they always do.
        static func recallOffset(_ selector: Selector, in textView: NSTextView) -> Int? {
            let selection = textView.selectedRange()
            guard selection.length == 0 else { return nil }
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                return InsertionLine.isFirst(in: textView, at: selection.location) ? -1 : nil
            case #selector(NSResponder.moveDown(_:)):
                return InsertionLine.isLast(in: textView, at: selection.location) ? 1 : nil
            default:
                return nil
            }
        }

        /// Puts the recalled text in the field at once, rather than on SwiftUI's next update, so
        /// the insertion point can go where the next press continues: the start after Up, so
        /// Up again goes further back, and the end after Down.
        private func showRecalled(in textView: NSTextView, movingUp: Bool) {
            let text = parent.text
            if textView.string != text {
                isSettingText = true
                textView.string = text
                isSettingText = false
                textView.undoManager?.removeAllActions()
            }
            let location = movingUp ? 0 : (text as NSString).length
            textView.setSelectedRange(NSRange(location: location, length: 0))
            textView.scrollRangeToVisible(NSRange(location: location, length: 0))
        }

        /// How a key moves between instant action matches: Up and Shift-Tab back, Down and Tab on.
        static func choiceOffset(_ selector: Selector) -> Int? {
            switch selector {
            case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.insertBacktab(_:)): -1
            case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)): 1
            default: nil
            }
        }
    }
}

/// What a text command from the key bindings does in the input field.
enum InputCommand: Equatable {
    /// Send the text, or take the instant action the row offers.
    case send
    /// Send the text to the agent, even when the row offers an instant action. Command-Return.
    case sendToAgent
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
            let flags = modifiers.intersection(.deviceIndependentFlagsMask)
            self = flags.contains(.shift) ? .newLine : flags.contains(.command) ? .sendToAgent : .send
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

/// Whether the insertion point is on the field's first or last line as laid out, so a long
/// message that wraps counts its wrapped lines. Without a window to lay it out in, the line
/// breaks in the text decide.
@MainActor
enum InsertionLine {
    static func isFirst(in textView: NSTextView, at location: Int) -> Bool {
        let text = textView.string as NSString
        if let here = caretRect(textView, location), let start = caretRect(textView, 0) {
            return abs(here.midY - start.midY) < InputField.lineHeight / 2
        }
        return text.range(of: "\n", range: NSRange(location: 0, length: min(location, text.length))).location == NSNotFound
    }

    static func isLast(in textView: NSTextView, at location: Int) -> Bool {
        let text = textView.string as NSString
        if let here = caretRect(textView, location), let end = caretRect(textView, text.length) {
            return abs(here.midY - end.midY) < InputField.lineHeight / 2
        }
        let start = min(location, text.length)
        return text.range(of: "\n", range: NSRange(location: start, length: text.length - start)).location == NSNotFound
    }

    /// Where the insertion point would be drawn at this location, in screen coordinates.
    private static func caretRect(_ textView: NSTextView, _ location: Int) -> NSRect? {
        guard textView.window != nil else { return nil }
        let rect = textView.firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil)
        return rect == .zero ? nil : rect
    }
}

/// A text view that remembers the modifier keys of the key press it is handling, so a command
/// from the key bindings can tell Return from Shift-Return.
final class InputTextView: NSTextView {
    private(set) var currentKeyModifiers: NSEvent.ModifierFlags = []
    /// Asked for focus before it was in a window.
    var takesFocusInWindow = false
    /// Command-Return. AppKit offers a Command key press to the views as a key equivalent and
    /// never turns it into a text command, so it is caught here.
    var onCommandReturn: (() -> Void)?
    /// Control-C. Returns true when it used the key.
    var onControlC: (() -> Bool)?
    /// The second of two quick presses of Delete in an empty field. Returns true when it used the key.
    var onDoubleDelete: (() -> Bool)?
    /// An input method started (true) or stopped (false) composing.
    var onComposingChange: ((Bool) -> Void)?
    private var wasComposing = false
    /// How close two presses of Delete have to be. The system's double-click interval, read at
    /// each press so a change in System Settings applies at once.
    var doubleDeleteInterval: () -> TimeInterval = { NSEvent.doubleClickInterval }
    private(set) var doubleDelete = DoubleDelete(interval: NSEvent.doubleClickInterval)
    /// While a first press waits for a second: sees every click and key in the app, so one in
    /// between, anywhere, starts the count over, including a key that a menu takes before it
    /// would reach this view.
    private var doubleDeleteMonitor: Any?
    private var resignKeyObserver: (any NSObjectProtocol)?

    /// Delete with no modifier, by its key code, as the key bindings read it.
    static func isPlainDelete(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        return event.type == .keyDown && event.keyCode == 51 && flags.isEmpty
    }

    func resetDoubleDelete() {
        doubleDelete.reset()
        if let doubleDeleteMonitor {
            NSEvent.removeMonitor(doubleDeleteMonitor)
            self.doubleDeleteMonitor = nil
        }
    }

    /// One press of Delete. True when it was the second of two in an empty field and the
    /// owner's handler used it.
    private func handleDelete(_ event: NSEvent) -> Bool {
        // An input method that is composing gets Delete as usual.
        guard !hasMarkedText() else {
            resetDoubleDelete()
            return false
        }
        doubleDelete.interval = doubleDeleteInterval()
        if doubleDelete.press(fieldIsEmpty: string.isEmpty, isRepeat: event.isARepeat, at: event.timestamp) {
            resetDoubleDelete()
            return onDoubleDelete?() == true
        }
        if doubleDelete.isWaiting, doubleDeleteMonitor == nil {
            doubleDeleteMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] event in
                MainActor.assumeIsolated {
                    if event.type != .keyDown || !Self.isPlainDelete(event) { self?.resetDoubleDelete() }
                }
                return event
            }
        } else if !doubleDelete.isWaiting {
            resetDoubleDelete()
        }
        return false
    }

    override func mouseDown(with event: NSEvent) {
        resetDoubleDelete()
        super.mouseDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        resetDoubleDelete()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        resetDoubleDelete()
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
            self.resignKeyObserver = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    /// Gray text drawn after the insertion point, such as "ome" and "Google Chrome" after
    /// "chr". It is never in the text storage, so it cannot be selected, copied, sent,
    /// recalled, or read back as the field's value. It shows only while the insertion point is
    /// at the end of a single line and no input method is composing.
    ///
    /// A view of its own draws it, over the text view. Overriding the text view's own drawing
    /// would put it back on TextKit 1, which changes how the field measures its lines.
    var inlineCompletion: InlineCompletion? {
        didSet { if inlineCompletion != oldValue { updateInlineCompletion() } }
    }
    var inlineCompletionColor: NSColor = .tertiaryLabelColor {
        didSet { if inlineCompletionColor != oldValue { updateInlineCompletion() } }
    }
    private lazy var inlineCompletionView: InlineCompletionView = {
        let view = InlineCompletionView(frame: bounds)
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        return view
    }()

    /// Whether the gray text can show for this text and selection.
    static func showsInlineCompletion(text: String, selection: NSRange, composing: Bool) -> Bool {
        !composing && !text.isEmpty && selection.length == 0 && selection.location == (text as NSString).length
            && !text.contains(where: \.isNewline)
    }

    var isShowingInlineCompletion: Bool {
        guard let inlineCompletion, !inlineCompletion.isEmpty else { return false }
        return Self.showsInlineCompletion(text: string, selection: selectedRange(), composing: hasMarkedText())
    }

    /// Where the gray text starts, in this view, while it shows.
    var inlineCompletionOrigin: CGPoint? {
        guard isShowingInlineCompletion else { return nil }
        return CGPoint(x: insertionPointX(), y: textContainerOrigin.y)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        updateInlineCompletion()
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        reportComposing()
        updateInlineCompletion()
    }

    override func unmarkText() {
        super.unmarkText()
        reportComposing()
        updateInlineCompletion()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        reportComposing()
    }

    override func didChangeText() {
        super.didChangeText()
        reportComposing()
        updateInlineCompletion()
    }

    /// Tells the field when composing starts or stops, once each time.
    private func reportComposing() {
        let composing = hasMarkedText()
        guard composing != wasComposing else { return }
        wasComposing = composing
        onComposingChange?(composing)
    }

    private func updateInlineCompletion() {
        guard inlineCompletion != nil || subviews.contains(where: { $0 is InlineCompletionView }) else { return }
        let view = inlineCompletionView
        view.frame = bounds
        let origin = inlineCompletionOrigin
        let content = origin == nil ? nil : inlineCompletion
        guard view.completion != content || view.origin != origin || view.color != inlineCompletionColor else { return }
        view.completion = content
        view.origin = origin ?? .zero
        view.font = font ?? InputField.font
        view.color = inlineCompletionColor
        view.needsDisplay = true
    }

    /// Where the insertion point is drawn at the end of the text, in this view. The text
    /// system says, once the view is in a window. Before that, the text is measured.
    func insertionPointX() -> CGFloat {
        let end = NSRange(location: (string as NSString).length, length: 0)
        if let window {
            let onScreen = firstRect(forCharacterRange: end, actualRange: nil)
            if onScreen != .zero {
                return convert(window.convertFromScreen(onScreen), from: nil).minX
            }
        }
        let width = (string as NSString).size(withAttributes: [.font: font ?? InputField.font]).width
        return textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0) + ceil(width)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isCommandReturn(event), window?.firstResponder === self, let onCommandReturn {
            onCommandReturn()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func isCommandReturn(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        return event.type == .keyDown && (event.keyCode == 36 || event.keyCode == 76) && flags == .command && !hasMarkedText()
    }

    /// Control-C with no other modifier, by the character the key types, as a terminal reads it.
    static func isControlC(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        return event.type == .keyDown && flags == .control && event.charactersIgnoringModifiers?.lowercased() == "c"
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Hiding the window, or the owner going to another window, starts the count over.
        if let window {
            resignKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.resetDoubleDelete() }
            }
        }
        if takesFocusInWindow, let window {
            takesFocusInWindow = false
            window.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        if Self.isPlainDelete(event) {
            if handleDelete(event) { return }
        } else {
            resetDoubleDelete()
        }
        // A Command-Return that no key equivalent took, as when the event comes straight to the view.
        if isCommandReturn(event), let onCommandReturn {
            onCommandReturn()
            return
        }
        if Self.isControlC(event), !hasMarkedText(), onControlC?() == true {
            return
        }
        currentKeyModifiers = event.modifierFlags
        defer { currentKeyModifiers = [] }
        super.keyDown(with: event)
    }
}

/// Draws the field's gray completion text: the rest of the word, a gap, then the whole name,
/// cut off with an ellipsis at the field's edge. It takes no clicks.
final class InlineCompletionView: NSView {
    var completion: InlineCompletion?
    var origin: CGPoint = .zero
    var font: NSFont = InputField.font
    var color: NSColor = .tertiaryLabelColor
    /// The room between the rest of the word and the whole name.
    static let gap: CGFloat = 12

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let completion else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        var x = origin.x
        let lineHeight = InputField.lineHeight
        if !completion.rest.isEmpty {
            let rest = NSAttributedString(string: completion.rest, attributes: attributes)
            rest.draw(with: NSRect(x: x, y: origin.y, width: max(0, bounds.maxX - x), height: lineHeight),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            x += ceil(rest.size().width)
        }
        if let name = completion.name {
            x += Self.gap
            let width = bounds.maxX - x
            guard width > 20 else { return }
            NSAttributedString(string: name, attributes: attributes).draw(
                with: NSRect(x: x, y: origin.y, width: width, height: lineHeight),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }
}
