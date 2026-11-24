import AppKit
import MacOSAgentCore
import QuartzCore
import SwiftUI

/// The floating panel the hotkey toggles. It takes keyboard focus without bringing the app
/// forward, like Spotlight. It stays up when the owner clicks another app, and hides only on
/// the hotkey, the menu bar icon, Hide Panel in its top bar's menu, Escape, or Command-W.
/// Hiding never stops a running task.
///
/// It lives in one of the layout presets in `PanelPreset`, chosen from the menu in its top bar
/// and kept in the defaults:
/// - Centered: the owner moves and resizes it, and it appears and disappears in place. Its
///   frame is saved under `frameName`, so it opens where it was left.
/// - Slide over: full height and flush against the left or right edge of its screen's visible
///   area, with square corners on that side. It slides in from the edge when summoned and back
///   out past it when hidden. Only the free edge resizes, and the width is kept.
///
/// In slide over the window reaches the edge of the screen's visible area. The glass slides
/// inside the window, which cuts it off at that edge. That is how it leaves at the edge instead
/// of travelling across a display beside this one.
///
/// The corners on a side flush against the screen's edge are square, on the glass and on the
/// clip of its layer alike, and rounded again once the panel moves off it. See `squareEdges`.
///
/// A double click on the top bar puts it back at its preset's frame and forgets the frame or
/// width it remembered for that preset. See `resetToDefaultPlace()`.
///
/// It is above other windows only while it has focus, or always when Keep on Top is on, and
/// the app's own windows, such as Settings, always come in front of it. Once another window
/// is brought forward it layers like an ordinary window and stays open underneath. See
/// `PanelLayering` and the layering section below.
///
/// With the suggestions-in-the-field experiment on, the window grows downward for a moment to
/// hold the list under the text field, and shrinks back when it closes. See the footer section
/// below. The growth is never part of `panelFrame`, so nothing that remembers or reasons about
/// the panel's place sees it.
///
/// The incognito window is the same panel with the `.incognito` role. It has no layouts and
/// no slide, keeps nothing about its place, and opens beside the main panel. Closing it, with
/// Close and Discard in its top bar's menu or Command-W, discards its conversation, so Escape
/// never closes it.
@MainActor
final class SummonPanel: NSPanel {
    /// Which window this is.
    enum Role: Equatable {
        /// The main panel the hotkey and the menu bar icon toggle.
        case main
        /// The incognito window, opened beside the main panel.
        case incognito
    }

    /// The incognito window's size when it opens. It is for opening apps and short questions,
    /// so it is smaller than the main panel.
    static let incognitoSize = NSSize(width: 480, height: 500)
    static let defaultSize = NSSize(width: 640, height: 560)
    static let minimumSize = NSSize(width: 440, height: 300)
    private static let frameName = "SummonPanel"
    static let presetKey = "SummonPanelPreset"
    static let centeredFrameKey = "SummonPanelCenteredFrame"
    static let slideOverWidthKey = "SummonPanelSlideOverWidth"
    /// Where PR #17 kept the dock state and the frame from before docking. Read once, moved to
    /// the keys above, and removed.
    static let legacyDockKey = "SummonPanelDock"
    static let legacyUndockedFrameKey = "SummonPanelUndockedFrame"
    /// The preferences previews and tests read, such as the agent's name, so they never read
    /// the owner's.
    static let previewPreferences = UserDefaults(suiteName: "dev.lubelski.mac-os-agent.preview") ?? .standard

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

    let role: Role
    private let session: AgentSession
    let placement = PanelPlacement()
    /// For the incognito window: the main panel's frame when it has one, to open beside it.
    var mainPanelFrame: () -> CGRect? = { nil }
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

    /// Keep on Top, shared by both panels. Only the main panel's top bar menu changes it.
    let keepOnTop: KeepOnTopSetting
    /// Whether the panel or its inspector has keyboard focus. Tests stand in their own.
    var hasFocus: (SummonPanel) -> Bool = { $0.isKeyWindow || $0.inspectorWindow.isKeyWindow }
    /// True when focus has gone to another app: no window of this app is key and the
    /// frontmost app is another one.
    var anotherApplicationHasFocus: () -> Bool = {
        NSApp.keyWindow == nil
            && NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier
    }
    /// The window number of the frontmost app's front ordinary window, to order the panel
    /// below when it drops behind that app.
    var frontmostApplicationWindow: () -> Int? = { SummonPanel.frontWindowOfFrontmostApplication() }
    /// Orders the panel below a window, by window number. Tests stand in a recorder.
    var orderBelow: (SummonPanel, Int) -> Void = { panel, number in panel.order(.below, relativeTo: number) }
    /// Holds the panel above ordinary windows without focus, for previews, which never take
    /// focus and are captured over whatever is on screen.
    var floatsWithoutFocus = false
    /// The layer the panel is in now.
    private(set) var layer: PanelLayer = .ordinary
    /// The app's own window, such as Settings, that took focus after the panel did.
    private var ownWindowInFront = OwnWindowInFront<ObjectIdentifier>()
    private weak var ownWindowInFrontWindow: NSWindow?
    private var layeringUpdateIsScheduled = false

    /// True once the panel has a frame on screen, restored or placed.
    private var hasBeenPlaced = false
    /// True while the panel moves itself, so the move is not taken for the owner's drag.
    private var isPlacing = false
    /// The centered frame to come back to from slide over.
    private var centeredFrame: CGRect?
    /// The width the owner left the slide over panel at.
    private var slideOverWidth: CGFloat?
    /// The strip the window has beyond the glass on its edge side. None now that slide over is
    /// flush against the edge, but kept for a frame that does not reach it.
    private var inset: (edge: PanelEdge, width: CGFloat)?
    /// The slide under way, if any.
    private(set) var slide: PanelSlide?
    private var displayLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval?
    /// True while the window is ordered in, including on its way out.
    private(set) var isOrderedIn = false
    /// True when the panel is showing or on its way in. False when hidden or on its way out.
    private(set) var isPresented = false
    /// How far the window reaches below `panelFrame` to hold the list under the text field.
    private(set) var footerGrowth: CGFloat = 0
    /// The window's size while grown, to tell the owner's resize from the growth.
    private var grownSize: CGSize?
    /// The frame autosave name, set aside while the window is grown so the grown frame is
    /// never saved.
    private var suspendedAutosaveName: NSWindow.FrameAutosaveName?

    /// - Parameters:
    ///   - role: the main panel, or the incognito window. The incognito window never reads or
    ///     writes the defaults, whatever the other arguments say.
    ///   - remembersFrame: false for preview runs, so they neither read nor overwrite the frame
    ///     or the preset the owner left the panel with.
    ///   - placementDefaults: where to keep the preset. Defaults to the standard defaults when
    ///     the panel remembers its frame, and to memory only when it does not.
    ///   - screens: the screens to place the panel on. Defaults to the connected displays.
    ///   - mouseLocation: where the mouse is. Defaults to the real one.
    ///   - keepOnTop: Keep on Top. Defaults to the shared setting when the panel remembers its
    ///     frame, and to one in memory only, off, when it does not.
    init(
        session: AgentSession, role: Role = .main, remembersFrame: Bool = true, placementDefaults: UserDefaults? = nil,
        keepOnTop: KeepOnTopSetting? = nil,
        screens: @escaping () -> [Screen] = { NSScreen.screens.map { Screen(frame: $0.frame, visible: $0.visibleFrame) } },
        mouseLocation: @escaping () -> CGPoint = { NSEvent.mouseLocation }
    ) {
        self.role = role
        self.session = session
        self.screens = screens
        self.mouseLocation = mouseLocation
        self.keepOnTop = keepOnTop ?? (remembersFrame ? .shared : KeepOnTopSetting(defaults: nil))
        let remembersFrameArgument = remembersFrame
        // Remembering where the incognito window was would be a trace of it.
        let remembersFrame = remembersFrame && role == .main
        defaults = role == .incognito ? nil : placementDefaults ?? (remembersFrame ? .standard : nil)
        hostingController = NSHostingController(rootView: AnyView(EmptyView()))
        // The window's size is the owner's to choose, not the content's.
        hostingController.sizingOptions = []
        let size = role == .incognito ? Self.incognitoSize : Self.defaultSize
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true)
        isFloatingPanel = true
        // On every Space and over a full screen app, because it stays up while the owner works
        // in other apps. Mission Control leaves it out. Its level follows focus, Keep on Top,
        // and the app's own windows: see `updateLayering()`.
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
        placement.close = { [weak self] in self?.closeButtonPressed() }
        placement.resetToDefault = { [weak self] in self?.resetToDefaultPlace() }
        placement.offersLayouts = role == .main
        placement.keepsOnTop = self.keepOnTop.isOn
        if role == .main {
            // The incognito window shows that Keep on Top is on but never changes it, since it
            // writes nothing to the preferences.
            let setting = self.keepOnTop
            placement.setKeepsOnTop = { setting.set($0) }
        }
        inspectorWindow = ToolInspectorWindow(inspector: inspector, session: session, defaults: defaults)
        inspector.callIDs = { [weak session] in session?.transcript.toolCallIDs ?? [] }
        inspector.onChange = { [weak self] in self?.updateInspector() }
        inspectorWindow.onResize = { [weak self] in self?.placeInspector() }
        // A preview reads the agent's name from the preview preferences, never the owner's.
        let preferences = remembersFrameArgument ? UserDefaults.standard : Self.previewPreferences
        hostingController.rootView = AnyView(SummonView(session: session, onDismiss: { [weak self] in
            self?.escape()
        }).environment(placement).environment(inspector).defaultAppStorage(preferences))

        container.frame = NSRect(origin: .zero, size: size)
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        contentView = container
        setContentSize(size)
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
        center.addObserver(self, selector: #selector(windowDidBecomeKey(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowDidResignKey(_:)), name: NSWindow.didResignKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil)
        center.addObserver(self, selector: #selector(keepOnTopDidChange), name: KeepOnTopSetting.didChange, object: self.keepOnTop)
        applyLayer(PanelLayering.layer(for: layeringState))
        session.suggestionList.layoutNeedsUpdate = { [weak self] in self?.updateFooterGrowth() }
        observeSuggestionList()
        observeCornerRadius()
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
        PanelShape.clipToSurface(layer)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The glass's frame on screen when it is in place: the window's frame less any strip on
    /// the edge side, and less the room it grew downward for the list under the text field.
    /// Everything that remembers or reasons about the panel's place reads this, so the growth
    /// reaches none of it.
    var panelFrame: CGRect {
        var glass = frame
        if footerGrowth > 0 {
            glass.origin.y += footerGrowth
            glass.size.height -= footerGrowth
        }
        guard let inset else { return glass }
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
        raiseForFocus()
        orderIn(self, true)
        scheduleLayeringUpdate()
        isOrderedIn = true
        session.panelDidAppear()
    }

    /// Shows the panel for a screenshot without making it key, so the frontmost app keeps
    /// keyboard focus. A slide over panel slides in as it would on a summon.
    func showForPreview() {
        floatsWithoutFocus = true
        updateLayering()
        present(makeKey: false)
    }

    private func present(makeKey: Bool) {
        // A summon brings the panel to the front, over a full screen app too. It is raised
        // before it is ordered in, so its first frame is already in front.
        if makeKey { raiseForFocus() }
        if isOrderedIn, var slide, slide.target == .hidden {
            // On its way out: turn around from where it is.
            slide.retarget(.shown)
            self.slide = slide
            isPresented = true
            orderIn(self, makeKey)
            scheduleLayeringUpdate()
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
        scheduleLayeringUpdate()
        // A list of slash commands still showing for the draft comes back with the panel.
        updateFooterGrowth()
    }

    /// Hides the panel. In slide over it slides out past its edge first. It never stops a task.
    func dismiss() {
        guard isPresented || isOrderedIn else { return }
        // Hiding closes the list, and the window is its own size again before it goes.
        session.closeSuggestionList()
        isPresented = false
        setFooterGrowth(0)
        if var slide {
            slide.retarget(.hidden)
            self.slide = slide
        } else if isOrderedIn, placement.preset.slideOverEdge != nil {
            startSlide(to: .hidden)
        } else {
            finishHiding()
        }
    }

    /// Escape dismisses an instant action suggestion or the list of slash commands first when
    /// one is showing, then closes the inspector when it is open, and hides the main panel on
    /// the next press.
    ///
    /// In the incognito window it never goes further than the inspector. Closing that window
    /// discards its conversation, so a reflex press of Escape must not do it. A question about
    /// closing while a task runs is answered no.
    func escape() {
        if session.pendingDiscard != nil {
            session.cancelDiscard()
            return
        }
        if session.dismissSuggestionOrHint() { return }
        if inspector.isOpen {
            inspector.close()
        } else if role == .main {
            dismiss()
        }
    }

    override func cancelOperation(_ sender: Any?) {
        escape()
    }

    /// Command-Period goes to the main menu's Stop before the window's views, so no button whose
    /// shortcut is Escape, such as the go-ahead card's Don't Run, takes it as Escape.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if MainMenu.isStopShortcut(event), let menu = NSApp.mainMenu {
            return menu.performKeyEquivalent(with: event)
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Stop in the main menu, Command-Period: stops this window's task.
    @objc func stopTask(_ sender: Any?) {
        session.stop()
    }

    /// Close in the Window menu is always enabled. AppKit's own check turns it down for a
    /// window without the standard close button, which this borderless panel is, and a disabled
    /// item takes Command-W and does nothing.
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == MainMenu.stopTaskAction { return session.isRunning }
        if item.action == #selector(performClose(_:)) { return true }
        return super.validateMenuItem(item)
    }

    /// Command-W, from the Window menu. The last item in the top bar's menu does the same.
    override func performClose(_ sender: Any?) {
        closeButtonPressed()
    }

    /// The top bar menu's last item and Command-W. The main panel hides and its task keeps
    /// going. The incognito window closes and discards its conversation, after asking when a
    /// task runs.
    private func closeButtonPressed() {
        switch role {
        case .main: dismiss()
        case .incognito: session.requestDiscard(.close)
        }
    }

    /// The Show or Hide item in the menu bar menu. It follows whether the panel is presented,
    /// so during a slide out it already offers Show, and choosing it turns the slide around.
    var menuItemHides: Bool { isPresented }

    func toggleFromMenu() {
        if isPresented { dismiss() } else { summon() }
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
        // The pointer leaves with the window, and no exit comes for it, so the close button
        // is hidden again when the panel next shows.
        placement.barIsHovered = false
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

    /// Puts the panel back at its preset's default frame: Centered at the default size in the
    /// middle of its screen, slide over flush against its edge at the full height and the width
    /// it was left at. The same as choosing the current preset again from the layout menu, so
    /// `placement.choose(placement.preset)` does it from the panel's content. The frames come
    /// from `PanelGeometry.presetFrame`.
    func returnToPresetFrame() {
        choose(placement.preset)
    }

    /// Moves the panel to a preset. Centered comes back to the frame it had before slide over,
    /// or, when it is already centered, goes to the default size in the middle of its screen.
    /// A slide over preset slides in from its edge when the panel is showing.
    func choose(_ preset: PanelPreset) {
        collapseFooter()
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
                    place(presetFrame(.centered, in: visible))
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

    /// A double click on the top bar. The panel goes back to its preset's frame on the screen
    /// it is on, as if the owner had never moved or resized it there, and forgets what it
    /// remembered for that preset. The frames come from `returnToPresetFrame()`, so they are
    /// the ones the layout menu uses.
    /// - Centered: the default size in the middle of the screen. The frame from before slide
    ///   over is forgotten too.
    /// - Slide over: the default width against its edge, which replaces the remembered width,
    ///   so the panel comes back at it from Centered too.
    /// - The incognito window: its opening size, beside the main panel. It remembers nothing.
    ///
    /// It moves at once, as choosing a preset does: the layouts have no animated move to share.
    func resetToDefaultPlace() {
        guard role == .main else {
            collapseFooter()
            placeOnActiveScreen(size: Self.incognitoSize)
            updatePlacementFrames()
            placeInspector()
            return
        }
        if placement.preset.slideOverEdge != nil {
            slideOverWidth = Self.defaultSize.width
        } else {
            centeredFrame = nil
        }
        returnToPresetFrame()
    }

    /// Puts a slide over panel in place at its edge of its screen, at the full height and the
    /// width the owner left it at. The height is held there, so only the free edge resizes.
    private func applyPreset() {
        guard let edge = placement.preset.slideOverEdge, let visible = currentScreen()?.visible else { return }
        let glass = presetFrame(placement.preset, in: visible)
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

    /// Where a preset puts the panel on a screen, from `PanelGeometry.presetFrame`.
    private func presetFrame(_ preset: PanelPreset, in visible: CGRect) -> CGRect {
        PanelGeometry.presetFrame(
            preset, centeredSize: Self.defaultSize, slideOverWidth: slideOverWidth ?? panelFrame.width,
            minimumWidth: Self.minimumSize.width, in: visible)
    }

    private func place(_ target: CGRect) {
        // The target is a place for the panel itself. Any growth for the list is dropped.
        if footerGrowth > 0 { forgetFooterGrowth() }
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
        updateSquareEdges()
    }

    /// The sides whose corners are square now, because they are flush against the screen's
    /// edge. The glass reads them from `placement`.
    private(set) var squareEdges: Set<PanelEdge> = []
    /// The radius the glass's layer is clipped to now. See `PanelPlacement.cornerRadius`.
    private var clippedCornerRadius = PanelShape.cornerRadius

    /// Squares the clip on the glass's layer on the sides flush against the screen's edge, and
    /// rounds it again when the panel moves off. The window server traces the shadow from what
    /// the window draws, so it is traced again now and once more after the glass has redrawn
    /// in its new shape. That keeps the shadow on the rounded corners, not on a square fill.
    private func updateSquareEdges() {
        let edges = placement.squareEdges
        let radius = placement.cornerRadius
        guard edges != squareEdges || radius != clippedCornerRadius else { return }
        squareEdges = edges
        clippedCornerRadius = radius
        if let layer = host.layer { PanelShape.clipToSurface(layer, squareEdges: edges, radius: radius) }
        invalidateShadow()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.invalidateShadow() }
        }
    }

    /// A move or resize by the owner. Resizing the free edge of a slide over panel keeps it
    /// there and remembers the width. Dragging it away makes it Centered where it was dropped.
    @objc private func frameDidChange() {
        defer {
            updatePlacementFrames()
            placeInspector()
        }
        guard !isPlacing, slide == nil else { return }
        if let grownSize, frame.size != grownSize {
            // The owner resized the grown window. It keeps the size they gave it, and the list
            // closes, since the window is no longer grown for it.
            forgetFooterGrowth()
            session.closeSuggestionList()
        }
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
        collapseFooter()
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

    // MARK: - The footer's list

    /// The least room left below the grown window, so it never ends flush with the bottom of
    /// the screen, where its corners would read as square.
    static let footerGrowthMargin: CGFloat = 8

    /// Whether the window can grow downward by this much where it is: a centered panel,
    /// showing, not sliding, with the room below it on its screen. In slide over it is full
    /// height, so the list is drawn over the conversation instead.
    func canGrowDownward(by height: CGFloat) -> Bool {
        guard isPresented, slide == nil, placement.preset.slideOverEdge == nil,
              let visible = currentScreen()?.visible else { return false }
        return panelFrame.minY - visible.minY >= height + Self.footerGrowthMargin
    }

    /// Grows or shrinks the window for the list under the text field, or leaves it at its own
    /// size and lets the list cover the bottom of the conversation when there is no room.
    func updateFooterGrowth() {
        let wanted = session.suggestionListHeight
        setFooterGrowth(wanted > 0 && canGrowDownward(by: wanted) ? wanted : 0)
    }

    /// Moves the window's bottom edge down by `growth` below `panelFrame`. The top stays where
    /// it is, so the conversation and the text field do not move. The frame is not saved while
    /// grown, and is saved at the panel's own size again afterward.
    private func setFooterGrowth(_ growth: CGFloat) {
        guard growth != footerGrowth else { return }
        let resting = panelFrame
        if growth > 0, suspendedAutosaveName == nil, !frameAutosaveName.isEmpty {
            suspendedAutosaveName = frameAutosaveName
            setFrameAutosaveName("")
        }
        footerGrowth = growth
        var target = resting
        target.origin.y -= growth
        target.size.height += growth
        isPlacing = true
        setFrame(target, display: true)
        isPlacing = false
        grownSize = growth > 0 ? frame.size : nil
        layoutHost(offset: 0)
        session.suggestionList.growth = growth
        if growth == 0 { resumeFrameAutosave() }
    }

    /// Takes the growth as part of the window, without moving it: before the window is put
    /// somewhere else, or after the owner resized it.
    private func forgetFooterGrowth() {
        footerGrowth = 0
        grownSize = nil
        session.suggestionList.growth = 0
        resumeFrameAutosave()
    }

    private func resumeFrameAutosave() {
        guard let name = suspendedAutosaveName else { return }
        suspendedAutosaveName = nil
        setFrameAutosaveName(name)
        saveFrame(usingName: name)
    }

    /// Closes the list and puts the window back at its own size, before the panel is moved to
    /// another place.
    private func collapseFooter() {
        session.closeSuggestionList()
        setFooterGrowth(0)
    }

    /// Clips the glass again when its radius changes, as the panel with bars switch does.
    private func observeCornerRadius() {
        withObservationTracking {
            _ = placement.cornerRadius
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.updateSquareEdges()
                    self.observeCornerRadius()
                }
            }
        }
    }

    /// Follows changes to the list that come from typing, a turn after they happen, since they
    /// arrive while the text field is still processing the edit. The list keeps the room the
    /// window has until then, so nothing above it moves in between.
    private func observeSuggestionList() {
        withObservationTracking {
            _ = session.suggestionListHeight
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.updateFooterGrowth()
                    self.observeSuggestionList()
                }
            }
        }
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
        inspectorWindow.level = level
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

    /// The default place on the screen that has the mouse. The incognito window goes beside
    /// the main panel instead, on the main panel's screen, when the main panel has a place.
    private func placeOnActiveScreen(size: CGSize? = nil) {
        let screens = screens()
        let size = size ?? panelFrame.size
        if role == .incognito, let main = mainPanelFrame(),
           let index = PanelGeometry.screenIndex(for: main, among: screens.map(\.frame))
        {
            place(PanelGeometry.besideFrame(size: size, beside: main, in: screens[index].visible))
            return
        }
        guard let visible = mouseScreen(screens)?.visible else { return }
        place(PanelGeometry.defaultFrame(size: size, in: visible))
    }

    /// Where the panel is when it has been placed, for a window that opens beside it.
    var placedFrame: CGRect? { hasBeenPlaced ? panelFrame : nil }

    // MARK: - Layering

    /// What decides the panel's layer now. See `PanelLayering`.
    var layeringState: PanelLayeringState {
        if let window = ownWindowInFrontWindow, !window.isVisible {
            ownWindowInFront.windowClosed(ObjectIdentifier(window))
            ownWindowInFrontWindow = nil
        }
        if ownWindowInFrontWindow == nil, let id = ownWindowInFront.window {
            ownWindowInFront.windowClosed(id)
        }
        return PanelLayeringState(
            hasFocus: hasFocus(self), keepsOnTop: keepOnTop.isOn || floatsWithoutFocus,
            ownWindowInFront: ownWindowInFront.window != nil)
    }

    /// Puts the panel, and its inspector with it, in the layer its state calls for. When it
    /// drops to the ordinary windows it goes below the window that took focus from it, since
    /// a change of level alone would leave it in front of that window.
    func updateLayering() {
        layeringUpdateIsScheduled = false
        let state = layeringState
        let old = layer
        let new = PanelLayering.layer(for: state)
        applyLayer(new)
        guard isVisible, let lowering = PanelLayering.lowering(
            from: old, to: new, ownWindowInFront: state.ownWindowInFront,
            anotherApplicationIsFrontmost: anotherApplicationHasFocus())
        else { return }
        switch lowering {
        case .belowOwnWindow:
            if let window = ownWindowInFrontWindow { orderBelow(self, window.windowNumber) }
        case .belowFrontmostApplication:
            if let number = frontmostApplicationWindow() { orderBelow(self, number) }
        case .inPlace:
            break
        }
    }

    /// Focus moves in steps, such as from the panel to its inspector, and the window that
    /// takes focus may be ordered front just after. The layer is worked out once things settle,
    /// on the next turn of the run loop.
    func scheduleLayeringUpdate() {
        guard !layeringUpdateIsScheduled else { return }
        layeringUpdateIsScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.updateLayering() }
        }
    }

    /// Raises the panel at once for a summon, before it has focus, so it is ordered in on top.
    private func raiseForFocus() {
        ownWindowInFront.panelTookFocus()
        ownWindowInFrontWindow = nil
        applyLayer(.floating)
    }

    private func applyLayer(_ new: PanelLayer) {
        layer = new
        let level: NSWindow.Level = new == .floating ? .floating : .normal
        if self.level != level { self.level = level }
        if let inspectorWindow, inspectorWindow.level != level { inspectorWindow.level = level }
        if placement.keepsOnTop != keepOnTop.isOn { placement.keepsOnTop = keepOnTop.isOn }
    }

    /// Whether a window is part of a summoned panel: a panel or an inspector, this one's or
    /// the other window's. Focus moving between them is not the app's own window in front.
    private static func isPartOfAPanel(_ window: NSWindow) -> Bool {
        window is SummonPanel || window is ToolInspectorWindow
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === self || window === inspectorWindow {
            ownWindowInFront.panelTookFocus()
            ownWindowInFrontWindow = nil
        } else if !Self.isPartOfAPanel(window) {
            // Settings, a sheet on it, an alert, or a file panel.
            ownWindowInFront.ownWindowTookFocus(ObjectIdentifier(window))
            ownWindowInFrontWindow = window
        }
        scheduleLayeringUpdate()
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        scheduleLayeringUpdate()
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window !== self else { return }
        ownWindowInFront.windowClosed(ObjectIdentifier(window))
        if ownWindowInFrontWindow === window { ownWindowInFrontWindow = nil }
        scheduleLayeringUpdate()
    }

    @objc private func keepOnTopDidChange() {
        updateLayering()
    }

    /// The front ordinary window of the frontmost app, from the window server's list, which
    /// is front to back. It reports window numbers, layers, and owners without Screen
    /// Recording permission.
    static func frontWindowOfFrontmostApplication() -> Int? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }
        let window = list.first { info in
            (info[kCGWindowOwnerPID as String] as? Int32) == application.processIdentifier
                && (info[kCGWindowLayer as String] as? Int) == 0
                && ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0
        }
        return window?[kCGWindowNumber as String] as? Int
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
