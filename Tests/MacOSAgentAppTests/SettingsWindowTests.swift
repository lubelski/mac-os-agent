import AppKit
import MacOSAgentCore
import SwiftUI
import Testing
@testable import mac_os_agent

/// A Settings window on stand-in data in a temporary folder, with a defaults suite of its own.
/// It never goes on screen and never reads the real data folder.
@MainActor
struct SettingsWindowHarness {
    let folder = FileManager.default.temporaryDirectory
        .appending(path: "mac-os-agent-settings-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let suiteName = "mac-os-agent-settings-tests-\(UUID().uuidString)"
    let controller: SettingsWindowController

    init(section: SettingsSection) throws {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, description) in [
            ("archive-downloads", "Move files older than a month from Downloads into a dated archive folder."),
            ("battery-report", "Summarize battery health, cycle count, and the apps using the most energy."),
            ("clean-desktop", "Sort the files on the desktop into folders by kind."),
        ] {
            let skill = folder.appending(path: "skills/\(name)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
            try "---\nname: \(name)\ndescription: \(description)\n---\n\nSteps for this skill.\n"
                .write(to: skill.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        }
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(section.rawValue, forKey: SettingsNavigation.key)
        let prompt = AgentPrompt(
            instructions: InstructionsStore(fileURL: folder.appending(path: "instructions.md")),
            skills: SkillLibrary(folder: folder.appending(path: "skills"), settingsFile: folder.appending(path: "skill-settings.json")),
            memories: MemoryLibrary(folder: folder.appending(path: "memory", directoryHint: .isDirectory)))
        let history = try ThreadStore(fileURL: folder.appending(path: "thread.jsonl"))
        let summonTrigger = SummonTriggerController(registrar: StandInHotKey(), defaults: defaults, systemShortcuts: { [] })
        controller = SettingsWindowController(
            session: AgentSession(previewEntries: []), prompt: prompt,
            usageLog: UsageLog(fileURL: folder.appending(path: "usage.jsonl")),
            tools: ToolRegistry(builtIn: BuiltInTools.make(skills: prompt.skills, history: history)),
            history: history, problems: ProblemLog(), signInStatus: { nil },
            summonTrigger: summonTrigger, defaults: defaults, remembersFrame: false)
    }

    var window: NSWindow { controller.window! }

    /// Lays the window out without putting it on screen.
    func layOut() {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func tearDown() {
        window.close()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Renders the whole Settings window, its frame included, offscreen, for a pull request when
/// screen capture is not available. Run with MAC_OS_AGENT_RENDER_SETTINGS set to a folder.
/// Liquid Glass is not drawn offscreen.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MAC_OS_AGENT_RENDER_SETTINGS"] != nil))
struct SettingsWindowRenders {
    @Test(arguments: [SettingsSection.general, .instructions, .memory, .skills, .behaviors, .experiments])
    func rendersTheWindow(section: SettingsSection) throws {
        let out = URL(filePath: ProcessInfo.processInfo.environment["MAC_OS_AGENT_RENDER_SETTINGS"]!, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let harness = try SettingsWindowHarness(section: section)
        defer { harness.tearDown() }
        harness.window.appearance = NSAppearance(named: .darkAqua)
        harness.layOut()
        // The frame view holds the title bar as well as the content.
        let frame = try #require(harness.window.contentView?.superview)
        frame.layoutSubtreeIfNeeded()
        let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: out.appending(path: "settings-\(section.rawValue).png"))
    }
}

/// The window's title bar, the title in it, and the sidebar's width, checked on the window's
/// views since screen capture is not available.
@MainActor
@Suite(.serialized) struct SettingsWindowTests {
    /// The view that draws the sidebar's list: the leftmost scroll view in the content.
    private func sidebar(in view: NSView) -> NSScrollView? {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView { found.append(scroll); return }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found.min { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
    }

    private func titleLabel(in window: NSWindow) -> NSTextField? {
        window.toolbar?.items.first { $0.itemIdentifier == SettingsTitleBar.titleItem }?.view as? NSTextField
    }

    @Test func theTitleBarSpansTheWindowAboveTheSidebar() throws {
        let harness = try SettingsWindowHarness(section: .general)
        defer { harness.tearDown() }
        harness.layOut()
        let window = harness.window
        #expect(window.styleMask.contains(.titled))
        #expect(!window.styleMask.contains(.fullSizeContentView))
        #expect(window.titlebarSeparatorStyle == .line)
        #expect(window.toolbarStyle == .unifiedCompact)
        // The content, sidebar included, starts below the title bar.
        let content = try #require(window.contentView)
        #expect(content.frame.maxY <= window.contentLayoutRect.maxY)
        #expect(window.frame.height - window.contentRect(forFrameRect: window.frame).height > 0)
    }

    @Test func theTitleIsTheSectionCenteredOnTheWindow() throws {
        let harness = try SettingsWindowHarness(section: .skills)
        defer { harness.tearDown() }
        harness.layOut()
        let window = harness.window
        #expect(window.titleVisibility == .hidden)
        #expect(window.toolbar?.items.map(\.itemIdentifier) == [SettingsTitleBar.titleItem])
        #expect(window.toolbar?.centeredItemIdentifiers == [SettingsTitleBar.titleItem])
        #expect(window.title == "Skills")
        #expect(titleLabel(in: window)?.stringValue == "Skills")

        for section in SettingsSection.allCases {
            harness.controller.models.navigation.section = section
            harness.layOut()
            #expect(window.title == section.title)
            let label = try #require(titleLabel(in: window))
            #expect(label.stringValue == section.title)
            let frame = label.convert(label.bounds, to: nil)
            #expect(abs(frame.midX - window.frame.width / 2) <= 2, "\(section.title) is centered")
            #expect(frame.width >= label.intrinsicContentSize.width - 1, "\(section.title) is not cut off")
        }
    }

    @Test func theSidebarKeepsItsWidthAndTheWindowItsSize() throws {
        let harness = try SettingsWindowHarness(section: .general)
        defer { harness.tearDown() }
        harness.layOut()
        let window = harness.window
        let content = try #require(window.contentView)
        let size = window.frame.size
        #expect(window.contentRect(forFrameRect: window.frame).size == SettingsWindowController.defaultSize)
        for section in SettingsSection.allCases {
            harness.controller.models.navigation.section = section
            harness.layOut()
            #expect(window.frame.size == size, "\(section.title) keeps the window's size")
            #expect(sidebar(in: content)?.frame.width == SettingsRootView.sidebarWidth, "\(section.title) keeps the sidebar's width")
        }
        // Nothing in the window drags it: there is no split view around the sidebar.
        var splits: [NSSplitView] = []
        func walk(_ view: NSView) { if let split = view as? NSSplitView { splits.append(split) }; view.subviews.forEach(walk) }
        harness.controller.models.navigation.section = .general
        harness.layOut()
        walk(content)
        #expect(splits.isEmpty)
        for width in [SettingsWindowController.minimumSize.width, 1400] {
            window.setContentSize(NSSize(width: width, height: SettingsWindowController.defaultSize.height))
            harness.layOut()
            #expect(sidebar(in: content)?.frame.width == SettingsRootView.sidebarWidth, "at \(width) points wide")
        }
    }

    @Test func debuggingIsLast() {
        #expect(SettingsSection.allCases.last == .debugging)
    }
}
