import AppKit
import MacOSAgentCore
import SwiftUI

/// The floating panel the hotkey toggles. It takes keyboard focus without bringing the app
/// forward, like Spotlight. It stays up when the owner clicks another app, and hides only on
/// the hotkey, the menu bar icon, Escape, or Command-W. Hiding never stops a running task.
///
/// The owner can move and resize it. Its frame is saved under `frameName`, so it opens where
/// it was left, across summons and launches. It can also be docked to the left or right edge
/// of its screen, which is a state of its own, kept in the defaults beside the frame.
@MainActor
final class SummonPanel: NSPanel {
    static let defaultSize = NSSize(width: 640, height: 560)
    static let minimumSize = NSSize(width: 440, height: 300)
    static let cornerRadius: CGFloat = 26
    private static let frameName = "SummonPanel"
    static let dockKey = "SummonPanelDock"
    static let undockedFrameKey = "SummonPanelUndockedFrame"

    /// What the hotkey and the menu bar icon do, given the panel's state.
    enum ToggleAction: Equatable {
        /// Hidden: show it with keyboard focus.
        case show
        /// Showing while another app has keyboard focus: give the panel focus.
        case focus
        /// Showing with keyboard focus: hide it.
        case hide

        static func given(isVisible: Bool, isKey: Bool) -> ToggleAction {
            guard isVisible else { return .show }
            return isKey ? .hide : .focus
        }
    }

    /// A screen as the panel sees it: its whole frame, and the part the menu bar and the Dock
    /// leave free.
    struct Screen: Equatable {
        var frame: CGRect
        var visible: CGRect
    }

    private let session: AgentSession
    let placement = PanelPlacement()
    /// The tool call inspector beside the panel, and the call it shows.
    let inspector = ToolInspector()
    private(set) var inspectorWindow: ToolInspectorWindow!
    /// Where the dock state and the frame from before docking are kept. Nil keeps them in
    /// memory only, for previews and tests.
    private let defaults: UserDefaults?
    /// The screens, and the mouse, so tests can stand in their own.
    var screens: () -> [Screen]
    var mouseLocation: () -> CGPoint
    /// True once the panel has a frame on screen, restored or placed.
    private var hasBeenPlaced = false
    /// True while the panel moves itself, so the move is not taken for the owner's drag.
    private var isPlacing = false
    /// The frame before the panel docked, to go back to when the owner undocks it.
    private var undockedFrame: CGRect?

    /// - Parameters:
    ///   - remembersFrame: false for preview runs, so they neither read nor overwrite the frame
    ///     or the dock the owner left the panel with.
    ///   - placementDefaults: where to keep the dock state. Defaults to the standard defaults
    ///     when the panel remembers its frame, and to memory only when it does not.
    ///   - screens: the screens to place the panel on. Defaults to the connected displays.
    ///   - mouseLocation: where the mouse is. Defaults to the real one.
    init(
        session: AgentSession, remembersFrame: Bool = true, placementDefaults: UserDefaults? = nil,
        screens: @escaping () -> [Screen] = { NSScreen.screens.map { Screen(frame: $0.frame, visible: $0.visibleFrame) } },
        mouseLocation: @escaping () -> CGPoint = { NSEvent.mouseLocation }
    ) {
        self.session = session
        self.screens = screens
        self.mouseLocation = mouseLocation
        defaults = placementDefaults ?? (remembersFrame ? .standard : nil)
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.nonactivatingPanel, .borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true)
        isFloatingPanel = true
        // Above ordinary windows, on every Space, and over a full screen app, because it stays
        // up while the owner works in other apps. Mission Control leaves it out.
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        // Dragging inside the panel selects text. The bar along the top moves it.
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        contentMinSize = Self.minimumSize

        placement.recenter = { [weak self] in self?.recenter() }
        placement.toggleDock = { [weak self] edge in self?.toggleDock(edge) }
        inspectorWindow = ToolInspectorWindow(inspector: inspector, session: session, defaults: defaults)
        inspector.callIDs = { [weak session] in session?.visibleTranscript.toolCallIDs ?? [] }
        inspector.onChange = { [weak self] in self?.updateInspector() }
        inspectorWindow.onResize = { [weak self] in self?.placeInspector() }
        let controller = NSHostingController(rootView: SummonView(session: session, onDismiss: { [weak self] in
            self?.escape()
        }).environment(placement).environment(inspector))
        // The window's size is the owner's to choose, not the content's.
        controller.sizingOptions = []
        contentViewController = controller
        setContentSize(Self.defaultSize)
        Self.giveRoundedShape(to: controller.view)

        if remembersFrame {
            hasBeenPlaced = setFrameUsingName(Self.frameName)
            setFrameAutosaveName(Self.frameName)
        }
        if let defaults {
            placement.dock = defaults.string(forKey: Self.dockKey).flatMap(PanelDock.init(rawValue:))
            undockedFrame = defaults.string(forKey: Self.undockedFrameKey).map { NSRectFromString($0) }
        }
        if placement.dock != nil {
            hasBeenPlaced = true
            applyDock()
        }

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(frameDidChange), name: NSWindow.didMoveNotification, object: self)
        center.addObserver(self, selector: #selector(frameDidChange), name: NSWindow.didResizeNotification, object: self)
        center.addObserver(self, selector: #selector(screensDidChange), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    /// Liquid Glass draws a soft shadow a little outside its shape. In a window exactly the
    /// size of the glass, that shadow is cut off at the window's rectangular edge. It leaves a
    /// faint square fill in each corner, and the window server traces its own shadow and edge
    /// around that square. Clipping the content to the glass's rounded shape keeps the corners
    /// fully transparent, so the window's shape, and so its shadow, is the rounded glass.
    /// The clip lives on the layer, so it follows the window through every resize.
    static func giveRoundedShape(to view: NSView) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        layer.backgroundColor = .clear
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Showing and hiding

    /// The hotkey and the menu bar icon. A first press while another app has focus gives the
    /// panel focus, so the owner can type. A press while it has focus hides it.
    func toggle() {
        // The inspector is part of the panel: focus in it counts as focus in the panel.
        switch ToggleAction.given(isVisible: isVisible, isKey: isKeyWindow || inspectorWindow.isKeyWindow) {
        case .show: summon()
        case .focus: focus()
        case .hide: dismiss()
        }
    }

    func summon() {
        if placement.dock != nil {
            applyDock()
        } else if !hasBeenPlaced || !isReachable {
            placeOnActiveScreen()
        }
        makeKeyAndOrderFront(nil)
        invalidateShadow()
        updateInspector()
        session.panelDidAppear()
    }

    /// Gives the panel keyboard focus where it is, with the text field ready.
    func focus() {
        makeKeyAndOrderFront(nil)
        session.panelDidAppear()
    }

    /// Shows the panel for a screenshot without making it key, so the frontmost app keeps
    /// keyboard focus.
    func showForPreview() {
        if placement.dock != nil {
            applyDock()
        } else if !hasBeenPlaced {
            placeOnActiveScreen()
        }
        orderFrontRegardless()
        invalidateShadow()
        updateInspector()
    }

    /// Hides the panel and the inspector with it. The inspector keeps its call, so it comes
    /// back with the panel.
    func dismiss() {
        hideInspectorWindow()
        orderOut(nil)
    }

    /// Escape closes the inspector first when it is open, and hides the panel on the next press.
    func escape() {
        if inspector.isOpen {
            inspector.close()
        } else {
            dismiss()
        }
    }

    override func cancelOperation(_ sender: Any?) {
        escape()
    }

    /// Command-W, from the Window menu. The panel has no close button, so AppKit would beep.
    override func performClose(_ sender: Any?) {
        dismiss()
    }

    /// The window server keeps the shadow it traced at the old size until told otherwise.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        let resized = frameRect.size != frame.size
        super.setFrame(frameRect, display: flag)
        if resized { invalidateShadow() }
    }

    // MARK: - Placement

    /// Back to the default size, centered on the screen the panel is on. It undocks.
    func recenter() {
        undock(restoringFrame: false)
        guard let visible = currentScreen()?.visible else { return }
        place(PanelGeometry.defaultFrame(size: Self.defaultSize, in: visible))
    }

    /// Docks to the edge, or undocks back to the frame from before when already docked there.
    func toggleDock(_ edge: PanelDock) {
        if placement.dock == edge {
            undock(restoringFrame: true)
            return
        }
        if placement.dock == nil {
            undockedFrame = frame
        }
        placement.dock = edge
        save()
        applyDock()
    }

    /// Puts a docked panel against its edge of its screen, at the full height. The height is
    /// held there while docked, so only the free edge resizes.
    private func applyDock() {
        guard let dock = placement.dock, let visible = currentScreen()?.visible else { return }
        let target = PanelGeometry.dockedFrame(dock, width: frame.width, minimumWidth: Self.minimumSize.width, in: visible)
        contentMinSize = NSSize(width: min(Self.minimumSize.width, target.width), height: target.height)
        contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: target.height)
        place(target)
    }

    private func undock(restoringFrame: Bool) {
        let wasDocked = placement.dock != nil
        placement.dock = nil
        contentMinSize = Self.minimumSize
        contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        if wasDocked, restoringFrame, let visible = currentScreen()?.visible {
            let target = undockedFrame.map { PanelGeometry.clamped($0, minimumSize: Self.minimumSize, in: visible) }
                ?? PanelGeometry.defaultFrame(size: Self.defaultSize, in: visible)
            place(target)
        }
        undockedFrame = nil
        save()
    }

    private func place(_ target: CGRect) {
        hasBeenPlaced = true
        isPlacing = true
        setFrame(target, display: true)
        isPlacing = false
    }

    private func save() {
        guard let defaults else { return }
        defaults.set(placement.dock?.rawValue, forKey: Self.dockKey)
        defaults.set(undockedFrame.map { NSStringFromRect($0) }, forKey: Self.undockedFrameKey)
    }

    /// A move or resize by the owner. Dragging a docked panel away undocks it. Resizing its
    /// free edge keeps it docked.
    @objc private func frameDidChange() {
        defer { placeInspector() }
        guard !isPlacing, let dock = placement.dock, let visible = currentScreen()?.visible else { return }
        if !PanelGeometry.isDocked(frame, at: dock, in: visible) {
            undock(restoringFrame: false)
        }
    }

    /// A display was connected, unplugged, or changed resolution, or the Dock moved. A docked
    /// panel docks again on its screen. A free one that ended up off every screen comes back.
    @objc func screensDidChange() {
        if placement.dock != nil {
            applyDock()
        } else if !isReachable, let visible = currentScreen()?.visible {
            place(PanelGeometry.clamped(frame, minimumSize: Self.minimumSize, in: visible))
        }
        placeInspector()
    }

    // MARK: - The inspector

    /// Shows the inspector beside the panel while it has a call and the panel is up, and hides
    /// it otherwise. It is a child window, so AppKit moves it and orders it with the panel.
    func updateInspector() {
        guard inspector.isOpen, isVisible else {
            hideInspectorWindow()
            return
        }
        placeInspector()
        if inspectorWindow.parent == nil {
            addChildWindow(inspectorWindow, ordered: .above)
        }
        if !inspectorWindow.isVisible {
            inspectorWindow.orderFront(nil)
        }
    }

    private func hideInspectorWindow() {
        if inspectorWindow.isKeyWindow, isVisible { makeKey() }
        if inspectorWindow.parent != nil { removeChildWindow(inspectorWindow) }
        inspectorWindow.orderOut(nil)
    }

    /// Beside the panel on the side with room, at the panel's height. See `PanelGeometry`.
    func placeInspector() {
        guard inspector.isOpen, let visible = currentScreen()?.visible else { return }
        let placement = PanelGeometry.inspectorPlacement(
            panel: frame, dock: self.placement.dock, width: inspectorWindow.preferredWidth, in: visible)
        if inspector.side != placement.side { inspector.side = placement.side }
        inspectorWindow.place(placement.frame)
    }

    /// The screen that holds most of the panel, or the one with the mouse when none does.
    private func currentScreen() -> Screen? {
        let screens = screens()
        if let index = PanelGeometry.screenIndex(for: frame, among: screens.map(\.frame)) {
            return screens[index]
        }
        return mouseScreen(screens)
    }

    private func mouseScreen(_ screens: [Screen]) -> Screen? {
        PanelGeometry.screenIndex(containing: mouseLocation(), among: screens.map(\.frame)).map { screens[$0] } ?? screens.first
    }

    /// False when the saved frame is on a display that is no longer connected.
    private var isReachable: Bool {
        PanelGeometry.isReachable(frame, on: screens().map(\.visible))
    }

    /// The default place on the screen that has the mouse.
    private func placeOnActiveScreen() {
        guard let visible = mouseScreen(screens())?.visible else { return }
        place(PanelGeometry.defaultFrame(size: frame.size, in: visible))
    }
}
