import AppKit
import MacOSAgentCore
import SwiftUI
import Testing
@testable import mac_os_agent

/// Settings as one stack of panes, with its experiment on: the window's path, the section
/// models it is kept in step with, Escape, and the title bar. Checked on the window's model
/// and key handling, since screen capture is not available.
@MainActor
@Suite(.serialized) struct SettingsOneStackAppTests {
    private func harness(_ section: SettingsSection = .tools, on: Bool = true) throws -> SettingsWindowHarness {
        try SettingsWindowHarness(
            section: section, additionalTools: ToolsSettingsStandIns.mcpTools, privacyAccess: ToolsSettingsStandIns.Access(),
            experiments: on ? [.settingsAsOneStackOfPanes] : [])
    }

    private func escape() throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    }

    @Test func offTheSectionListIsTheFixedSidebarAndTheWindowsStackIsUnused() throws {
        let harness = try harness(on: false)
        defer { harness.tearDown() }
        let models = harness.controller.models
        harness.layOut()
        models.tools.showInStack("find_files")
        harness.layOut()
        #expect(models.navigation.stack.path.entries == ["tools"])
        #expect(models.tools.stack.path.entries == ["system", "find_files"])
    }

    @Test func itOpensOnTheLastSectionWhereItWasLeft() throws {
        let harness = try harness()
        defer { harness.tearDown() }
        let models = harness.controller.models
        models.tools.showInStack("find_files")
        harness.layOut()
        #expect(models.navigation.stack.path.entries == ["tools", "system", "find_files"])
        #expect(harness.controller.titleBar.title == "Tools")
    }

    @Test func escapeClosesOnePaneAndAtASectionsFirstLevelIsNotTaken() throws {
        let harness = try harness()
        defer { harness.tearDown() }
        let models = harness.controller.models
        let stack = models.navigation.stack
        harness.layOut()
        // At the section's first level Escape is not the stack's, as with Tools on its own.
        #expect(!harness.window.performKeyEquivalent(with: try escape()))
        #expect(stack.path.entries == ["tools"])

        models.tools.showInStack("weather__add_alert")
        harness.layOut()
        #expect(stack.path.entries == ["tools", "mcp:weather", "weather__add_alert"])
        #expect(harness.window.performKeyEquivalent(with: try escape()))
        harness.layOut()
        #expect(stack.path.entries == ["tools", "mcp:weather"])
        #expect(models.tools.stack.path.entries == ["mcp:weather"], "the section keeps its place")
        #expect(harness.window.performKeyEquivalent(with: try escape()))
        harness.layOut()
        #expect(stack.path.entries == ["tools"], "never the section list alone")
        #expect(!harness.window.performKeyEquivalent(with: try escape()))
        #expect(stack.path.entries == ["tools"])
        #expect(models.navigation.section == .tools)
    }

    @Test func leavingASectionAndComingBackFindsItAsItWas() throws {
        let harness = try harness()
        defer { harness.tearDown() }
        let models = harness.controller.models
        let stack = models.navigation.stack
        models.tools.showInStack("find_files")
        harness.layOut()
        stack.scrollOffsets["3|tools/system/find_files"] = 180

        // As the menu's Settings item or a section turned off would choose it.
        models.navigation.section = .general
        harness.layOut()
        #expect(stack.path.entries == ["general"])
        #expect(harness.controller.titleBar.title == "General")
        #expect(models.tools.stack.path.entries == ["system", "find_files"], "Tools keeps its place")

        models.navigation.section = .tools
        harness.layOut()
        #expect(stack.path.entries == ["tools", "system", "find_files"])
        // Kept by the pane's path, which starts with the section, so no other section's pane
        // shares it. The pane writes its own place back as it lays out, as in Tools alone.
        #expect(stack.scrollOffsets["3|tools/system/find_files"] != nil)
    }

    @Test func aChangeTheStackMakesIsWrittenToTheSectionsModels() throws {
        let harness = try harness(.general)
        defer { harness.tearDown() }
        let models = harness.controller.models
        harness.layOut()
        #expect(models.navigation.stack.path.entries == ["general"])
        // As a swap from the section list would leave it, with Tools' levels after it.
        models.navigation.stack.path = PaneStackPath(["tools", "calendar"])
        harness.layOut()
        #expect(models.navigation.section == .tools)
        #expect(models.tools.stack.path.entries == ["calendar"])
        #expect(harness.controller.titleBar.title == "Tools")
    }

    @Test func aPathToSomethingGoneFallsBackToTheSection() throws {
        let harness = try harness()
        defer { harness.tearDown() }
        let models = harness.controller.models
        models.tools.stack.path = PaneStackPath(["mcp:gone", "gone__tool"])
        harness.layOut()
        #expect(models.navigation.stack.path.entries == ["tools"])
        #expect(models.tools.stack.path.isAtBase)
    }

    @Test func turningTheSwitchOnWhileTheWindowIsOpenTakesEffectNow() throws {
        let harness = try harness(on: false)
        defer { harness.tearDown() }
        let models = harness.controller.models
        models.tools.showInStack("find_files")
        harness.layOut()
        #expect(models.navigation.stack.path.entries == ["tools"])
        Experiment.settingsAsOneStackOfPanes.set(true, try #require(UserDefaults(suiteName: harness.suiteName)))
        harness.layOut()
        #expect(models.navigation.stack.path.entries == ["tools", "system", "find_files"])
    }

    /// A click on the covered list finds its section by where each row says it is. The rows sit
    /// in a sidebar `List`, so this checks that each one reports its place out of the list, and
    /// that the place covers the row's width and height, not only its label.
    @Test func eachSectionInTheListSaysWhereItsRowIs() throws {
        let suite = "mac-os-agent-one-stack-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = SettingsNavigation(defaults: defaults)
        let found = FoundRows()
        let view = SettingsSectionListPane(navigation: navigation)
            .overlayPreferenceValue(PaneItemAnchors.self) { anchors in
                GeometryReader { proxy in
                    let _ = found.rects = anchors.mapValues { proxy[$0] }
                    Color.clear
                }
            }
            .frame(width: 600, height: 620)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 620), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: view)
        for _ in 0..<3 {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        #expect(Set(found.rects.keys) == Set(navigation.sections.map(\.rawValue)))
        let rects = navigation.sections.compactMap { found.rects[$0.rawValue] }
        #expect(rects.allSatisfy { $0.height >= 31 && $0.width >= 150 && $0.maxX <= SettingsRootView.sidebarWidth })
        // Each row's place meets the next one's, so a click between two labels still finds one.
        for (upper, lower) in zip(rects, rects.dropFirst()) {
            #expect(lower.minY <= upper.maxY)
        }
    }

    @Test func aPreviewThatAsksForOneStackShowsItWithoutThePreference() throws {
        let suite = "mac-os-agent-one-stack-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = SettingsNavigation(defaults: defaults, oneStackOverride: true)
        #expect(navigation.oneStackOverride == true)
        #expect(navigation.stack.path.entries == ["general"], "something is chosen from the start")
        #expect(defaults.object(forKey: Experiment.settingsAsOneStackOfPanes.key) == nil, "nothing is written")
    }
}

/// Where each row of a pane said it was, read out of a layout.
@MainActor
private final class FoundRows {
    var rects: [String: CGRect] = [:]
}
