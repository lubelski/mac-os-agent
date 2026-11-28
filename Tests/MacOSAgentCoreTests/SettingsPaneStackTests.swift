import Foundation
import Testing
@testable import MacOSAgentCore

/// Settings as one pane stack: the section list at depth 0, the section at depth 1, and the
/// section's own levels above it.
@Suite struct SettingsPaneStackTests {
    private let kept: [String: PaneStackPath] = [
        "tools": PaneStackPath(["system", "find_files"]),
        "history": PaneStackPath(["6"]),
    ]

    private func keptPath(_ section: String) -> PaneStackPath { kept[section] ?? PaneStackPath() }

    @Test func aSectionsLevelsContinueTheWindowsPath() {
        let path = SettingsPaneStack.path(section: "tools", within: PaneStackPath(["system", "find_files"]))
        #expect(path.entries == ["tools", "system", "find_files"])
        #expect(path.depth == 3)
        #expect(SettingsPaneStack.section(of: path) == "tools")
        #expect(SettingsPaneStack.sectionPath(of: path).entries == ["system", "find_files"])
        // The section counts its own first level as depth 0, as it did on its own.
        #expect(SettingsPaneStack.depthInSection(1) == 0)
        #expect(SettingsPaneStack.depthInSection(3) == 2)
        #expect(SettingsPaneStack.depthInSection(0) == -1)

        let general = SettingsPaneStack.path(section: "general")
        #expect(general.entries == ["general"])
        #expect(SettingsPaneStack.sectionPath(of: general).isAtBase)
        #expect(SettingsPaneStack.section(of: PaneStackPath()) == nil)
    }

    @Test func pickingAnotherSectionIsASwapThatBringsBackWhereItWasLeft() {
        let current = PaneStackPath(["general"])
        // The list's row opens the section from depth 0, as any row opens its item.
        var requested = current
        requested.open("tools", from: 0)
        let path = SettingsPaneStack.resolve(requested, from: current, kept: keptPath)
        #expect(path.entries == ["tools", "system", "find_files"])
        // A swap at depth 1 by the list's order, not an open, so the section's card stays.
        let order = ["general", "appearance", "tools", "history"]
        let change = PaneStackChange(from: current, to: path) { $0.isAtBase ? order : [] }
        #expect(change == .swap(depth: 1, direction: .fromBelow))
    }

    @Test func pickingAnotherSectionClosesTheLevelsOfTheOneLeft() {
        let current = PaneStackPath(["tools", "system", "find_files"])
        var requested = current
        requested.clickStrip(at: 0, on: "general")
        let path = SettingsPaneStack.resolve(requested, from: current, kept: keptPath)
        #expect(path.entries == ["general"])
        let order = ["general", "appearance", "tools", "history"]
        #expect(PaneStackChange(from: current, to: path) { $0.isAtBase ? order : [] } == .swap(depth: 1, direction: .fromAbove))
    }

    @Test func theSectionListNeverShowsAlone() {
        // A click on the list's strip away from any row, or on the chosen section's own row,
        // goes back to that pane in a stack of its own. Here it stops at the section's first level.
        let current = PaneStackPath(["tools", "system", "find_files"])
        var away = current
        away.clickStrip(at: 0, on: nil)
        #expect(away.isAtBase)
        #expect(SettingsPaneStack.resolve(away, from: current, kept: keptPath).entries == ["tools"])

        var ownRow = current
        ownRow.clickStrip(at: 0, on: "tools")
        #expect(SettingsPaneStack.resolve(ownRow, from: current, kept: keptPath).entries == ["tools"])

        // At a section's first level, it stays where it is.
        let first = PaneStackPath(["general"])
        var back = first
        back.goBack()
        #expect(SettingsPaneStack.resolve(back, from: first, kept: keptPath) == first)
    }

    @Test func changesInsideASectionAreAsAsked() {
        let current = PaneStackPath(["tools", "system", "find_files"])
        var requested = current
        requested.clickStrip(at: 1, on: "calendar")
        #expect(SettingsPaneStack.resolve(requested, from: current, kept: keptPath).entries == ["tools", "calendar"])

        // Going back to the section's own first level is not the list, so it is allowed.
        requested = current
        requested.clickStrip(at: 1, on: nil)
        #expect(SettingsPaneStack.resolve(requested, from: current, kept: keptPath).entries == ["tools"])

        requested = current
        requested.open("read_clipboard", from: 2)
        #expect(SettingsPaneStack.resolve(requested, from: current, kept: keptPath).entries == ["tools", "system", "read_clipboard"])
    }

    @Test func escapeClosesOnePaneAboveASectionsFirstLevelAndNoMore() {
        #expect(SettingsPaneStack.escape(from: PaneStackPath(["history", "6", "call_5"]))?.entries == ["history", "6"])
        #expect(SettingsPaneStack.escape(from: PaneStackPath(["history", "6"]))?.entries == ["history"])
        // At the section's first level Escape is not the stack's, so it does what it did before.
        #expect(SettingsPaneStack.escape(from: PaneStackPath(["history"])) == nil)
        #expect(SettingsPaneStack.escape(from: PaneStackPath(["general"])) == nil)
        #expect(SettingsPaneStack.escape(from: PaneStackPath()) == nil)
    }

    @Test func theLayoutCoversTheSectionListMoreAsTheWindowNarrows() {
        // The section list asks for 200, as the sidebar was. General is one pane over it.
        #expect(PaneStackLayout.stripWidths(preferred: [200], available: 900) == [200])
        #expect(PaneStackLayout.stripWidths(preferred: [200], available: 620) == [200])
        #expect(PaneStackLayout.stripWidths(preferred: [200], available: 440) == [120])
        // Tools three deep: the list, the groups narrowed to their icons, and the tools.
        #expect(PaneStackLayout.stripWidths(preferred: [200, 56, 170], available: 900) == [200, 56, 170])
        #expect(PaneStackLayout.stripWidths(preferred: [200, 56, 170], available: 620) == [24, 56, 170])
        #expect(PaneStackLayout.stripWidths(preferred: [200, 56, 170], available: 440) == [0, 0, 120])
        // History two deep: the list and the episodes.
        #expect(PaneStackLayout.stripWidths(preferred: [200, 200], available: 900) == [200, 200])
        #expect(PaneStackLayout.stripWidths(preferred: [200, 200], available: 620) == [24, 200])
        #expect(PaneStackLayout.stripWidths(preferred: [200, 200], available: 440) == [0, 120])
    }
}
