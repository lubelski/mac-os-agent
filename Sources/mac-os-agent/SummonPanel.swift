import AppKit
import SwiftUI

/// The floating panel the hotkey toggles. It takes keyboard focus without bringing the app
/// forward, like Spotlight, and hides when it loses focus. Hiding never stops a running task.
///
/// The owner can move and resize it. Its frame is saved under `frameName`, so it opens where
/// it was left, across summons and launches.
@MainActor
final class SummonPanel: NSPanel {
    static let defaultSize = NSSize(width: 640, height: 560)
    static let minimumSize = NSSize(width: 440, height: 300)
    static let cornerRadius: CGFloat = 26
    private static let frameName = "SummonPanel"

    private let session: AgentSession
    /// True once the panel has a frame on screen, restored or placed.
    private var hasBeenPlaced = false

    /// - Parameter remembersFrame: false for preview runs, so they neither read nor overwrite
    ///   the frame the owner left the panel at.
    init(session: AgentSession, remembersFrame: Bool = true) {
        self.session = session
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
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
        // Dragging inside the panel selects text. The strip along the top edge moves it.
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        contentMinSize = Self.minimumSize

        let controller = NSHostingController(rootView: SummonView(session: session, onDismiss: { [weak self] in
            self?.dismiss()
        }))
        // The window's size is the owner's to choose, not the content's.
        controller.sizingOptions = []
        contentViewController = controller
        setContentSize(Self.defaultSize)
        Self.giveRoundedShape(to: controller.view)

        if remembersFrame {
            hasBeenPlaced = setFrameUsingName(Self.frameName)
            setFrameAutosaveName(Self.frameName)
        }
    }

    /// Liquid Glass draws a soft shadow a little outside its shape. In a window exactly the
    /// size of the glass, that shadow is cut off at the window's rectangular edge. It leaves a
    /// faint square fill in each corner, and the window server traces its own shadow and edge
    /// around that square. Clipping the content to the glass's rounded shape keeps the corners
    /// fully transparent, so the window's shape, and so its shadow, is the rounded glass.
    /// The clip lives on the layer, so it follows the window through every resize.
    private static func giveRoundedShape(to view: NSView) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        layer.backgroundColor = .clear
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func toggle() {
        if isVisible { dismiss() } else { summon() }
    }

    func summon() {
        if !hasBeenPlaced || !isOnAScreen {
            placeOnActiveScreen()
        }
        makeKeyAndOrderFront(nil)
        invalidateShadow()
        session.panelDidAppear()
    }

    func dismiss() {
        orderOut(nil)
    }

    override func resignKey() {
        super.resignKey()
        dismiss()
    }

    override func cancelOperation(_ sender: Any?) {
        dismiss()
    }

    /// The window server keeps the shadow it traced at the old size until told otherwise.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        let resized = frameRect.size != frame.size
        super.setFrame(frameRect, display: flag)
        if resized { invalidateShadow() }
    }

    /// False when the saved frame is on a display that is no longer connected.
    private var isOnAScreen: Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersection(frame).height >= 60 }
    }

    /// Centered on the screen that has the mouse, with its top a little below the menu bar.
    private func placeOnActiveScreen() {
        hasBeenPlaced = true
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let width = min(frame.width, visible.width - 40)
        let height = min(frame.height, visible.height - 40)
        let top = visible.maxY - visible.height * 0.12
        setFrame(
            NSRect(x: visible.midX - width / 2, y: max(visible.minY + 20, top - height), width: width, height: height),
            display: false)
    }
}
