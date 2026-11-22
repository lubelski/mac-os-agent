import AppKit
import MacOSAgentCore
import Testing
@testable import mac_os_agent

/// What the tests pretend about focus and the other apps.
@MainActor
final class StandInFocus {
    var panelHasFocus = false
    var anotherApplicationHasFocus = true
    var frontmostApplicationWindow: Int? = 4242
    var orderedBelow: [Int] = []
}

/// How the real panel layers as focus moves, driven with stand-in focus. A panel that has to
/// be on screen for ordering is put far off screen and fully transparent, so nothing shows and
/// nothing takes focus. The Keep on Top setting is kept in a defaults suite of the tests' own.
@MainActor
@Suite(.serialized) struct PanelLayeringAppTests {
    init() { _ = NSApplication.shared }

    private let suiteName = "mac-os-agent-layering-tests-\(UUID().uuidString)"
    private let focus = StandInFocus()
    private let recorder = WindowRecorder()

    private func makePanel(role: SummonPanel.Role = .main, keepOnTop: KeepOnTopSetting) throws -> SummonPanel {
        let session = try #require(PanelPreview.session(named: "empty"))
        let panel = SummonPanel(
            session: session, role: role, remembersFrame: false, keepOnTop: keepOnTop,
            screens: { [StandInScreens.laptop] }, mouseLocation: { CGPoint(x: 700, y: 400) })
        let focus = focus
        panel.hasFocus = { _ in focus.panelHasFocus }
        panel.anotherApplicationHasFocus = { focus.anotherApplicationHasFocus }
        panel.frontmostApplicationWindow = { focus.frontmostApplicationWindow }
        panel.orderBelow = { _, number in focus.orderedBelow.append(number) }
        panel.drivesSlidesWithTheDisplay = false
        panel.reduceMotion = { false }
        return panel
    }

    private func makeSetting() throws -> (KeepOnTopSetting, UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (KeepOnTopSetting(defaults: defaults), defaults)
    }

    private func cleanUp(_ defaults: UserDefaults) {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// Really ordered in, so the panel is visible, but far off screen and transparent.
    private func putOnScreenUnseen(_ window: NSWindow) {
        window.alphaValue = 0
        window.setFrameOrigin(CGPoint(x: -30000, y: -30000))
        window.orderFrontRegardless()
    }

    private func becomeKey(_ window: NSWindow) {
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    }

    private func recordOrdering(_ panel: SummonPanel) {
        let recorder = recorder
        panel.orderIn = { _, makeKey in recorder.orderedIn.append(makeKey) }
        panel.orderAway = { _ in recorder.orderedAway += 1 }
    }

    @Test func atRestThePanelIsAnOrdinaryWindow() throws {
        let (setting, defaults) = try makeSetting()
        defer { cleanUp(defaults) }
        let panel = try makePanel(keepOnTop: setting)
        #expect(panel.layer == .ordinary)
        #expect(panel.level == .normal)
        #expect(panel.inspectorWindow.level == .normal)
    }

    @Test func aSummonRaisesThePanelBeforeItIsOrderedIn() throws {
        let (setting, defaults) = try makeSetting()
        defer { cleanUp(defaults) }
        let panel = try makePanel(keepOnTop: setting)
        var levelWhenOrderedIn: NSWindow.Level?
        panel.orderIn = { panel, _ in levelWhenOrderedIn = panel.level }
        panel.summon()
        #expect(levelWhenOrderedIn == .floating)
        #expect(panel.inspectorWindow.level == .floating)
        // With focus it stays raised.
        focus.panelHasFocus = true
        panel.updateLayering()
        #expect(panel.level == .floating)
        #expect(focus.orderedBelow.isEmpty)
    }

    @Test func losingFocusToAnotherAppDropsItBelowThatAppsWindow() throws {
        let (setting, defaults) = try makeSetting()
        defer { cleanUp(defaults) }
        let panel = try makePanel(keepOnTop: setting)
        defer { panel.orderOut(nil) }
        putOnScreenUnseen(panel)
        focus.panelHasFocus = true
        panel.focus()
        panel.updateLayering()
        #expect(panel.level == .floating)

        focus.panelHasFocus = false
        panel.updateLayering()
        #expect(panel.level == .normal)
        #expect(panel.inspectorWindow.level == .normal)
        #expect(focus.orderedBelow == [4242])
        #expect(panel.isVisible)

        // Nothing more happens by itself, and the next summon raises it again.
        panel.updateLayering()
        #expect(focus.orderedBelow == [4242])
        panel.focus()
        #expect(panel.level == .floating)
    }

    @Test func focusMovingToTheOtherPanelLeavesThisOneInPlace() throws {
        let (setting, defaults) = try makeSetting()
        defer { cleanUp(defaults) }
        let panel = try makePanel(keepOnTop: setting)
        let other = try makePanel(role: .incognito, keepOnTop: setting)
        defer { panel.orderOut(nil) }
        putOnScreenUnseen(panel)
        panel.focus()
        // The incognito window takes focus. No window of another app has it.
        focus.anotherApplicationHasFocus = false
        becomeKey(other)
        panel.updateLayering()
        #expect(panel.level == .normal)
        #expect(focus.orderedBelow.isEmpty)
    }

    @Test(arguments: [false, true])
    func settingsAlwaysComesInFront(keptOnTop: Bool) throws {
        let (setting, defaults) = try makeSetting()
        defer { cleanUp(defaults) }
        setting.set(keptOnTop)
        let panel = try makePanel(keepOnTop: setting)
        let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        settings.isReleasedWhenClosed = false
        defer {
            panel.orderOut(nil)
            settings.orderOut(nil)
        }
        putOnScreenUnseen(panel)
        putOnScreenUnseen(settings)
        focus.panelHasFocus = true
        panel.focus()
        panel.updateLayering()
        #expect(panel.level == .floating)

        // Settings opens, from Command-comma or the menu bar menu.
        focus.panelHasFocus = false
        focus.anotherApplicationHasFocus = false
        becomeKey(settings)
        panel.updateLayering()
        #expect(panel.level == .normal)
        #expect(focus.orderedBelow == [settings.windowNumber])

        // Settings reveals a file in Finder. Finder has focus and the panel stays down.
        focus.anotherApplicationHasFocus = true
        panel.updateLayering()
        #expect(panel.level == .normal)

        // Settings closes. A panel kept on top floats again. Otherwise it stays down.
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: settings)
        panel.updateLayering()
        #expect(panel.level == (keptOnTop ? .floating : .normal))
    }

    @Test func aSheetOrAlertOnSettingsIsInFrontToo() throws {
        let (setting, defaults) = try makeSetting()
        defer { cleanUp(defaults) }
        setting.set(true)
        let panel = try makePanel(keepOnTop: setting)
        let alert = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        alert.isReleasedWhenClosed = false
        defer {
            panel.orderOut(nil)
            alert.orderOut(nil)
        }
        putOnScreenUnseen(panel)
        putOnScreenUnseen(alert)
        becomeKey(alert)
        panel.updateLayering()
        #expect(panel.level == .normal)
        #expect(focus.orderedBelow == [alert.windowNumber])
        // An alert that goes away without closing counts as gone.
        alert.orderOut(nil)
        panel.updateLayering()
        #expect(panel.level == .floating)
    }

    @Test func keepOnTopFloatsWithoutFocusAndIsKeptInThePreferences() throws {
        let (setting, defaults) = try makeSetting()
        defer { cleanUp(defaults) }
        let panel = try makePanel(keepOnTop: setting)
        #expect(!panel.placement.keepsOnTop)
        let set = try #require(panel.placement.setKeepsOnTop)
        set(true)
        #expect(defaults.bool(forKey: KeepOnTopSetting.key))
        #expect(panel.level == .floating)
        #expect(panel.inspectorWindow.level == .floating)
        #expect(panel.placement.keepsOnTop)
        // A new launch reads it back.
        #expect(KeepOnTopSetting(defaults: defaults).isOn)
        set(false)
        #expect(!defaults.bool(forKey: KeepOnTopSetting.key))
        #expect(panel.level == .normal)
    }

    @Test func keepOnTopIsOffByDefault() throws {
        let (setting, defaults) = try makeSetting()
        defer { cleanUp(defaults) }
        #expect(!setting.isOn)
        #expect(!KeepOnTopSetting(defaults: nil).isOn)
    }

    @Test func theIncognitoWindowFollowsKeepOnTopAndNeverChangesIt() throws {
        let (setting, defaults) = try makeSetting()
        defer { cleanUp(defaults) }
        let incognito = try makePanel(role: .incognito, keepOnTop: setting)
        #expect(incognito.placement.setKeepsOnTop == nil)
        #expect(incognito.level == .normal)
        setting.set(true)
        #expect(incognito.level == .floating)
        #expect(incognito.placement.keepsOnTop)
    }

    @Test func theLayoutMenuHasKeepOnTopAfterThePresets() throws {
        var chosen: [Bool] = []
        let layoutMenu = LayoutMenu(current: .centered, choose: { _ in }, keepsOnTop: true, setKeepsOnTop: { chosen.append($0) })
        let menu = layoutMenu.menu
        let titles = menu.items.map(\.title)
        #expect(titles == PanelPreset.allCases.map(\.title) + ["", LayoutMenu.keepOnTopTitle])
        #expect(menu.items[PanelPreset.allCases.count].isSeparatorItem)
        let item = try #require(menu.items.last)
        #expect(item.state == .on)
        #expect(item.target === layoutMenu)
        layoutMenu.toggledKeepOnTop(item)
        #expect(chosen == [false])
    }

    @Test func aMenuWithoutTheSettingHasNoKeepOnTop() {
        let menu = LayoutMenu(current: .centered, choose: { _ in }).menu
        #expect(menu.items.map(\.title) == PanelPreset.allCases.map(\.title))
    }

    /// A slide over panel that dropped behind other windows still slides out when hidden, and
    /// slides back in on top when summoned.
    @Test(arguments: PanelEdge.allCases)
    func aSlideOverPanelBehindOtherWindowsSlidesOutAndBackInOnTop(_ edge: PanelEdge) throws {
        let (setting, defaults) = try makeSetting()
        defer { cleanUp(defaults) }
        let panel = try makePanel(keepOnTop: setting)
        recordOrdering(panel)
        panel.choose(PanelPreset(slideOver: edge))
        panel.summon()
        panel.advanceSlide(by: 1)
        #expect(panel.slide == nil)
        #expect(panel.level == .floating)

        // Another app takes focus. The window is not really on screen here, so nothing is
        // ordered, but the level drops.
        focus.panelHasFocus = false
        panel.updateLayering()
        #expect(panel.level == .normal)

        // The menu bar menu hides it, which slides it out behind the other windows.
        panel.toggleFromMenu()
        #expect(panel.slide?.target == .hidden)
        panel.advanceSlide(by: 1)
        #expect(recorder.orderedAway == 1)
        #expect(!panel.isPresented)

        // A summon slides it in, raised from the first frame.
        panel.summon()
        #expect(panel.slide?.target == .shown)
        #expect(panel.level == .floating)
        #expect(recorder.orderedIn.last == true)
        panel.advanceSlide(by: 1)
        #expect(panel.slide == nil)
        #expect(panel.level == .floating)
    }

    @Test func aPreviewFloatsWithoutTakingFocus() throws {
        let (setting, defaults) = try makeSetting()
        defer { cleanUp(defaults) }
        let panel = try makePanel(keepOnTop: setting)
        recordOrdering(panel)
        panel.showForPreview()
        #expect(recorder.orderedIn == [false])
        #expect(panel.level == .floating)
    }
}
