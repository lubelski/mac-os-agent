import AppKit
import MacOSAgentCore
import SwiftUI
import Testing
@testable import mac_os_agent

/// The close button at the left end of the top bar: hidden at rest, shown while the pointer is
/// over the bar, a button wherever it is drawn, and the same action as Command-W. The panels
/// are never put on screen: ordering in and out is recorded, and the pointer coming onto the
/// bar is the drag area's own entered and exited events.
@MainActor
@Suite(.serialized) struct TopBarCloseButtonTests {
    init() { _ = NSApplication.shared }

    private let suiteName = "mac-os-agent-close-button-tests-\(UUID().uuidString)"
    private let standIn = StandInScreens()

    private func cleanUp() {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private func makePanel(session: AgentSession, role: SummonPanel.Role = .main) throws -> (SummonPanel, WindowRecorder) {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let standIn = standIn
        let recorder = WindowRecorder()
        let panel = SummonPanel(
            session: session, role: role, remembersFrame: false, placementDefaults: defaults,
            screens: { standIn.screens }, mouseLocation: { standIn.mouse })
        panel.orderIn = { _, makeKey in recorder.orderedIn.append(makeKey) }
        panel.orderAway = { _ in recorder.orderedAway += 1 }
        panel.drivesSlidesWithTheDisplay = false
        panel.reduceMotion = { false }
        panel.setFrame(CGRect(x: 300, y: 200, width: 640, height: 560), display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        PanelHarness.turnTheRunLoop()
        return (panel, recorder)
    }

    private func dragArea(in panel: NSWindow) throws -> WindowDragArea.DragView {
        try #require(Self.first(WindowDragArea.DragView.self, in: panel.contentView!))
    }

    private static func first<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let view = view as? T { return view }
        for subview in view.subviews {
            if let found = first(type, in: subview) { return found }
        }
        return nil
    }

    private func crossing(_ type: NSEvent.EventType, _ window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.enterExitEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
    }

    /// What the close button calls. A synthesized click does not reach a SwiftUI button in a
    /// window that is not on screen, and SwiftUI builds no accessibility elements for the bar
    /// without an assistive app asking, so the press is the button's action, `placement.close`.
    /// That the button takes a click on its spot while it is not drawn is
    /// `PanelPlacementTests.theBarMovesThePanelExceptOverItsControls`.
    private func pressClose(_ panel: SummonPanel) {
        panel.placement.close()
        PanelHarness.turnTheRunLoop()
    }

    // MARK: - Showing on hover

    @Test func itIsHiddenAtRestAndShowsWhileThePointerIsOverTheBar() throws {
        defer { cleanUp() }
        let (panel, _) = try makePanel(session: try #require(PanelPreview.session(named: "empty")))
        panel.summon()
        let drag = try dragArea(in: panel)
        #expect(!panel.placement.barIsHovered)
        #expect(CloseButton.opacity(barIsHovered: false) == 0)

        drag.mouseEntered(with: try crossing(.mouseEntered, panel))
        #expect(panel.placement.barIsHovered)
        #expect(CloseButton.opacity(barIsHovered: true) == 1)

        drag.mouseExited(with: try crossing(.mouseExited, panel))
        #expect(!panel.placement.barIsHovered)
    }

    /// The drag area lies under the whole bar and tracks the pointer wherever it is on it,
    /// whether or not the app is active, which it never is while the panel has focus.
    @Test func theWholeBarTracksThePointerWhileTheAppIsInactive() throws {
        defer { cleanUp() }
        let (panel, _) = try makePanel(session: try #require(PanelPreview.session(named: "empty")))
        let drag = try dragArea(in: panel)
        drag.updateTrackingAreas()
        let area = try #require(drag.trackingAreas.first)
        #expect(area.options.contains(.mouseEnteredAndExited))
        #expect(area.options.contains(.activeAlways))
        #expect(area.options.contains(.inVisibleRect))
        #expect(drag.frame.width == panel.contentView!.bounds.width)
        #expect(drag.frame.height == PanelTopBar.height)
    }

    /// The pointer leaves with the window and no exit comes for it, so a hidden panel shows
    /// the bar at rest when it comes back.
    @Test func itIsHiddenAgainWhenThePanelComesBack() throws {
        defer { cleanUp() }
        let (panel, _) = try makePanel(session: try #require(PanelPreview.session(named: "empty")))
        panel.summon()
        panel.placement.barIsHovered = true
        panel.dismiss()
        #expect(!panel.placement.barIsHovered)
    }

    // MARK: - What it does

    /// Pressed at rest, before the pointer has shown it, it hides the main panel.
    @Test func pressedAtRestItHidesTheMainPanel() throws {
        defer { cleanUp() }
        let (panel, recorder) = try makePanel(session: try #require(PanelPreview.session(named: "empty")))
        panel.summon()
        #expect(!panel.placement.barIsHovered)
        pressClose(panel)
        #expect(!panel.isPresented)
        #expect(recorder.orderedAway == 1)
    }

    @Test func itHidesTheMainPanelAndItsTaskKeepsGoing() async throws {
        defer { cleanUp() }
        let provider = EchoProvider()
        provider.holds = true
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "mac-os-agent-close-button-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let thread = try ThreadStore(fileURL: folder.appending(path: "thread.jsonl"))
        let session = AgentSession(
            loop: AgentLoop(provider: provider, thread: thread, tools: [], episodeTimeout: { 1800 }),
            authenticator: nil, episodeTimeout: { 1800 }, signedIn: true)
        let (panel, _) = try makePanel(session: session)
        panel.summon()
        session.draft = "tidy the desktop"
        session.submit()
        panel.placement.barIsHovered = true
        pressClose(panel)
        #expect(!panel.isPresented)
        #expect(session.isRunning)
        session.stop()
        await session.waitUntilIdle()
    }

    /// In the incognito window it goes through the discard question, as Close and Discard and
    /// Command-W do: at once with no task, and asking first with one.
    @Test func inTheIncognitoWindowItClosesOrAsks() async throws {
        let provider = EchoProvider()
        let standIn = standIn
        let controller = IncognitoWindowController(
            makeSession: {
                AgentSession(
                    incognito: { AgentLoop(provider: provider, thread: InMemoryThreadStore(), tools: [], episodeTimeout: { .infinity }) },
                    signedIn: true)
            },
            makePanel: { session in
                let panel = SummonPanel(
                    session: session, role: .incognito, remembersFrame: false,
                    screens: { standIn.screens }, mouseLocation: { standIn.mouse })
                panel.orderIn = { _, _ in }
                panel.orderAway = { _ in }
                panel.drivesSlidesWithTheDisplay = false
                return panel
            })

        // With a task running, it asks.
        provider.holds = true
        controller.open()
        var panel = try #require(controller.panel)
        panel.contentView?.layoutSubtreeIfNeeded()
        PanelHarness.turnTheRunLoop()
        var session = try #require(controller.session)
        session.draft = "a secret"
        session.submit()
        panel.placement.barIsHovered = true
        pressClose(panel)
        #expect(session.pendingDiscard == .close)
        #expect(controller.isOpen)
        session.cancelDiscard()
        session.stop()
        await session.waitUntilIdle()

        // With none, it closes and discards.
        pressClose(panel)
        #expect(!controller.isOpen)

        // A second window, opened after the first was discarded, closes the same way.
        provider.holds = false
        controller.open()
        panel = try #require(controller.panel)
        panel.contentView?.layoutSubtreeIfNeeded()
        PanelHarness.turnTheRunLoop()
        session = try #require(controller.session)
        pressClose(panel)
        #expect(!controller.isOpen)
    }

    // MARK: - Nothing shifts

    /// Rendered at rest and hovered, the bar differs only where the close button is, so the
    /// name does not move, and the name is centered on the whole bar.
    @Test(arguments: [false, true])
    func theTitleStaysCenteredAndOnlyTheButtonChanges(incognito: Bool) throws {
        let suite = "mac-os-agent-close-button-render-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        PanelTopBar.hostsAppKitViews = false
        defer { PanelTopBar.hostsAppKitViews = true }
        let width: CGFloat = 480
        func render(hovered: Bool) throws -> NSBitmapImageRep {
            let placement = PanelPlacement()
            placement.offersLayouts = !incognito
            placement.barIsHovered = hovered
            let view = PanelTopBar(incognito: incognito ? .init(canClear: true, clear: {}) : nil)
                .environment(placement)
                .defaultAppStorage(preferences)
                .frame(width: width)
                .foregroundStyle(.black)
                .background(.white)
                .transaction { $0.animation = nil }
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            return NSBitmapImageRep(cgImage: image)
        }
        let rest = try render(hovered: false)
        let hovered = try render(hovered: true)
        #expect(rest.pixelsWide == hovered.pixelsWide && rest.pixelsHigh == hovered.pixelsHigh)

        func columnsWithInk(_ bitmap: NSBitmapImageRep, in range: Range<Int>) -> [Int] {
            range.filter { x in
                (0..<bitmap.pixelsHigh).contains { y in
                    guard let color = bitmap.colorAt(x: x, y: y) else { return false }
                    return color.redComponent < 0.9
                }
            }
        }
        func changedColumns() -> [Int] {
            (0..<rest.pixelsWide).filter { x in
                (0..<rest.pixelsHigh).contains { y in rest.colorAt(x: x, y: y) != hovered.colorAt(x: x, y: y) }
            }
        }
        let buttonEnd = Int(PanelTopBar.sidePadding + TopBarButton.size)
        let changed = changedColumns()
        #expect(!changed.isEmpty, "the button shows on hover")
        #expect(changed.allSatisfy { $0 >= Int(PanelTopBar.sidePadding) - 1 && $0 <= buttonEnd + 1 }, "only the button's spot changes")
        #expect(columnsWithInk(rest, in: 0..<buttonEnd).isEmpty, "nothing is drawn there at rest")

        if !incognito {
            // Between the two ends there is only the name.
            let ink = columnsWithInk(rest, in: buttonEnd + 1..<Int(width) - buttonEnd - 1)
            let first = try #require(ink.first), last = try #require(ink.last)
            #expect(abs(Double(first + last) / 2 - Double(width) / 2) <= 1.5, "the name is centered on the bar")
        }
    }
}
