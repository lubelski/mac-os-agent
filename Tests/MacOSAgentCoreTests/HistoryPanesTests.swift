import Foundation
import Testing
@testable import MacOSAgentCore

/// Settings, History, as a pane stack: what each depth of a path shows, the rows a swap
/// follows, and what a search result opens.
@Suite struct HistoryPanesTests {
    /// Three episodes: messages and a command; a hosted search, a quick action with two steps,
    /// and an app opened; and apps opened only.
    private func panes() -> HistoryPanes {
        let contents = ThreadContents(entries: HistoryHasWhateverHappenedTests.everyKind())
        return HistoryPanes(contents: contents, items: EpisodeListItem.all(in: contents))
    }

    private var stepIDs: [String] {
        let runID = HistoryHasWhateverHappenedTests.runID
        return [QuickActionRunStart.callID(entryID: runID, index: 0), QuickActionRunStart.callID(entryID: runID, index: 1)]
    }

    @Test func eachDepthOfThePathIsTheEpisodesAnEpisodeOrACommand() throws {
        let panes = panes()
        let first = try #require(panes.contents.episode(numbered: 1))
        let path = PaneStackPath(["1", "call_1"])
        #expect(panes.pane(at: 0, of: path) == .episodes)
        #expect(panes.pane(at: 1, of: path) == .episode(first))
        guard case .command(let line, let call, let episode) = panes.pane(at: 2, of: path) else {
            Issue.record("depth 2 is not a command")
            return
        }
        #expect(episode == first)
        #expect(line.callID == "call_1")
        #expect(line.text == "Bash du -sh ~/Movies")
        // The command's pane has what the inspector shows: its input and its output.
        #expect(call?.command == "du -sh ~/Movies")
        #expect(call?.output == "38G\t/Users/someone/Movies\n[exit status 0]")
        #expect(call?.status == .succeeded)
        #expect(panes.pane(at: 3, of: path) == nil)

        #expect(panes.pane(at: 0, of: path)?.title == "all episodes")
        #expect(panes.pane(at: 1, of: path)?.title == "Episode 1")
        #expect(panes.pane(at: 2, of: path)?.title == "Bash du -sh ~/Movies")
    }

    @Test func aHostedSearchAndAQuickActionsStepsOpenAsCommands() throws {
        let panes = panes()
        guard case .command(_, let search, _) = panes.pane(at: 2, of: PaneStackPath(["2", "ws_1"])) else {
            Issue.record("the hosted search does not open")
            return
        }
        #expect(search?.name == "web_search")
        guard case .command(let step, let call, _) = panes.pane(at: 2, of: PaneStackPath(["2", stepIDs[1]])) else {
            Issue.record("the quick action's step does not open")
            return
        }
        #expect(step.kind == .command(.failed))
        #expect(call?.output == "Error: no shortcut named focus.\n[exit status 1]")
    }

    @Test func eachPaneListsItsRowsInTheOrderItShowsThem() throws {
        let panes = panes()
        // Newest first, as the list shows them.
        #expect(panes.rows(of: PaneStackPath()) == ["3", "2", "1"])
        // The search, then the quick action's steps under its line.
        #expect(panes.rows(of: PaneStackPath(["2"])) == ["ws_1"] + stepIDs)
        #expect(panes.rows(of: PaneStackPath(["3"])) == [])
        #expect(panes.rows(of: PaneStackPath(["1", "call_1"])) == [])

        // Picking an older episode while one is open swaps it, rising from below.
        let change = PaneStackChange(from: PaneStackPath(["3"]), to: PaneStackPath(["2"]), rows: panes.rows)
        #expect(change == .swap(depth: 1, direction: .fromBelow))
        // So does another episode picked from the strip while a command is open.
        let fromCommand = PaneStackChange(from: PaneStackPath(["1", "call_1"]), to: PaneStackPath(["2"]), rows: panes.rows)
        #expect(fromCommand == .swap(depth: 1, direction: .fromAbove))
        let steps = PaneStackChange(from: PaneStackPath(["2", "ws_1"]), to: PaneStackPath(["2", stepIDs[0]]), rows: panes.rows)
        #expect(steps == .swap(depth: 2, direction: .fromBelow))
    }

    @Test func aPathThatNamesWhatIsNotThereFallsBackToWhatIs() {
        let panes = panes()
        #expect(panes.validPrefix(of: PaneStackPath(["9", "call_1"])) == PaneStackPath())
        #expect(panes.validPrefix(of: PaneStackPath(["one"])) == PaneStackPath())
        // A command opens only from the episode it ran in.
        #expect(panes.validPrefix(of: PaneStackPath(["2", "call_1"])) == PaneStackPath(["2"]))
        #expect(panes.validPrefix(of: PaneStackPath(["1", "call_1", "more"])) == PaneStackPath(["1", "call_1"]))
    }

    @Test func anItemOpensItsEpisodeOrCommand() {
        let panes = panes()
        #expect(panes.path(showing: "2") == PaneStackPath(["2"]))
        #expect(panes.path(showing: "call_1") == PaneStackPath(["1", "call_1"]))
        #expect(panes.path(showing: stepIDs[0]) == PaneStackPath(["2", stepIDs[0]]))
        #expect(panes.path(showing: "9") == nil)
        #expect(panes.path(showing: "nothing") == nil)
    }

    @Test func anOpenEpisodeStaysOpenWhenASearchNoLongerListsIt() {
        let contents = ThreadContents(entries: HistoryHasWhateverHappenedTests.everyKind())
        let panes = HistoryPanes(contents: contents, items: [])
        #expect(panes.validPrefix(of: PaneStackPath(["1", "call_1"])) == PaneStackPath(["1", "call_1"]))
        #expect(panes.rows(of: PaneStackPath()) == [])
    }

    @Test func aSearchResultOpensItsEpisodeAtTheLineThatMatched() async throws {
        let store = try ThreadStore(fileURL: try writeLegacyThread())
        let contents = await store.contents
        let found = EpisodeListItem.matching(await store.search("Downloads", limit: 50))
        let panes = HistoryPanes(contents: contents, items: found)
        #expect(panes.rows(of: PaneStackPath()) == ["1"])
        let episode = try #require(panes.episode("1"))
        let matched = try #require(panes.matchedLineID(in: episode))
        // The line that matched is one the episode's pane shows, so it can be marked and
        // scrolled to.
        let line = try #require(panes.lines(of: episode).first { $0.id == matched })
        #expect(line.text == found[0].match)
        // Without a search nothing is marked.
        #expect(HistoryPanes(contents: contents, items: EpisodeListItem.all(in: contents)).matchedLineID(in: episode) == nil)
    }

    @Test func anEpisodeNewerThanTheContentsReadsOnlyWhatTheyHold() throws {
        // A search can find an episode that grew after the contents were read.
        let entries = HistoryHasWhateverHappenedTests.everyKind()
        let full = ThreadContents(entries: entries)
        let older = ThreadContents(entries: entries.prefix(3))
        let first = try #require(full.episode(numbered: 1))
        #expect(EpisodeLine.lines(of: first, in: older).map(\.kind) == [.owner, .command(.succeeded)])
        let later = try #require(full.episode(numbered: 2))
        #expect(EpisodeLine.lines(of: later, in: older).isEmpty)
    }
}
