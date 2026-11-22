import AppKit
import MacOSAgentCore
import Observation
import SwiftUI

/// The sections of the Settings window, in sidebar order.
///
/// Debugging is always last. A new section, such as MCP servers, goes above it, with its view
/// in `SettingsRootView.detail`.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case instructions
    case skills
    case tools
    case debugging

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .instructions: "Instructions"
        case .skills: "Skills"
        case .tools: "Tools"
        case .debugging: "Debugging"
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .instructions: "text.quote"
        case .skills: "puzzlepiece.extension"
        case .tools: "wrench.and.screwdriver"
        case .debugging: "ladybug"
        }
    }
}

/// Which section is showing. It is kept in the preferences, so the window opens where it was left.
@MainActor
@Observable
final class SettingsNavigation {
    static let key = "SettingsSelectedSection"

    var section: SettingsSection {
        didSet { defaults.set(section.rawValue, forKey: Self.key) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        section = defaults.string(forKey: Self.key).flatMap(SettingsSection.init(rawValue:)) ?? .general
    }
}

/// What the Settings window shows, one model per section that keeps state.
@MainActor
struct SettingsModels {
    let session: AgentSession
    let shortcutAvailable: Bool
    let navigation: SettingsNavigation
    let instructions: InstructionsSettingsModel
    let skills: SkillsSettingsModel
    let tools: ToolsSettingsModel
    let debugging: DebuggingSettingsModel
}

/// The window's content: a sidebar of sections and the selected section beside it, in the
/// style of System Settings.
struct SettingsRootView: View {
    let models: SettingsModels
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: Binding<SettingsSection?>(
                get: { navigation.section },
                set: { if let section = $0 { navigation.section = section } }
            )) {
                ForEach(SettingsSection.allCases) { section in
                    Label(section.title, systemImage: section.symbolName)
                        .tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(navigation.section.title)
        }
    }

    @ViewBuilder private var detail: some View {
        switch navigation.section {
        case .general:
            GeneralSettingsView(session: models.session, shortcutAvailable: models.shortcutAvailable)
        case .instructions:
            InstructionsSettingsView(model: models.instructions)
        case .skills:
            SkillsSettingsView(model: models.skills)
        case .tools:
            ToolsSettingsView(model: models.tools)
        case .debugging:
            DebuggingSettingsView(model: models.debugging, instructions: models.instructions)
        }
    }
}

/// The Settings window: a SwiftUI split view with a sidebar, hosted in an AppKit window. The
/// app has no SwiftUI `App`, so it cannot use the `Settings` scene.
///
/// The window keeps one size whichever section is showing. The owner can resize it, and its
/// size and position are remembered.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let defaultSize = NSSize(width: 900, height: 620)
    static let minimumSize = NSSize(width: 760, height: 480)
    static let frameName = "SettingsWindow"

    let models: SettingsModels
    private var hasBeenShown = false

    /// - Parameter remembersFrame: False for previews, so they never write the owner's saved frame.
    init(
        session: AgentSession, prompt: AgentPrompt, usageLog: UsageLog, tools: ToolRegistry,
        problems: ProblemLog, signInStatus: @escaping @Sendable () async -> SignInStatus?,
        shortcutAvailable: Bool, defaults: UserDefaults = .standard, remembersFrame: Bool = true
    ) {
        models = SettingsModels(
            session: session,
            shortcutAvailable: shortcutAvailable,
            navigation: SettingsNavigation(defaults: defaults),
            instructions: InstructionsSettingsModel(prompt: prompt),
            skills: SkillsSettingsModel(library: prompt.skills),
            tools: ToolsSettingsModel(registry: tools),
            debugging: DebuggingSettingsModel(
                prompt: prompt, usageLog: usageLog, tools: tools, problems: problems,
                signInStatus: signInStatus, defaults: defaults))

        let root = SettingsRootView(models: models, navigation: models.navigation)
            .defaultAppStorage(defaults)
        let hosting = NSHostingController(rootView: root)
        // The window keeps its own size, so switching sections never resizes it.
        hosting.sizingOptions = []
        // The split view's toolbar and the section's title go to the window, as in System Settings.
        hosting.sceneBridgingOptions = [.toolbars, .title]

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.setContentSize(Self.defaultSize)
        window.contentMinSize = Self.minimumSize
        window.toolbarStyle = .unified
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenNone]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        if remembersFrame {
            hasBeenShown = window.setFrameUsingName(Self.frameName)
            window.setFrameAutosaveName(Self.frameName)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows the window in front of everything and gives it focus. The app has no Dock icon,
    /// so it has to activate itself first or the window would open behind the frontmost app.
    /// A preview passes `takeFocus: false`, so it never takes the keyboard from the owner.
    func show(_ section: SettingsSection? = nil, takeFocus: Bool = true) {
        if let section { models.navigation.section = section }
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
        models.skills.reload()
        models.instructions.reloadIfUnchanged()
        models.debugging.reload()
    }
}

/// The Settings window with stand-in data, for screenshots. `--preview-settings <section>`
/// shows it, and `--preview-item <name>` selects a skill or tool in that section.
@MainActor
enum SettingsPreview {
    private static var controller: SettingsWindowController?

    static func show(_ section: SettingsSection, item: String?) {
        let session = AgentSession(previewEntries: [])
        // Preferences of their own, so the model picker never reads or writes the real setting.
        let defaults = UserDefaults(suiteName: "dev.lubelski.mac-os-agent.preview") ?? .standard
        let prompt = AgentPrompt()
        let problems = ProblemLog()
        problems.record(
            "Request", "OpenAI API error (429): The usage limit for this plan was reached. Try again in 12 minutes.",
            date: Date().addingTimeInterval(-40 * 60))
        let controller = SettingsWindowController(
            session: session, prompt: prompt, usageLog: UsageLog(),
            tools: ToolRegistry(builtIn: BuiltInTools.make(skills: prompt.skills)),
            problems: problems,
            signInStatus: {
                SignInStatus(
                    isSignedIn: true, accessTokenExpires: Date().addingTimeInterval(52 * 60),
                    lastTokenDate: Date().addingTimeInterval(-8 * 60))
            },
            shortcutAvailable: true, defaults: defaults, remembersFrame: false)
        self.controller = controller
        if let item {
            controller.models.skills.selection = item
            controller.models.tools.selection = item
        }
        controller.show(section, takeFocus: false)
        controller.models.debugging.reload()
        // Quits on its own, so a failed capture script cannot leave it on screen.
        Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { _ in exit(0) }
    }
}
