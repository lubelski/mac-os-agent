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

/// The match card's measures, which way it opens, and its keys. See `MatchCard`.
@MainActor
@Suite struct MatchCardGeometryTests {
    @Test func itOpensDownwardShortenedToTheRoomAndNeverBelowTwoRowsAndAPart() {
        let rows = 4
        let part = MatchCard.partRowHeight
        #expect(part == 17, "0.4 of a 44 point row")
        let reach = MatchCard.reachBelowPanel(rows: rows)
        // The card covers the status line first, then reaches past the panel's edge.
        #expect(reach == MatchCard.heightBelowPill(rows: rows) - InputFooter.height)
        #expect(MatchCard.heightBelowPill(rows: rows) == 4 * 44 + 1 + InputFooter.height)
        #expect(MatchCard.heightBelowPill(rows: 2, partRowHeight: part) == 2 * 44 + 17 + 1 + InputFooter.height)
        #expect(reach == MatchCard.rowHeight * 4 + MatchCard.reachBeyondRows)
        #expect(MatchCard.fit(rows: rows, roomBelow: reach) == .below(rows: 4, partRowHeight: 0))
        #expect(MatchCard.fit(rows: rows, roomBelow: reach - 1) == .below(rows: 3, partRowHeight: part), "shortened, and it scrolls")
        let fewest = MatchCard.reachBelowPanel(rows: 2, partRowHeight: part)
        #expect(MatchCard.fit(rows: 7, roomBelow: fewest) == .below(rows: 2, partRowHeight: part))
        #expect(MatchCard.fit(rows: 7, roomBelow: MatchCard.reachBelowPanel(rows: 3, partRowHeight: part)) == .below(rows: 3, partRowHeight: part))
        #expect(MatchCard.fit(rows: 7, roomBelow: fewest - 1) == .above, "less than two and a part")
        #expect(MatchCard.fit(rows: 7, roomBelow: MatchCard.reachBelowPanel(rows: 2)) == .above, "two whole rows are not enough")
        #expect(MatchCard.fit(rows: 0, roomBelow: 1000) == nil, "no rows, no card")
    }

    @Test func theRoomBelowIsNoneInSlideOverAndLessAMargin() {
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 949)
        let panel = CGRect(x: 300, y: 200, width: 640, height: 560)
        #expect(MatchCard.roomBelow(panel: panel, visible: visible, slideOver: false) == 200 - SummonPanel.footerGrowthMargin)
        #expect(MatchCard.roomBelow(panel: panel, visible: visible, slideOver: true) == 0)
        #expect(MatchCard.roomBelow(panel: panel.offsetBy(dx: 0, dy: -200), visible: visible, slideOver: false) == 0)
    }

    @Test func openingUpwardShowsAsManyRowsAsFit() {
        #expect(MatchCard.rowsAbove(7, roomAbove: .greatestFiniteMagnitude) == 7)
        #expect(MatchCard.rowsAbove(7, roomAbove: 44 * 3 + 1) == 3)
        #expect(MatchCard.rowsAbove(7, roomAbove: 10) == 1, "at least one")
        #expect(MatchCard.rowsAbove(0, roomAbove: 500) == 0)
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
        #expect(session.matchCardSide == nil)
    }

    @Test func withTheSwitchOffTheListStillWaitsForDown() async throws {
        let (harness, _) = try harness(bars: false)
        harness.type("chr")
        await harness.settle()
        #expect(!harness.session.suggestionList.isOpen)
        #expect(harness.session.matchCardRows.isEmpty)
        #expect(harness.session.matchCardSide == nil)
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
        #expect(harness.session.matchCardSide != nil)
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
        #expect(session.matchCardSide == .below)
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

    /// Slide over is the screen's full height, so there is no room below for two rows.
    @Test func inSlideOverItOpensUpward() throws {
        let (panel, session, defaults) = try makePanel()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        panel.choose(.slideOverRight)
        let before = panel.frame
        session.draft = "chr"
        panel.updateFooterGrowth()
        #expect(session.suggestionList.roomBelow == 0)
        #expect(session.matchCardSide == .above)
        #expect(panel.matchCardFrame == nil)
        #expect(panel.frame == before)
    }

    /// Near the bottom of the screen the card still opens downward, shortened to the rows that
    /// fit, and opens upward only with room for fewer than two.
    @Test(arguments: [CGFloat(4), 60, 100, 150, 250, 400])
    func nearTheBottomOfTheScreenItIsShortened(_ room: CGFloat) throws {
        let (panel, session, defaults) = try makePanel(frame: CGRect(x: 300, y: laptop.minY + room, width: 640, height: 500))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        session.draft = "chr"
        panel.updateFooterGrowth()
        let rows = min(session.matchCardRows.count, MatchCard.visibleLimit)
        #expect(rows > 2, "the stand-in apps match more than fit in some of these rooms")
        let available = room - SummonPanel.footerGrowthMargin
        let fits = Int(((available - MatchCard.reachBeyondRows) / MatchCard.rowHeight).rounded(.down))
        let wholeBesidesPart = Int(((available - MatchCard.reachBeyondRows - MatchCard.partRowHeight) / MatchCard.rowHeight).rounded(.down))
        if fits >= rows {
            #expect(session.matchCardSide == .below)
            #expect(session.matchCardVisibleRows == rows)
            #expect(session.matchCardPartRowHeight == 0)
        } else if wholeBesidesPart >= 2 {
            #expect(session.matchCardSide == .below)
            #expect(session.matchCardVisibleRows == wholeBesidesPart)
            #expect(session.matchCardPartRowHeight == MatchCard.partRowHeight, "ends in a part row")
        } else {
            #expect(session.matchCardSide == .above)
            #expect(panel.matchCardFrame == nil)
        }
        if session.matchCardSide == .below {
            session.suggestionList.pillFrame = CGRect(x: 8, y: 500 - 26 - 38, width: 624, height: 38)
            let card = try #require(panel.matchCardFrame)
            #expect(card.minY >= laptop.minY + SummonPanel.footerGrowthMargin, "it ends inside the screen")
            #expect(card.height == MatchCard.heightBelowPill(rows: session.matchCardVisibleRows, partRowHeight: session.matchCardPartRowHeight))
        }
        #expect(panel.panelFrame.minY == laptop.minY + room, "the panel never moves")
    }

    /// In the shortened card, the arrows scroll the list so the highlighted row is always whole,
    /// down to the Ask row and back up, with part of the next row showing past it.
    @Test func theShortenedCardKeepsTheHighlightWhole() throws {
        let room = SummonPanel.footerGrowthMargin + MatchCard.reachBelowPanel(rows: 2, partRowHeight: MatchCard.partRowHeight)
        let (panel, session, defaults) = try makePanel(frame: CGRect(x: 300, y: laptop.minY + room, width: 640, height: 500))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        session.draft = "chr"
        panel.updateFooterGrowth()
        #expect(session.matchCardSide == .below)
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
        #expect(session.matchCardSide == .below)
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
