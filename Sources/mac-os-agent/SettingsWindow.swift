import AppKit
import MacOSAgentCore
import SwiftUI

/// The panes of the Settings window, in toolbar order.
///
/// An MCP pane goes here as another case, with its view in `SettingsWindowController.view(for:)`.
/// Its servers' tools reach the agent through `ToolRegistry(additional:)` in `AppDelegate`.
enum SettingsPane: String, CaseIterable {
    case general
    case instructions
    case skills

    var title: String {
        switch self {
        case .general: "General"
        case .instructions: "Instructions"
        case .skills: "Skills"
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .instructions: "text.quote"
        case .skills: "puzzlepiece.extension"
        }
    }
}

/// The Settings window: a standard AppKit settings window with a toolbar of panes, each a
/// SwiftUI view. The app has no SwiftUI `App`, so it cannot use the `Settings` scene.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let tabs = NSTabViewController()
    let instructions: InstructionsSettingsModel
    let skills: SkillsSettingsModel
    private var hasBeenShown = false

    init(session: AgentSession, prompt: AgentPrompt, shortcutAvailable: Bool, defaults: UserDefaults = .standard) {
        instructions = InstructionsSettingsModel(prompt: prompt)
        skills = SkillsSettingsModel(library: prompt.skills)

        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = true
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenNone]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        for pane in SettingsPane.allCases {
            let root = view(for: pane, session: session, shortcutAvailable: shortcutAvailable)
                .defaultAppStorage(defaults)
            let hosting = NSHostingController(rootView: root)
            hosting.sizingOptions = [.preferredContentSize]
            hosting.title = pane.title
            let item = NSTabViewItem(viewController: hosting)
            item.identifier = pane.rawValue
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbolName, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func view(for pane: SettingsPane, session: AgentSession, shortcutAvailable: Bool) -> AnyView {
        switch pane {
        case .general: AnyView(GeneralSettingsView(session: session, shortcutAvailable: shortcutAvailable))
        case .instructions: AnyView(InstructionsSettingsView(model: instructions))
        case .skills: AnyView(SkillsSettingsView(model: skills))
        }
    }

    /// Shows the window in front of everything and gives it focus. The app has no Dock icon,
    /// so it has to activate itself first or the window would open behind the frontmost app.
    /// A preview passes `takeFocus: false`, so it never takes the keyboard from the owner.
    func show(_ pane: SettingsPane? = nil, takeFocus: Bool = true) {
        if let pane, let index = SettingsPane.allCases.firstIndex(of: pane) {
            tabs.selectedTabViewItemIndex = index
        }
        guard let window else { return }
        if !hasBeenShown {
            window.center()
            hasBeenShown = true
        }
        if takeFocus {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
        window.orderFrontRegardless()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // The agent can write skills and the person can edit files in Finder while the window
        // is closed, so read them again whenever it comes forward.
        skills.reload()
        instructions.reloadIfUnchanged()
    }
}

/// The Settings window with stand-in data, for screenshots. `--preview-settings <pane>` shows it.
@MainActor
enum SettingsPreview {
    private static var controller: SettingsWindowController?

    static func show(_ pane: SettingsPane) {
        let session = AgentSession(previewEntries: [])
        // Preferences of their own, so the model picker never reads or writes the real setting.
        let defaults = UserDefaults(suiteName: "dev.lubelski.mac-os-agent.preview") ?? .standard
        let controller = SettingsWindowController(
            session: session, prompt: AgentPrompt(), shortcutAvailable: true, defaults: defaults)
        self.controller = controller
        controller.show(pane, takeFocus: false)
        // Quits on its own, so a failed capture script cannot leave it on screen.
        Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { _ in exit(0) }
    }
}
