import AppKit
import MacOSAgentCore
import QuartzCore
import SwiftUI

/// The floating panel the hotkey toggles. It takes keyboard focus without bringing the app
/// forward, like Spotlight. It stays up when the owner clicks another app, and hides only on
/// the hotkey, the menu bar icon, the close button, Escape, or Command-W. Hiding never stops a
/// running task.
///
/// It lives in one of the layout presets in `PanelPreset`, chosen from the menu in its top bar
/// and kept in the defaults:
/// - Centered: the owner moves and resizes it, and it appears and disappears in place. Its
///   frame is saved under `frameName`, so it opens where it was left.
/// - Slide over: full height against the left or right edge of its screen. It slides in from
///   the edge when summoned and back out past it when hidden. Only the free edge resizes, and
///   the width is kept.
///
/// In slide over the window is wider than the glass by the margin on the edge side, so it
/// reaches the edge of the screen's visible area. The glass slides inside the window, which
/// cuts it off at that edge. That is how it leaves at the edge instead of travelling across a
/// display beside this one.
@MainActor
final class SummonPanel: NSPanel {
    static let defaultSize = NSSize(width: 640, height: 560)
    static let minimumSize = NSSize(width: 440, height: 300)
    static let cornerRadius: CGFloat = 26
    private static let frameName = "SummonPanel"
    static let presetKey = "SummonPanelPreset"
    static let centeredFrameKey = "SummonPanelCenteredFrame"
    static let slideOverWidthKey = "SummonPanelSlideOverWidth"
    /// Where PR #17 kept the dock state and the frame from before docking. Read once, moved to
    /// the keys above, and removed.
    static let legacyDockKey = "SummonPanelDock"
    static let legacyUndockedFrameKey = "SummonPanelUndockedFrame"

    /// What the hotkey and the menu bar icon do, given the panel's state.
    enum ToggleAction: Equatable {
        /// Hidden, or on its way out: show it with keyboard focus.
        case show
        /// Showing while another app has keyboard focus: give the panel focus.
        case focus
        /// Showing with keyboard focus, or on its way in: hide it.
        case hide

        /// - Parameter isVisible: whether the panel is showing or on its way in. A panel on its
        ///   way out counts as hidden, so a press brings it back.
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
    /// Holds the glass and cuts it off while it slides. The window's content view.
    private let container = SlideContainerView()
    private let hostingController: NSHostingController<AnyView>
    /// The SwiftUI content on its glass, inside `container`.
    private var host: NSView { hostingController.view }
    /// Where the preset and the remembered frames are kept. Nil keeps them in memory only, for
    /// previews and tests.
    private let defaults: UserDefaults?
    /// The screens, and the mouse, so tests can stand in their own.
    var screens: () -> [Screen]
    var mouseLocation: () -> CGPoint
    /// Whether to fade instead of slide. Defaults to the Reduce Motion setting.
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Puts the window on screen, with keyboard focus when asked. Tests stand in a recorder,
    /// so nothing shows and nothing takes focus.
    var orderIn: (SummonPanel, _ makeKey: Bool) -> Void = { panel, makeKey in
        if makeKey { panel.makeKeyAndOrderFront(nil) } else { panel.orderFrontRegardless() }
    }
    /// Takes the window off screen.
    var orderAway: (SummonPanel) -> Void = { $0.orderOut(nil) }
    /// False in tests, which move a slide on with `advanceSlide(by:)` instead of the display.
    var drivesSlidesWithTheDisplay = true
    /// Stretches every slide in time, for a preview that shows the motion slowly.
    var slideTimeScale: Double = 1

    /// True once the panel has a frame on screen, restored or placed.
    private var hasBeenPlaced = false
    /// True while the panel moves itself, so the move is not taken for the owner's drag.
    private var isPlacing = false
    /// The centered frame to come back to from slide over.
    private var centeredFrame: CGRect?
    /// The width the owner left the slide over panel at.
    private var slideOverWidth: CGFloat?
    /// The strip the window has beyond the glass on its edge side, in slide over.
    private var inset: (edge: PanelEdge, width: CGFloat)?
    /// The slide under way, if any.
    private(set) var slide: PanelSlide?
    private var displayLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval?
    /// True while the window is ordered in, including on its way out.
    private(set) var isOrderedIn = false
    /// True when the panel is showing or on its way in. False when hidden or on its way out.
    private(set) var isPresented = false

    /// - Parameters:
    ///   - remembersFrame: false for preview runs, so they neither read nor overwrite the frame
    ///     or the preset the owner left the panel with.
    ///   - placementDefaults: where to keep the preset. Defaults to the standard defaults when
    ///     the panel remembers its frame, and to memory only when it does not.
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
        hostingController = NSHostingController(rootView: AnyView(EmptyView()))
        // The window's size is the owner's to choose, not the content's.
        hostingController.sizingOptions = []
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

        session.hidePanel = { [weak self] in self?.dismiss() }
        session.showPanel = { [weak self] in self?.summon() }
        placement.choose = { [weak self] preset in self?.choose(preset) }
        placement.close = { [weak self] in self?.dismiss() }
        inspectorWindow = ToolInspectorWindow(inspector: inspector, session: session, defaults: defaults)
        inspector.callIDs = { [weak session] in session?.visibleTranscript.toolCallIDs ?? [] }
        inspector.onChange = { [weak self] in self?.updateInspector() }
        inspectorWindow.onResize = { [weak self] in self?.placeInspector() }
        hostingController.rootView = AnyView(SummonView(session: session, onDismiss: { [weak self] in
            self?.escape()
        }).environment(placement).environment(inspector))

        container.frame = NSRect(origin: .zero, size: Self.defaultSize)
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        contentView = container
        setContentSize(Self.defaultSize)
        Self.giveRoundedShape(to: host)

        if remembersFrame {
            hasBeenPlaced = setFrameUsingName(Self.frameName)
            setFrameAutosaveName(Self.frameName)
        }
        if let defaults {
            Self.migrateLegacyDock(in: defaults)
            placement.preset = defaults.string(forKey: Self.presetKey).flatMap(PanelPreset.init(rawValue:)) ?? .centered
            centeredFrame = defaults.string(forKey: Self.centeredFrameKey).map { NSRectFromString($0) }
            let width = defaults.double(forKey: Self.slideOverWidthKey)
            slideOverWidth = width > 0 ? width : nil
        }
        if placement.preset.slideOverEdge != nil {
            hasBeenPlaced = true
            applyPreset()
        }
        updatePlacementFrames()

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(frameDidChange), name: NSWindow.didMoveNotification, object: self)
        center.addObserver(self, selector: #selector(frameDidChange), name: NSWindow.didResizeNotification, object: self)
        center.addObserver(self, selector: #selector(screensDidChange), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    /// An owner who had docked the panel with PR #17 finds it in the matching slide over, and
    /// the frame from before docking becomes the centered frame to come back to.
    static func migrateLegacyDock(in defaults: UserDefaults) {
        let dock = defaults.string(forKey: legacyDockKey)
        let undocked = defaults.string(forKey: legacyUndockedFrameKey)
        guard dock != nil || undocked != nil else { return }
        if defaults.string(forKey: presetKey) == nil, let preset = PanelPreset(legacyDock: dock) {
            defaults.set(preset.rawValue, forKey: presetKey)
        }
        if defaults.string(forKey: centeredFrameKey) == nil, let undocked {
            defaults.set(undocked, forKey: centeredFrameKey)
        }
        defaults.removeObject(forKey: legacyDockKey)
        defaults.removeObject(forKey: legacyUndockedFrameKey)
    }

    /// Liquid Glass draws a soft shadow a little outside its shape. In a window exactly the
    /// size of the glass, that shadow is cut off at the window's rectangular edge. It leaves a
    /// faint square fill in each corner, and the window server traces its own shadow and edge
    /// around that square. Clipping the content to the glass's rounded shape keeps the corners
    /// fully transparent, so the window's shape, and so its shadow, is the rounded glass.
    /// The clip lives on the layer, so it follows the glass through every resize and slide.
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

    /// The glass's frame on screen when it is in place: the window's frame less the strip on
    /// the edge side in slide over.
    var panelFrame: CGRect {
        guard let inset else { return frame }
        var glass = frame
        glass.size.width -= inset.width
        if inset.edge == .left { glass.origin.x += inset.width }
        return glass
    }

    /// Where the glass is drawn now, in screen coordinates. Away from `panelFrame` only while
    /// it slides.
    var glassFrameOnScreen: CGRect {
        host.frame.offsetBy(dx: frame.minX, dy: frame.minY)
    }

    // MARK: - Showing and hiding

    /// The hotkey and the menu bar icon. A first press while another app has focus gives the
    /// panel focus, so the owner can type. A press while it has focus hides it. A press during
    /// a slide turns it around.
    func toggle() {
        // The inspector is part of the panel: focus in it counts as focus in the panel.
        let isKey = isKeyWindow || inspectorWindow.isKeyWindow
        switch ToggleAction.given(isVisible: isPresented && isOrderedIn, isKey: isKey) {
        case .show: summon()
        case .focus: focus()
        case .hide: dismiss()
        }
    }

    /// Shows the panel with the text field ready. The field takes focus at once, not when a
    /// slide ends.
    func summon() {
        present(makeKey: true)
        session.panelDidAppear()
    }

    /// Gives the panel keyboard focus where it is, with the text field ready.
    func focus() {
        orderIn(self, true)
        isOrderedIn = true
        session.panelDidAppear()
    }

    /// Shows the panel for a screenshot without making it key, so the frontmost app keeps
    /// keyboard focus. A slide over panel slides in as it would on a summon.
    func showForPreview() {
        present(makeKey: false)
    }

    private func present(makeKey: Bool) {
        if isOrderedIn, var slide, slide.target == .hidden {
            // On its way out: turn around from where it is.
            slide.retarget(.shown)
            self.slide = slide
            isPresented = true
            orderIn(self, makeKey)
            return
        }
        let wasOrderedIn = isOrderedIn
        if placement.preset.slideOverEdge != nil {
            applyPreset()
        } else if !hasBeenPlaced || !isReachable {
            placeOnActiveScreen()
        }
        isPresented = true
        if !wasOrderedIn, placement.preset.slideOverEdge != nil {
            // Off past the edge before the window is ordered in, so the first frame drawn is
            // the start of the slide.
            startSlide(to: .shown)
        }
        orderIn(self, makeKey)
        isOrderedIn = true
        invalidateShadow()
        updateInspector()
        if slide == nil { reportMotion() }
    }

    /// Hides the panel. In slide over it slides out past its edge first. It never stops a task.
    func dismiss() {
        guard isPresented || isOrderedIn else { return }
        isPresented = false
        if var slide {
            slide.retarget(.hidden)
            self.slide = slide
        } else if isOrderedIn, placement.preset.slideOverEdge != nil {
            startSlide(to: .hidden)
        } else {
            finishHiding()
        }
    }

    /// Escape dismisses an instant action suggestion first when one is showing, then closes
    /// the inspector when it is open, and hides the panel on the next press.
    func escape() {
        if session.instantActions.dismiss() { return }
        if inspector.isOpen {
            inspector.close()
        } else {
            dismiss()
        }
    }

    override func cancelOperation(_ sender: Any?) {
        escape()
    }

    /// Command-W, from the Window menu. The close button in the top bar does the same.
    override func performClose(_ sender: Any?) {
        dismiss()
    }

    /// Anything that takes the window off screen leaves it hidden, with no slide left running.
    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        if isOrderedIn || slide != nil {
            isOrderedIn = false
            isPresented = false
            endSlide()
        }
    }

    /// The window server keeps the shadow it traced at the old size until told otherwise.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        let resized = frameRect.size != frame.size
        super.setFrame(frameRect, display: flag)
        if resized { invalidateShadow() }
    }

    /// Hides the panel, and the inspector with it. The inspector keeps its call, so it comes
    /// back with the panel.
    private func finishHiding() {
        hideInspectorWindow()
        endSlide()
        isPresented = false
        orderAway(self)
        isOrderedIn = false
        reportMotion(position: 0)
    }

    // MARK: - Sliding

    private func startSlide(to target: PanelSlide.Target) {
        slide = PanelSlide(style: reduceMotion() ? .fade : .slide, to: target)
        lastFrameTime = nil
        drawSlide()
        guard drivesSlidesWithTheDisplay, displayLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(displayFrame(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func displayFrame(_ link: CADisplayLink) {
        let now = link.timestamp
        let elapsed = lastFrameTime.map { now - $0 } ?? 0
        lastFrameTime = now
        // A long gap between frames, such as after the Mac slept, does not skip the slide.
        advanceSlide(by: min(elapsed, 0.05))
    }

    /// Moves the slide on by this much time, and finishes it when it arrives.
    func advanceSlide(by seconds: TimeInterval) {
        guard var slide else { return }
        slide.advance(by: seconds / max(slideTimeScale, 0.01))
        self.slide = slide
        drawSlide()
        guard slide.isFinished else { return }
        if slide.target == .hidden {
            finishHiding()
        } else {
            endSlide()
            reportMotion()
        }
    }

    /// Stops any slide and puts the glass back in place, fully opaque.
    private func endSlide() {
        displayLink?.invalidate()
        displayLink = nil
        lastFrameTime = nil
        slide = nil
        layoutHost(offset: 0)
        alphaValue = 1
        inspectorWindow?.alphaValue = 1
        placeInspector()
    }

    /// Draws the glass where the slide has it: moved toward the edge, or faded.
    private func drawSlide() {
        guard let slide, let edge = placement.preset.slideOverEdge, let visible = currentScreen()?.visible else { return }
        let resting = panelFrame
        let moved = PanelGeometry.slidFrame(
            panel: resting, companion: restingInspectorPlacement(in: visible)?.frame, edge: edge, in: visible,
            travel: slide.travel)
        layoutHost(offset: moved.minX - resting.minX)
        alphaValue = slide.alpha
        invalidateShadow()
        placeInspector()
        placement.onMotion?(PanelMotionFrame(
            glass: moved, resting: resting, clip: visible, alpha: slide.alpha, position: slide.position))
    }

    /// Tells a window that follows the panel where it is at rest, shown or hidden.
    private func reportMotion(position: Double = 1) {
        guard let onMotion = placement.onMotion else { return }
        let resting = panelFrame
        let clip = currentScreen()?.visible ?? resting
        onMotion(PanelMotionFrame(glass: resting, resting: resting, clip: clip, alpha: position, position: position))
    }

    /// Lays the glass out in the window: beside the strip on the edge side, and moved sideways
    /// by `offset` while it slides. Its size never changes on the way, so nothing reflows.
    private func layoutHost(offset: CGFloat) {
        var glass = container.bounds
        if let inset {
            glass.size.width -= inset.width
            if inset.edge == .left { glass.origin.x += inset.width }
        }
        glass.origin.x += offset
        if host.frame != glass { host.frame = glass }
    }

    // MARK: - Presets

    /// Moves the panel to a preset. Centered comes back to the frame it had before slide over,
    /// or, when it is already centered, goes to the default size in the middle of its screen.
    /// A slide over preset slides in from its edge when the panel is showing.
    func choose(_ preset: PanelPreset) {
        let previous = placement.preset
        if let slide {
            if slide.target == .hidden { finishHiding() } else { endSlide() }
        }
        if previous == .centered, preset != .centered {
            centeredFrame = panelFrame
        }
        placement.preset = preset
        if preset == .centered {
            setInset(nil)
            contentMinSize = Self.minimumSize
            contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            if let visible = currentScreen()?.visible {
                if previous != .centered, let centeredFrame {
                    place(PanelGeometry.clamped(centeredFrame, minimumSize: Self.minimumSize, in: visible))
                } else {
                    place(PanelGeometry.defaultFrame(size: Self.defaultSize, in: visible))
                }
            }
        } else {
            applyPreset()
            if isPresented, isOrderedIn, preset != previous {
                startSlide(to: .shown)
            }
        }
        save()
        updatePlacementFrames()
        placeInspector()
        if slide == nil, isPresented { reportMotion() }
    }

    /// Puts a slide over panel in place at its edge of its screen, at the full height and the
    /// width the owner left it at. The height is held there, so only the free edge resizes.
    private func applyPreset() {
        guard let edge = placement.preset.slideOverEdge, let visible = currentScreen()?.visible else { return }
        let glass = PanelGeometry.slideOverFrame(
            edge, width: slideOverWidth ?? panelFrame.width, minimumWidth: Self.minimumSize.width, in: visible)
        let window = PanelGeometry.slideOverWindowFrame(panel: glass, edge: edge, in: visible)
        let strip = window.width - glass.width
        inset = strip > 0 ? (edge, strip) : nil
        contentMinSize = NSSize(width: min(Self.minimumSize.width, glass.width) + strip, height: window.height)
        contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: window.height)
        place(window)
        if slide != nil { drawSlide() }
    }

    /// Drops the strip beside the glass, and shrinks the window to the glass where it is.
    private func setInset(_ newInset: (edge: PanelEdge, width: CGFloat)?) {
        let glass = panelFrame
        inset = newInset
        if newInset == nil, frame != glass {
            place(glass)
        }
        layoutHost(offset: 0)
    }

    private func place(_ target: CGRect) {
        hasBeenPlaced = true
        isPlacing = true
        setFrame(target, display: true)
        isPlacing = false
        layoutHost(offset: 0)
        updatePlacementFrames()
    }

    private func save() {
        guard let defaults else { return }
        defaults.set(placement.preset.rawValue, forKey: Self.presetKey)
        defaults.set(centeredFrame.map { NSStringFromRect($0) }, forKey: Self.centeredFrameKey)
        if let slideOverWidth {
            defaults.set(Double(slideOverWidth), forKey: Self.slideOverWidthKey)
        } else {
            defaults.removeObject(forKey: Self.slideOverWidthKey)
        }
    }

    /// Keeps what a follower reads about the panel's place current.
    private func updatePlacementFrames() {
        let glass = panelFrame
        if placement.panelFrame != glass { placement.panelFrame = glass }
        let visible = currentScreen()?.visible ?? glass
        if placement.visibleFrame != visible { placement.visibleFrame = visible }
    }

    /// A move or resize by the owner. Resizing the free edge of a slide over panel keeps it
    /// there and remembers the width. Dragging it away makes it Centered where it was dropped.
    @objc private func frameDidChange() {
        defer {
            updatePlacementFrames()
            placeInspector()
        }
        guard !isPlacing, slide == nil else { return }
        guard let edge = placement.preset.slideOverEdge, let visible = currentScreen()?.visible else { return }
        if PanelGeometry.isInSlideOver(panelFrame, at: edge, in: visible) {
            slideOverWidth = panelFrame.width
            save()
        } else {
            placement.preset = .centered
            contentMinSize = Self.minimumSize
            contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            save()
            dropStripWhenTheMouseIsUp()
        }
    }

    /// A panel dragged out of slide over keeps its edge strip until the drag ends, so the
    /// window under the pointer is not resized mid drag. Then the window shrinks to the glass.
    private func dropStripWhenTheMouseIsUp() {
        guard inset != nil, placement.preset.slideOverEdge == nil else { return }
        if NSEvent.pressedMouseButtons & 1 != 0 {
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.dropStripWhenTheMouseIsUp() }
            }
            return
        }
        setInset(nil)
    }

    /// A display was connected, unplugged, or changed resolution, or the Dock moved. A slide
    /// over panel goes back in place on its screen. A centered one that ended up off every
    /// screen comes back.
    @objc func screensDidChange() {
        if let slide {
            if slide.target == .hidden { finishHiding() } else { endSlide() }
        }
        if placement.preset.slideOverEdge != nil {
            applyPreset()
        } else if !isReachable, let visible = currentScreen()?.visible {
            place(PanelGeometry.clamped(panelFrame, minimumSize: Self.minimumSize, in: visible))
        }
        updatePlacementFrames()
        placeInspector()
    }

    // MARK: - The inspector

    /// Shows the inspector beside the panel while it has a call and the panel is up, and hides
    /// it otherwise. It is a child window, so AppKit orders it with the panel.
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
        guard let inspectorWindow else { return }
        if inspectorWindow.isKeyWindow, isVisible { makeKey() }
        if inspectorWindow.parent != nil { removeChildWindow(inspectorWindow) }
        inspectorWindow.orderOut(nil)
    }

    /// Where the inspector goes when the panel is in place, or nil when it is closed.
    private func restingInspectorPlacement(in visible: CGRect) -> InspectorPlacement? {
        guard let inspectorWindow, inspector.isOpen else { return nil }
        return PanelGeometry.inspectorPlacement(
            panel: panelFrame, freeSide: placement.freeSide, width: inspectorWindow.preferredWidth, in: visible)
    }

    /// Beside the panel on its free side, at the panel's height: the inward side in slide
    /// over. See `PanelGeometry.inspectorPlacement`. While the panel slides, the inspector
    /// moves with its glass as one unit, takes its opacity, and is cut off at the same screen
    /// edge, so it never shows on a display beside this one.
    func placeInspector() {
        guard let inspectorWindow, let visible = currentScreen()?.visible,
              let placement = restingInspectorPlacement(in: visible) else { return }
        if inspector.side != placement.side { inspector.side = placement.side }
        if let slide, let edge = self.placement.preset.slideOverEdge {
            let offset = PanelGeometry.slideOffset(
                panel: panelFrame, companion: placement.frame, edge: edge, in: visible, travel: slide.travel)
            inspectorWindow.place(placement.frame.offsetBy(dx: offset, dy: 0), clip: visible)
            inspectorWindow.alphaValue = slide.alpha
        } else {
            inspectorWindow.place(placement.frame)
        }
    }

    /// The screen that holds most of the panel, or the one with the mouse when none does.
    private func currentScreen() -> Screen? {
        let screens = screens()
        if let index = PanelGeometry.screenIndex(for: panelFrame, among: screens.map(\.frame)) {
            return screens[index]
        }
        return mouseScreen(screens)
    }

    private func mouseScreen(_ screens: [Screen]) -> Screen? {
        PanelGeometry.screenIndex(containing: mouseLocation(), among: screens.map(\.frame)).map { screens[$0] } ?? screens.first
    }

    /// False when the saved frame is on a display that is no longer connected.
    private var isReachable: Bool {
        PanelGeometry.isReachable(panelFrame, on: screens().map(\.visible))
    }

    /// The default place on the screen that has the mouse.
    private func placeOnActiveScreen() {
        guard let visible = mouseScreen(screens())?.visible else { return }
        place(PanelGeometry.defaultFrame(size: panelFrame.size, in: visible))
    }
}

/// The window's content view. It draws nothing, and it cuts the glass off at its bounds while
/// the glass slides, which in slide over is the edge of the screen.
final class SlideContainerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The strip beside the glass in slide over is not part of the panel. A click there goes
    /// to whatever is behind it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
