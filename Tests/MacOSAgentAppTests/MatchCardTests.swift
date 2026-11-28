import AppKit
import MacOSAgentCore
import SwiftUI
import Testing
@testable import mac_os_agent

private let up = ("\u{F700}", UInt16(126))
private let down = ("\u{F701}", UInt16(125))
private let arrowFlags: NSEvent.ModifierFlags = [.function, .numericPad]

@MainActor
private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<400 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// The match card's measures, how much of it shows, and its keys. See `MatchCard`.
@MainActor
@Suite struct MatchCardGeometryTests {
    @Test func itIsShortenedToTheRoomDownToOneRowAndAPart() {
        let rows = 4
        let part = MatchCard.partRowHeight
        #expect(part == 17, "0.4 of a 44 point row")
        let reach = MatchCard.reachBelowPanel(rows: rows)
        // The card covers the status line first, then reaches past the panel's edge.
        #expect(reach == MatchCard.heightBelowPill(rows: rows) - InputFooter.height)
        #expect(MatchCard.heightBelowPill(rows: rows) == 4 * 44 + 1 + InputFooter.height)
        #expect(MatchCard.heightBelowPill(rows: 2, partRowHeight: part) == 2 * 44 + 17 + 1 + InputFooter.height)
        #expect(reach == MatchCard.rowHeight * 4 + MatchCard.reachBeyondRows)
        #expect(MatchCard.fit(rows: rows, roomBelow: reach) == MatchListFit(rows: 4, partRowHeight: 0))
        #expect(MatchCard.fit(rows: rows, roomBelow: reach - 1) == MatchListFit(rows: 3, partRowHeight: part), "shortened, and it scrolls")
        let fewest = MatchCard.reachBelowPanel(rows: 2, partRowHeight: part)
        #expect(MatchCard.fit(rows: 7, roomBelow: fewest) == MatchListFit(rows: 2, partRowHeight: part))
        #expect(MatchCard.fit(rows: 7, roomBelow: MatchCard.reachBelowPanel(rows: 3, partRowHeight: part)) == MatchListFit(rows: 3, partRowHeight: part))
        #expect(MatchCard.minimumReach(rows: 7) == fewest, "the panel makes room for less than this")
        #expect(MatchCard.roomMade == fewest)
        #expect(MatchCard.minimumReach(rows: 2) == MatchCard.reachBelowPanel(rows: 2), "two rows show whole")
        #expect(MatchCard.fit(rows: 7, roomBelow: fewest - 1) == MatchListFit(rows: 1, partRowHeight: part), "short of it, still downward")
        #expect(MatchCard.fit(rows: 7, roomBelow: 0) == MatchListFit(rows: 1, partRowHeight: part), "never upward")
        #expect(MatchCard.fit(rows: 0, roomBelow: 1000) == nil, "no rows, no card")
    }

    @Test func theRoomBelowIsLessAMarginAndNoneAtTheBottom() {
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 949)
        let panel = CGRect(x: 300, y: 200, width: 640, height: 560)
        #expect(MatchCard.roomBelow(panel: panel, visible: visible) == 200 - SummonPanel.footerGrowthMargin)
        #expect(MatchCard.roomBelow(panel: panel.offsetBy(dx: 0, dy: -200), visible: visible) == 0)
        #expect(MatchCard.roomBelow(panel: CGRect(x: 1112, y: 0, width: 400, height: 949), visible: visible) == 0, "slide over")
    }

    /// Where the panel goes to make room: a centered one moves up, a slide over one's bottom
    /// edge rises, each by just enough for two rows and a part above the margin.
    @Test func thePanelMakesRoomForTwoRowsAndAPart() {
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 949)
        let made = MatchCard.roomMade + SummonPanel.footerGrowthMargin
        let bottom = CGRect(x: 300, y: 0, width: 640, height: 560)
        #expect(MatchCard.frameMakingRoom(panel: bottom, visible: visible, slideOver: false) == bottom.offsetBy(dx: 0, dy: made))
        let slideOver = CGRect(x: 1112, y: 0, width: 400, height: 949)
        #expect(MatchCard.frameMakingRoom(panel: slideOver, visible: visible, slideOver: true)
            == CGRect(x: 1112, y: made, width: 400, height: 949 - made))
        let roomy = CGRect(x: 300, y: 300, width: 640, height: 560)
        #expect(MatchCard.frameMakingRoom(panel: roomy, visible: visible, slideOver: false) == roomy)
    }

    /// The window below the pill is the pill's width and starts at its bottom edge.
    @Test func theWindowBelowStartsAtThePillsBottomEdge() {
        let content = CGRect(x: 300, y: 200, width: 640, height: 560)
        // In the content, with a top-left origin: 8 from the sides, 26 above the bottom.
        let pill = CGRect(x: 8, y: 560 - 26 - 38, width: 624, height: 38)
        let frame = MatchCard.frameBelow(pill: pill, content: content, rows: 3)
        #expect(frame.minX == 308)
        #expect(frame.width == 624)
        #expect(frame.maxY == content.minY + 26, "the pill's bottom on screen")
        #expect(frame.height == MatchCard.heightBelowPill(rows: 3))
    }

    @Test func eachRowShowsItsKey() {
        let candidate = InstantActionCandidate(
            id: "a", title: "A", strength: .exact, score: 1, target: .quickAction(id: "a"))
        #expect(MatchCard.key(for: .candidate(candidate), at: 0, highlight: 0) == "↵")
        #expect(MatchCard.key(for: .candidate(candidate), at: 0, highlight: 1) == "⌘1")
        #expect(MatchCard.key(for: .candidate(candidate), at: 2, highlight: 0) == "⌘3")
        #expect(MatchCard.key(for: .ask("x"), at: 3, highlight: 0) == "⌘↵")
        #expect(MatchCard.key(for: .ask("x"), at: 3, highlight: 3) == "↵")
        #expect(MatchCard.key(for: .command(.builtIn(.new)), at: 1, highlight: 0) == nil)
    }

    @Test func theSecondLineSaysWhatARowIs() {
        let app = InstalledApplication(
            name: "Sample", bundleIdentifier: "com.example.sample",
            url: URL(filePath: "/Applications/Sample.app", directoryHint: .isDirectory))
        let open = InstantActionCandidate(id: "a", title: "Sample", strength: .exact, score: 1, target: .application(app))
        #expect(MatchCard.detail(for: .candidate(open), incognito: false) == "/Applications/Sample.app")
        let run = InstantActionCandidate(
            id: "q", title: "Lights", detail: "Shortcuts run \"Lights\"", strength: .exact, score: 1, target: .quickAction(id: "q"))
        #expect(MatchCard.detail(for: .candidate(run), incognito: false) == "Quick action · Shortcuts run \"Lights\"")
        #expect(MatchCard.detail(for: .ask("x"), incognito: false) == "Send the text as a message")
    }

    @Test func textOnTheAccentReadsOnIt() {
        #expect(!MatchCard.isLight(NSColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1)), "Glass's blue takes white")
        #expect(MatchCard.isLight(NSColor(srgbRed: 1, green: 0.84, blue: 0.04, alpha: 1)), "High Contrast's yellow takes black")
    }
}

/// The card's keys and state, through the real panel and its text field, with stand-in apps.
@MainActor
@Suite(.serialized) struct MatchCardInputTests {
    init() { _ = NSApplication.shared }

    final class Recorder {
        var opened: [String] = []
    }

    private func harness(bars: Bool = true) throws -> (PanelHarness, Recorder) {
        let session = AgentSession(previewEntries: FooterPreview.thread())
        if bars {
            PanelWithBarsPreview.configure(session)
        } else {
            FooterPreview.configure(session)
        }
        let recorder = Recorder()
        session.instantActions.openApplication = { recorder.opened.append($0.name) }
        session.hidePanel = {}
        return (try PanelHarness(session: session), recorder)
    }

    private func press(_ harness: PanelHarness, _ key: (String, UInt16), _ flags: NSEvent.ModifierFlags = arrowFlags) {
        harness.press(key.0, code: key.1, flags)
    }

    @Test func aMatchOpensTheCardWithNoKey() async throws {
        let (harness, _) = try harness()
        harness.type("chr")
        await harness.settle()
        let session = harness.session
        let matches = try #require(session.instantActions.suggestion?.matches)
        #expect(session.suggestionList.isOpen)
        #expect(session.matchCardRows.count == matches.count + 1)
        #expect(session.matchCardRows.last == .ask("chr"))
        #expect(session.highlightedRowIndex == 0)
        #expect(session.returnTarget == matches[0], "the first is what Return takes, as the engine ranks it")
        #expect(session.footerState == .list(matches[0].target), "the status line shows the list's keys")
        // Typing on to no match closes it.
        harness.type("zzz")
        await harness.settle()
        #expect(session.matchCardRows.isEmpty)
        #expect(!session.showsMatchCard)
    }

    @Test func withTheSwitchOffTheListStillWaitsForDown() async throws {
        let (harness, _) = try harness(bars: false)
        harness.type("chr")
        await harness.settle()
        #expect(!harness.session.suggestionList.isOpen)
        #expect(harness.session.matchCardRows.isEmpty)
        #expect(!harness.session.showsMatchCard)
        press(harness, down)
        #expect(harness.session.suggestionList.isOpen)
        press(harness, up)
        #expect(!harness.session.suggestionList.isOpen, "Up from the first row closes it, as before")
    }

    @Test func theArrowsMoveTheHighlightAndStopAtEachEnd() async throws {
        let (harness, _) = try harness()
        harness.type("chr")
        await harness.settle()
        let session = harness.session
        press(harness, up)
        #expect(session.suggestionList.isOpen, "Up on the first row leaves the card open")
        #expect(session.highlightedRowIndex == 0)
        press(harness, down)
        #expect(session.highlightedRowIndex == 1)
        for _ in 0..<10 { press(harness, down) }
        #expect(session.highlightedRow == .ask("chr"))
        #expect(session.returnTarget == nil)
    }

    @Test func returnActsOnTheHighlightedRow() async throws {
        let (harness, recorder) = try harness()
        harness.type("chr")
        await harness.settle()
        let matches = try #require(harness.session.instantActions.suggestion?.matches)
        let canary = try #require(matches.firstIndex { $0.title == "Google Chrome Canary" })
        for _ in 0..<canary { press(harness, down) }
        harness.press("\r", code: 36, [])
        await harness.settle()
        #expect(recorder.opened == ["Google Chrome Canary"])
        #expect(!harness.session.suggestionList.isOpen)
    }

    @Test func aCommandNumberRunsItsRowWithoutMovingToIt() async throws {
        let (harness, recorder) = try harness()
        harness.type("chr")
        await harness.settle()
        let matches = try #require(harness.session.instantActions.suggestion?.matches)
        let canary = try #require(matches.firstIndex { $0.title == "Google Chrome Canary" })
        #expect(harness.session.highlightedRowIndex == 0)
        harness.press("\(canary + 1)", code: 0, [.command])
        await harness.settle()
        #expect(recorder.opened == ["Google Chrome Canary"])
        #expect(harness.session.instantActions.history.wasPicked(matches[canary].id, for: "chr"), "learned as Return learns it")
        // A number past the rows does nothing.
        harness.type("chr")
        await harness.settle()
        harness.press("9", code: 25, [.command])
        await harness.settle()
        #expect(recorder.opened == ["Google Chrome Canary"])
        #expect(harness.session.draft == "chr")
    }

    @Test func escapeClosesTheCardAndItStaysAwayWhileTyping() async throws {
        let (harness, _) = try harness()
        let panel = try #require(harness.panel as? SummonPanel)
        harness.type("chr")
        await harness.settle()
        panel.escape()
        #expect(!harness.session.suggestionList.isOpen)
        #expect(harness.session.matchCardRows.isEmpty)
        harness.type("o")
        await harness.settle()
        #expect(harness.session.matchCardRows.isEmpty, "dismissed for this draft and what follows it")
        harness.session.draft = ""
        await harness.settle()
        harness.type("saf")
        await harness.settle()
        #expect(harness.session.suggestionList.isOpen, "a new draft opens it again")
    }

    @Test func slashCommandsUseTheSameCard() async throws {
        let (harness, _) = try harness()
        harness.session.skillCommands = SkillCommandsModel(menu: FooterPreview.skills)
        harness.type("/re")
        await harness.settle()
        let rows = harness.session.matchCardRows
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { if case .command = $0 { true } else { false } })
        #expect(harness.session.showsMatchCard)
    }
}

/// Where the card goes, with the real panel, stand-in screens, and a defaults suite of its own.
/// Nothing goes on screen.
@MainActor
@Suite(.serialized) struct MatchCardPlacementTests {
    init() { _ = NSApplication.shared }

    private let suiteName = "mac-os-agent-match-card-tests-\(UUID().uuidString)"
    private let standIn = StandInScreens()
    private var laptop: CGRect { StandInScreens.laptop.visible }

    private func makePanel(frame: CGRect = CGRect(x: 300, y: 300, width: 640, height: 560))
        throws -> (SummonPanel, AgentSession, UserDefaults)
    {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let session = AgentSession(previewEntries: FooterPreview.thread())
        PanelWithBarsPreview.configure(session)
        session.instantActions.openApplication = { _ in }
        let standIn = standIn
        let panel = SummonPanel(
            session: session, remembersFrame: false, placementDefaults: defaults,
            screens: { standIn.screens }, mouseLocation: { standIn.mouse })
        panel.orderIn = { _, _ in }
        panel.orderAway = { _ in }
        panel.drivesSlidesWithTheDisplay = false
        panel.reduceMotion = { false }
        panel.summon()
        panel.setFrame(frame, display: false)
        return (panel, session, defaults)
    }

    @Test func withRoomBelowItOpensDownwardAndThePanelIsUntouched() throws {
        let (panel, session, defaults) = try makePanel()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let name = "mac-os-agent-match-card-test-\(UUID().uuidString)"
        #expect(panel.setFrameAutosaveName(name))
        defer {
            panel.setFrameAutosaveName("")
            UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(name)")
        }
        let before = panel.frame
        let saved = UserDefaults.standard.string(forKey: "NSWindow Frame \(name)")
        #expect(session.suggestionList.roomBelow == 300 - SummonPanel.footerGrowthMargin)
        session.draft = "chr"
        panel.updateFooterGrowth()
        #expect(session.showsMatchCard)
        #expect(panel.footerGrowth == 0, "the window never grows for the card")
        #expect(panel.frame == before)
        #expect(panel.panelFrame == before)
        #expect(panel.placement.panelFrame == before)
        #expect(panel.frameAutosaveName == name, "the autosave is never set aside")
        #expect(UserDefaults.standard.string(forKey: "NSWindow Frame \(name)") == saved)
        // The window below the pill, from where the view measured the pill.
        session.suggestionList.pillFrame = CGRect(x: 8, y: 560 - 26 - 38, width: 624, height: 38)
        let card = try #require(panel.matchCardFrame)
        #expect(card.maxY == before.minY + 26)
        #expect(card.minY < before.minY, "past the panel's bottom edge")
        #expect(!before.contains(card))
        panel.choose(.slideOverLeft)
        #expect(defaults.string(forKey: SummonPanel.centeredFrameKey) == NSStringFromRect(before), "the saved centered frame")
    }

    /// Near the bottom of the screen the card is shortened to the rows that fit. With room for
    /// less than two rows and a part, the panel moves up just far enough for them, and the card
    /// still opens downward.
    @Test(arguments: [CGFloat(0), 4, 60, 100, 150, 250, 400])
    func nearTheBottomOfTheScreenItIsShortenedOrThePanelMovesUp(_ room: CGFloat) throws {
        let start = CGRect(x: 300, y: laptop.minY + room, width: 640, height: 500)
        let (panel, session, defaults) = try makePanel(frame: start)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        session.draft = "chr"
        panel.updateFooterGrowth()
        panel.advanceMatchCardMotion(by: 1)
        let rows = min(session.matchCardRows.count, MatchCard.visibleLimit)
        #expect(rows > 2, "the stand-in apps match more than fit in some of these rooms")
        let available = room - SummonPanel.footerGrowthMargin
        let fits = Int(((available - MatchCard.reachBeyondRows) / MatchCard.rowHeight).rounded(.down))
        let wholeBesidesPart = Int(((available - MatchCard.reachBeyondRows - MatchCard.partRowHeight) / MatchCard.rowHeight).rounded(.down))
        #expect(session.showsMatchCard, "always, and always downward")
        if fits >= rows {
            #expect(session.matchCardVisibleRows == rows)
            #expect(session.matchCardPartRowHeight == 0)
            #expect(panel.frame == start, "the panel stays")
        } else if wholeBesidesPart >= 2 {
            #expect(session.matchCardVisibleRows == wholeBesidesPart)
            #expect(session.matchCardPartRowHeight == MatchCard.partRowHeight, "ends in a part row")
            #expect(panel.frame == start, "the panel stays")
        } else {
            #expect(session.matchCardVisibleRows == 2, "two rows and a part, the minimum")
            #expect(session.matchCardPartRowHeight == MatchCard.partRowHeight)
            #expect(panel.frame.size == start.size)
            #expect(panel.frame.minY == laptop.minY + SummonPanel.footerGrowthMargin + MatchCard.roomMade, "just far enough")
            #expect(panel.panelFrame == panel.frame, "a centered panel reads where it is")
        }
        session.suggestionList.pillFrame = CGRect(x: 8, y: 500 - 26 - 38, width: 624, height: 38)
        let card = try #require(panel.matchCardFrame)
        #expect(card.minY >= laptop.minY + SummonPanel.footerGrowthMargin, "it ends inside the screen")
        #expect(card.maxY == panel.frame.minY + 26, "under the pill")
        #expect(card.height == MatchCard.heightBelowPill(rows: session.matchCardVisibleRows, partRowHeight: session.matchCardPartRowHeight))
    }

    /// A centered panel at the bottom moves up once with a slide's motion, keeps its place while
    /// matches come and go, and goes back to where the owner left it when the field is cleared.
    /// The place kept is never the moved one.
    @Test func atTheBottomItMovesUpOnceAndGoesBackWhenTheFieldIsCleared() throws {
        let start = CGRect(x: 300, y: laptop.minY, width: 640, height: 560)
        let (panel, session, defaults) = try makePanel(frame: start)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let name = "mac-os-agent-match-card-test-\(UUID().uuidString)"
        #expect(panel.setFrameAutosaveName(name))
        defer {
            panel.setFrameAutosaveName("")
            UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(name)")
        }
        let saved = UserDefaults.standard.string(forKey: "NSWindow Frame \(name)")
        let raised = start.offsetBy(dx: 0, dy: SummonPanel.footerGrowthMargin + MatchCard.roomMade)
        session.draft = "chr"
        panel.updateFooterGrowth()
        #expect(panel.matchCardMotion?.end == raised, "on its way up")
        #expect(session.matchCardVisibleRows == 2, "the card is its final size on the way")
        #expect(panel.frameAutosaveName.isEmpty, "the autosave is set aside")
        panel.advanceMatchCardMotion(by: MatchListRoom.Motion.duration / 3)
        #expect(panel.frame.minY > start.minY)
        #expect(panel.frame.minY < raised.minY)
        panel.advanceMatchCardMotion(by: 1)
        #expect(panel.matchCardMotion == nil)
        #expect(panel.frame == raised)
        #expect(UserDefaults.standard.string(forKey: "NSWindow Frame \(name)") == saved, "the moved frame is never kept")
        // No match, then a match again: the panel stays up the whole time.
        session.draft = "chrzzz"
        panel.updateFooterGrowth()
        #expect(!session.showsMatchCard)
        #expect(panel.matchCardMotion == nil)
        #expect(panel.frame == raised, "it does not go back while the owner types")
        session.draft = "chr"
        panel.updateFooterGrowth()
        #expect(panel.matchCardMotion == nil)
        #expect(panel.frame == raised)
        // Cleared: it goes back.
        session.draft = ""
        panel.updateFooterGrowth()
        #expect(panel.matchCardMotion?.end == start)
        panel.advanceMatchCardMotion(by: 1)
        #expect(panel.frame == start)
        #expect(panel.frameAutosaveName == name, "the autosave is back")
        let kept = try #require(UserDefaults.standard.string(forKey: "NSWindow Frame \(name)"))
        #expect(kept.hasPrefix("\(Int(start.minX)) \(Int(start.minY)) "), "the place kept is where the owner left it")
    }

    /// Hiding puts it back at once, before it goes, and Reduce Motion moves it at once both ways.
    @Test func hidingPutsItBackAtOnceAndReduceMotionNeverAnimates() throws {
        let start = CGRect(x: 300, y: laptop.minY, width: 640, height: 560)
        let (panel, session, defaults) = try makePanel(frame: start)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        session.draft = "chr"
        panel.updateFooterGrowth()
        panel.advanceMatchCardMotion(by: 1)
        #expect(panel.frame.minY > start.minY)
        panel.dismiss()
        #expect(panel.matchCardMotion == nil)
        #expect(panel.frame == start, "back before it hides")
        panel.reduceMotion = { true }
        panel.summon()
        session.draft = "chr"
        panel.updateFooterGrowth()
        #expect(panel.matchCardMotion == nil, "no motion with Reduce Motion")
        #expect(panel.frame.minY == start.minY + SummonPanel.footerGrowthMargin + MatchCard.roomMade)
        session.draft = ""
        panel.updateFooterGrowth()
        #expect(panel.matchCardMotion == nil)
        #expect(panel.frame == start)
    }

    /// A drag while it is moved makes where the owner drops it the panel's place: the move is
    /// dropped, and the panel does not move for the card again until the field is empty.
    @Test func aDragWhileMovedKeepsWhereTheOwnerLeftIt() throws {
        let start = CGRect(x: 300, y: laptop.minY, width: 640, height: 560)
        let (panel, session, defaults) = try makePanel(frame: start)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        session.draft = "chr"
        panel.updateFooterGrowth()
        panel.advanceMatchCardMotion(by: 1)
        let dropped = CGRect(x: 200, y: laptop.minY + 20, width: 640, height: 560)
        panel.setFrame(dropped, display: false)
        #expect(panel.frame == dropped)
        session.draft = "chro"
        panel.updateFooterGrowth()
        #expect(panel.matchCardMotion == nil, "it does not move up again under the owner")
        #expect(panel.frame == dropped)
        #expect(session.showsMatchCard, "the card is shortened to the room instead, downward")
        #expect(session.matchCardVisibleRows == 1)
        session.draft = ""
        panel.updateFooterGrowth()
        #expect(panel.matchCardMotion == nil)
        #expect(panel.frame == dropped, "it stays where the owner left it")
        session.draft = "chr"
        panel.updateFooterGrowth()
        panel.advanceMatchCardMotion(by: 1)
        #expect(panel.frame.minY == laptop.minY + SummonPanel.footerGrowthMargin + MatchCard.roomMade, "a new draft moves it again")
    }

    /// Slide over is the screen's full height, so its bottom edge rises instead, and its top and
    /// edge stay. It still reads as being in slide over, and goes back to the full height.
    @Test func inSlideOverTheBottomEdgeRises() throws {
        let (panel, session, defaults) = try makePanel()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        panel.choose(.slideOverRight)
        #expect(panel.slide != nil, "it slides in from its edge")
        session.draft = "chr"
        panel.updateFooterGrowth()
        #expect(panel.matchCardMotion == nil, "nothing moves for the card while it slides")
        panel.advanceSlide(by: 1)
        let full = panel.panelFrame
        #expect(full.minY == laptop.minY)
        #expect(full.maxY == laptop.maxY)
        #expect(panel.matchCardMotion != nil, "once in place, its bottom edge rises")
        panel.advanceMatchCardMotion(by: 1)
        let rise = SummonPanel.footerGrowthMargin + MatchCard.roomMade
        #expect(panel.frame == CGRect(x: full.minX, y: full.minY + rise, width: full.width, height: full.height - rise))
        #expect(panel.panelFrame == full, "its place is still the full height")
        #expect(panel.placement.preset == .slideOverRight)
        #expect(session.suggestionList.roomBelow == MatchCard.roomMade)
        #expect(session.matchCardVisibleRows == 2)
        #expect(session.matchCardPartRowHeight == MatchCard.partRowHeight)
        // The owner widens it from its free edge: still slide over, still raised.
        let wider = CGRect(x: full.minX - 60, y: panel.frame.minY, width: full.width + 60, height: panel.frame.height)
        panel.setFrame(wider, display: false)
        #expect(panel.placement.preset == .slideOverRight)
        #expect(panel.frame.minY == full.minY + rise)
        session.draft = ""
        panel.updateFooterGrowth()
        panel.advanceMatchCardMotion(by: 1)
        #expect(panel.frame == CGRect(x: wider.minX, y: full.minY, width: wider.width, height: full.height), "the full height, at the new width")
        #expect(panel.placement.preset == .slideOverRight)
    }

    /// In the shortened card, the arrows scroll the list so the highlighted row is always whole,
    /// down to the Ask row and back up, with part of the next row showing past it.
    @Test func theShortenedCardKeepsTheHighlightWhole() throws {
        let room = SummonPanel.footerGrowthMargin + MatchCard.reachBelowPanel(rows: 2, partRowHeight: MatchCard.partRowHeight)
        let (panel, session, defaults) = try makePanel(frame: CGRect(x: 300, y: laptop.minY + room, width: 640, height: 500))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        session.draft = "chr"
        panel.updateFooterGrowth()
        #expect(session.showsMatchCard)
        #expect(panel.frame.minY == laptop.minY + room, "with room for the minimum, the panel stays")
        #expect(session.matchCardVisibleRows == 2)
        #expect(session.matchCardPartRowHeight == MatchCard.partRowHeight)
        let count = session.matchCardRows.count
        #expect(count > 3, "more rows than show")
        let viewport = 2 * MatchCard.rowHeight + MatchCard.partRowHeight
        var offset: CGFloat = 0
        func check(_ label: String) {
            let index = session.highlightedRowIndex
            offset = MatchListScroll.offset(
                showing: index, from: offset, rowCount: count, rowHeight: MatchCard.rowHeight, viewport: viewport,
                margin: session.matchCardPartRowHeight)
            #expect(MatchListScroll.isWhole(index, offset: offset, rowHeight: MatchCard.rowHeight, viewport: viewport), "\(label) row \(index)")
            if index < count - 1 {
                #expect(offset + viewport > CGFloat(index + 1) * MatchCard.rowHeight, "part of the row after \(index) shows")
            }
        }
        for _ in 0..<count {
            check("down")
            _ = session.chooseInFooter(by: 1)
        }
        #expect(session.highlightedRow == .ask("chr"), "the Ask row last")
        #expect(offset == CGFloat(count) * MatchCard.rowHeight - viewport, "scrolled to the end")
        for _ in 0..<count {
            check("up")
            _ = session.chooseInFooter(by: -1)
        }
        #expect(session.highlightedRowIndex == 0)
        #expect(offset == 0, "back at the top")
    }

    /// Many slash commands never make the card taller than its limit: the list is shortened, ends
    /// in a part row, and scrolls, even with room for all of it.
    @Test func aListLongerThanTheLimitIsShortened() throws {
        let (panel, session, defaults) = try makePanel()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        session.skillCommands = SkillCommandsModel(menu: SlashCommandMenu(skills: (1...12).map {
            SkillCommand(name: "skill-\($0)", description: "A stand-in skill.", folderName: "skill-\($0)")
        }))
        session.draft = "/"
        panel.updateFooterGrowth()
        #expect(session.matchCardRows.count > MatchCard.visibleLimit)
        #expect(session.showsMatchCard)
        #expect(session.matchCardVisibleRows == MatchCard.visibleLimit - 1)
        #expect(session.matchCardPartRowHeight == MatchCard.partRowHeight)
    }

    @Test func aHiddenPanelLeavesNoRoomAndNoCard() throws {
        let (panel, session, defaults) = try makePanel()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        session.draft = "chr"
        panel.dismiss()
        #expect(session.suggestionList.roomBelow == 0)
        #expect(!session.suggestionList.isOpen)
    }
}
