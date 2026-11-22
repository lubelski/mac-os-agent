import AppKit
import SwiftUI

/// The floating panel the hotkey toggles. It takes keyboard focus without bringing the app
/// forward, like Spotlight, and hides when it loses focus. Hiding never stops a running task.
@MainActor
final class SummonPanel: NSPanel {
    private let session: AgentSession

    init(session: AgentSession) {
        self.session = session
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: SummonView.width, height: 80),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false

        let controller = NSHostingController(rootView: SummonView(session: session, onDismiss: { [weak self] in
            self?.dismiss()
        }))
        controller.sizingOptions = [.preferredContentSize]
        controller.view.wantsLayer = true
        controller.view.layer?.backgroundColor = .clear
        contentViewController = controller
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func toggle() {
        if isVisible { dismiss() } else { summon() }
    }

    func summon() {
        positionOnActiveScreen()
        makeKeyAndOrderFront(nil)
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

    /// Keeps the top edge in place when the content grows or shrinks.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var frame = frameRect
        if isVisible, frameRect.size.height != self.frame.size.height {
            frame.origin.y = self.frame.maxY - frameRect.size.height
        }
        super.setFrame(frame, display: flag)
    }

    /// The upper third of the screen that has the mouse, horizontally centered.
    private func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = frame.size
        let top = visible.maxY - visible.height * 0.22
        setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: top - size.height))
    }
}
