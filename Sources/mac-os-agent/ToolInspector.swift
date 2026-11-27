import AppKit
import MacOSAgentCore
import SwiftUI

/// Which tool call the inspector shows, if any. The panel owns it and hands it to its content
/// and to the inspector through the environment. There is one inspector: opening another call
/// swaps what it shows.
@MainActor @Observable
final class ToolInspector {
    /// The call shown, or nil when the inspector is closed.
    private(set) var selectedCallID: String?
    /// Which side of the panel it is on, for the side its resize edge and shadow face.
    var side: InspectorPlacement.Side = .right
    /// Called when the inspector opens, closes, or changes call, so the window follows.
    @ObservationIgnored var onChange: () -> Void = {}
    /// The calls of the history the panel shows, oldest first, for moving between them.
    @ObservationIgnored var callIDs: () -> [String] = { [] }

    var isOpen: Bool { selectedCallID != nil }

    func open(_ callID: String) {
        guard selectedCallID != callID else { return }
        selectedCallID = callID
        onChange()
    }

    func close() {
        guard selectedCallID != nil else { return }
        selectedCallID = nil
        onChange()
    }

    /// Moves to the previous call, or the next one, when the inspector is open. Returns whether
    /// it moved, so a key press that did nothing can go on to the text field.
    @discardableResult
    func move(by offset: Int) -> Bool {
        guard let selectedCallID else { return false }
        let ids = callIDs()
        guard let index = ids.firstIndex(of: selectedCallID) else { return false }
        let target = index + offset
        guard ids.indices.contains(target) else { return false }
        open(ids[target])
        return true
    }
}

/// The inspector's window: a borderless, non-activating panel attached to the summon panel as
/// a child window, so it moves, hides, shows, and changes Spaces with it. It becomes key only
/// when the owner clicks into something that takes keyboard focus, such as the output text,
/// so opening it never takes focus from the text field.
///
/// A child window, not a wider panel: the panel's frame, layout preset, saved frame, and resize
/// limits stay exactly as they are, and the inspector has its own glass, edge, and width.
///
/// Its glass sits in a container, as the panel's does, so it can slide with the panel's glass
/// in slide over and be cut off at the same screen edge. See `place(_:clip:)`.
@MainActor
final class ToolInspectorWindow: ActiveAppearancePanel {
    static let defaultWidth: CGFloat = 440
    static let widthKey = "ToolInspectorWidth"

    private let defaults: UserDefaults?
    /// Holds the glass and cuts it off at the screen's edge while it slides with the panel.
    private let container = SlideContainerView()
    private let hostingController: NSHostingController<AnyView>
    /// True while the window is being placed, so the move is not taken for the owner's resize.
    private var isPlacing = false
    /// The width the owner chose, kept across launches.
    private(set) var preferredWidth: CGFloat
    /// Places the window again, after the owner resized it.
    var onResize: () -> Void = {}
    let inspector: ToolInspector
    /// The panel's session, for Stop while the inspector is key.
    private let session: AgentSession

    init(inspector: ToolInspector, session: AgentSession, defaults: UserDefaults?) {
        self.inspector = inspector
        self.session = session
        self.defaults = defaults
        let stored = defaults?.double(forKey: Self.widthKey) ?? 0
        preferredWidth = stored >= PanelGeometry.inspectorMinimumWidth ? stored : Self.defaultWidth
        hostingController = NSHostingController(rootView: AnyView(ToolInspectorView(session: session).environment(inspector)))
        hostingController.sizingOptions = []
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: preferredWidth, height: SummonPanel.defaultSize.height),
            styleMask: [.nonactivatingPanel, .borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        // A click on a label or the glass leaves keyboard focus in the text field.
        becomesKeyOnlyIfNeeded = true
        contentMinSize = NSSize(width: PanelGeometry.inspectorNarrowestWidth, height: 200)

        let host = hostingController.view
        container.frame = NSRect(x: 0, y: 0, width: preferredWidth, height: SummonPanel.defaultSize.height)
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        contentView = container
        SummonPanel.giveRoundedShape(to: host)

        NotificationCenter.default.addObserver(self, selector: #selector(didResize), name: NSWindow.didResizeNotification, object: self)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Puts the window at a frame without taking it for the owner's resize. The height is held
    /// at the panel's, so only the width resizes.
    func place(_ frame: CGRect) {
        place(frame, clip: nil)
    }

    /// Puts the glass at a frame, with the window cut down to the part of it inside `clip`, so
    /// the glass is cut off at the clip's edge as it slides with the panel. The glass keeps its
    /// size, so nothing in it reflows. With no clip, or a frame wholly inside it, the window
    /// is the glass.
    func place(_ frame: CGRect, clip: CGRect?) {
        isPlacing = true
        defer { isPlacing = false }
        var shown = frame
        if let clip {
            let minX = max(frame.minX, clip.minX)
            let maxX = min(frame.maxX, clip.maxX)
            // Fully past the edge: a sliver at the edge that shows none of the glass.
            shown = maxX > minX
                ? CGRect(x: minX, y: frame.minY, width: maxX - minX, height: frame.height)
                : CGRect(x: frame.maxX <= clip.minX ? clip.minX : clip.maxX - 1, y: frame.minY, width: 1, height: frame.height)
        }
        if shown == frame {
            contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: frame.height)
            contentMinSize = NSSize(width: PanelGeometry.inspectorNarrowestWidth, height: frame.height)
        } else {
            contentMinSize = NSSize(width: 1, height: frame.height)
        }
        if shown != self.frame {
            setFrame(shown, display: true)
        }
        let glass = CGRect(x: frame.minX - shown.minX, y: 0, width: frame.width, height: frame.height)
        if hostingController.view.frame != glass { hostingController.view.frame = glass }
        invalidateShadow()
    }

    /// Where the inspector's glass is drawn now, in screen coordinates.
    var glassFrameOnScreen: CGRect {
        hostingController.view.frame.offsetBy(dx: frame.minX, dy: frame.minY)
    }

    @objc private func didResize() {
        guard !isPlacing else { return }
        preferredWidth = max(PanelGeometry.inspectorMinimumWidth, frame.width.rounded())
        defaults?.set(Double(preferredWidth), forKey: Self.widthKey)
        onResize()
    }

    /// Escape in the inspector closes it.
    override func cancelOperation(_ sender: Any?) {
        inspector.close()
    }

    /// Stop in the main menu, Command-Period, while the inspector is key: stops its panel's task.
    @objc func stopTask(_ sender: Any?) {
        session.stop()
    }

    /// Close in the Window menu is always enabled, as in the panel: AppKit's own check turns it
    /// down for a borderless window.
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == MainMenu.stopTaskAction { return session.isRunning }
        if item.action == #selector(performClose(_:)) { return true }
        return super.validateMenuItem(item)
    }

    /// Command-W closes the inspector rather than beeping.
    override func performClose(_ sender: Any?) {
        inspector.close()
    }

    /// Up and Down move between calls, unless a text view has focus and uses them itself.
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            switch event.keyCode {
            case 126: if inspector.move(by: -1) { return }
            case 125: if inspector.move(by: 1) { return }
            default: break
            }
        }
        super.keyDown(with: event)
    }

    /// Command-F shows the find bar of the output, when the output has one.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "f",
           let textView = contentView.flatMap(Self.findableTextView(in:))
        {
            makeKey()
            makeFirstResponder(textView)
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.showFindInterface.rawValue
            textView.performTextFinderAction(item)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private static func findableTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView, textView.usesFindBar { return textView }
        for subview in view.subviews {
            if let found = findableTextView(in: subview) { return found }
        }
        return nil
    }
}
