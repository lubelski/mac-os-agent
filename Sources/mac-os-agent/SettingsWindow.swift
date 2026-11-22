import AppKit
import Carbon.HIToolbox
import MacOSAgentCore
import Observation
import SwiftUI

/// The sections of the Settings window, in sidebar order.
///
/// Debugging is always last. A new section, such as MCP servers, goes above it, with its view
/// in `SettingsRootView.detail`.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case appearance
    case instructions
    case skills
    case tools
    case history
    case debugging

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .instructions: "Instructions"
        case .skills: "Skills"
        case .tools: "Tools"
        case .history: "History"
        case .debugging: "Debugging"
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .instructions: "text.quote"
        case .skills: "puzzlepiece.extension"
        case .tools: "wrench.and.screwdriver"
        case .history: "clock.arrow.circlepath"
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
        didSet {
            defaults.set(section.rawValue, forKey: Self.key)
            didChange?(section)
        }
    }

    /// Called after the section changes, so the window can title itself with it.
    @ObservationIgnored var didChange: ((SettingsSection) -> Void)?

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
    let shortcut: ShortcutRecorderModel
    let navigation: SettingsNavigation
    let instructions: InstructionsSettingsModel
    let skills: SkillsSettingsModel
    let tools: ToolsSettingsModel
    let history: HistorySettingsModel
    let debugging: DebuggingSettingsModel
}

/// The window's content: a sidebar of sections and the selected section beside it. The window's
/// own title bar spans both and says the section's name.
struct SettingsRootView: View {
    /// The sidebar's width. It is fixed: the sidebar cannot be dragged wider or collapsed.
    static let sidebarWidth: CGFloat = 200

    let models: SettingsModels
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        // A plain row rather than a split view, so the sidebar keeps its width: it cannot be
        // dragged or collapsed, and there is no sidebar button.
        HStack(spacing: 0) {
            List(selection: Binding<SettingsSection?>(
                get: { navigation.section },
                set: { if let section = $0 { navigation.section = section } }
            )) {
                ForEach(SettingsSection.allCases) { section in
                    // The sidebar draws the selected row's title in a heavier weight, which widens
                    // it. A weight set on the title's own Text overrides that, so the row keeps
                    // one weight across hover and selection. On the Label it has no effect.
                    Label {
                        Text(section.title).fontWeight(.regular)
                    } icon: {
                        Image(systemName: section.symbolName)
                    }
                    .tag(section)
                }
            }
            .listStyle(.sidebar)
            .frame(width: Self.sidebarWidth)
            Divider()
            // A minimum of zero keeps a section's ideal size, such as a long line in the
            // instructions editor, from pushing the window or the sidebar around.
            detail
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var detail: some View {
        switch navigation.section {
        case .general:
            GeneralSettingsView(session: models.session, shortcut: models.shortcut)
        case .appearance:
            AppearanceSettingsView(model: ThemeModel.shared)
        case .instructions:
            InstructionsSettingsView(model: models.instructions)
        case .skills:
            SkillsSettingsView(model: models.skills)
        case .tools:
            ToolsSettingsView(model: models.tools)
        case .history:
            HistorySettingsView(model: models.history)
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
    let titleBar = SettingsTitleBar()
    private var hasBeenShown = false

    /// - Parameter remembersFrame: False for previews, so they never write the owner's saved frame.
    init(
        session: AgentSession, prompt: AgentPrompt, usageLog: UsageLog, tools: ToolRegistry,
        history: ThreadStore?, problems: ProblemLog, signInStatus: @escaping @Sendable () async -> SignInStatus?,
        summonTrigger: SummonTriggerController, defaults: UserDefaults = .standard, remembersFrame: Bool = true,
        privacyAccess: any PrivacyAccessGate = EventKitStore.shared
    ) {
        models = SettingsModels(
            session: session,
            shortcut: ShortcutRecorderModel(controller: summonTrigger),
            navigation: SettingsNavigation(defaults: defaults),
            instructions: InstructionsSettingsModel(prompt: prompt),
            skills: SkillsSettingsModel(library: prompt.skills),
            tools: ToolsSettingsModel(registry: tools, access: privacyAccess),
            history: HistorySettingsModel(history: history),
            debugging: DebuggingSettingsModel(
                prompt: prompt, usageLog: usageLog, tools: tools, problems: problems,
                signInStatus: signInStatus, defaults: defaults))

        let root = SettingsRootView(models: models, navigation: models.navigation)
            .defaultAppStorage(defaults)
        let hosting = NSHostingController(rootView: root)
        // The window keeps its own size, so switching sections never resizes it.
        hosting.sizingOptions = []
        // The window's title and title bar are set below, not by SwiftUI.
        hosting.sceneBridgingOptions = []

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        // A title bar across the whole window, above the sidebar and the section, with a hairline
        // under it. The content starts below it. The system draws a window's own title at the
        // leading edge, so the title is hidden and the toolbar's one centered item says it.
        window.titleVisibility = .hidden
        window.toolbar = titleBar.toolbar
        window.toolbarStyle = .unifiedCompact
        window.titlebarSeparatorStyle = .line
        window.contentViewController = hosting
        window.setContentSize(Self.defaultSize)
        window.contentMinSize = Self.minimumSize
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenNone]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        showTitle(of: models.navigation.section)
        models.navigation.didChange = { [weak self] in self?.showTitle(of: $0) }
        if remembersFrame {
            hasBeenShown = window.setFrameUsingName(Self.frameName)
            window.setFrameAutosaveName(Self.frameName)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Titles the window with the section's name.
    private func showTitle(of section: SettingsSection) {
        window?.title = section.title
        titleBar.title = section.title
    }

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

    func windowWillClose(_ notification: Notification) {
        models.shortcut.cancel()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // The agent can write skills and the person can edit files in Finder while the window
        // is closed, so read them again whenever it comes forward.
        models.skills.reload()
        models.instructions.reloadIfUnchanged()
        models.debugging.reload()
        models.history.reload()
        models.tools.reloadAccess()
    }
}

/// The Settings window's title bar: a compact toolbar with nothing in it but the title, centered
/// on the whole window. The window's own title stays set, for the Window menu and VoiceOver.
@MainActor
final class SettingsTitleBar: NSObject, NSToolbarDelegate {
    static let titleItem = NSToolbarItem.Identifier("SettingsTitle")

    let toolbar = NSToolbar(identifier: "Settings")
    let label = NSTextField(labelWithString: "")

    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override init() {
        super.init()
        // The font the system uses for a window's title.
        label.font = .titleBarFont(ofSize: 0)
        label.textColor = .windowFrameTextColor
        label.lineBreakMode = .byTruncatingTail
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [Self.titleItem]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.titleItem] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.titleItem] }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.view = label
        item.isBordered = false
        item.visibilityPriority = .high
        return item
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
        // The default instructions take the agent's name from the same preferences.
        let prompt = AgentPrompt(instructions: InstructionsStore(agentName: {
            AgentNameSetting.current(UserDefaults(suiteName: "dev.lubelski.mac-os-agent.preview") ?? .standard)
        }))
        let problems = ProblemLog()
        problems.record(
            "Request", "OpenAI API error (429): The usage limit for this plan was reached. Try again in 12 minutes.",
            date: Date().addingTimeInterval(-40 * 60))
        let history = standInHistory()
        // A stand-in hotkey that never registers, so a preview cannot take the installed app's.
        let hotKey = StandInHotKey()
        let summonTrigger = SettingsPreview.summonTrigger(hotKey: hotKey, defaults: defaults, state: section == .general ? item : nil)
        let controller = SettingsWindowController(
            session: session, prompt: prompt, usageLog: UsageLog(),
            tools: ToolRegistry(builtIn: BuiltInTools.make(skills: prompt.skills, history: history)),
            history: history,
            problems: problems,
            signInStatus: {
                SignInStatus(
                    isSignedIn: true, accessTokenExpires: Date().addingTimeInterval(52 * 60),
                    lastTokenDate: Date().addingTimeInterval(-8 * 60))
            },
            summonTrigger: summonTrigger, defaults: defaults, remembersFrame: false,
            privacyAccess: StandInPrivacyAccess())
        self.controller = controller
        if section == .general, let item {
            showShortcut(item, in: controller.models.shortcut)
        } else if let item {
            controller.models.history.query = section == .history ? item : ""
            controller.models.skills.selection = item
            controller.models.tools.selection = item
            controller.models.debugging.scrollTarget = item
        }
        controller.show(section, takeFocus: false)
        controller.models.debugging.reload()
        // Quits on its own, so a failed capture script cannot leave it on screen.
        Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { _ in exit(0) }
    }

    /// The summon shortcut in a preview. `--preview-item` picks a state for General:
    /// `recording`, `conflict` (Command-Space while Spotlight still has it), or `taken` (a chord
    /// another app holds). The preview's own preferences start from the default each time.
    private static func summonTrigger(hotKey: StandInHotKey, defaults: UserDefaults, state: String?) -> SummonTriggerController {
        SummonTriggerSetting.restoreDefault(defaults)
        let spotlight = SystemShortcut(keyCode: UInt16(kVK_Space), carbonModifiers: UInt32(cmdKey), isEnabled: true)
        let controller = SummonTriggerController(
            registrar: hotKey, defaults: defaults,
            systemShortcuts: { state == "conflict" ? [spotlight] : [] })
        controller.start()
        if state == "taken" {
            hotKey.taken = [KeyChord(keyCode: UInt16(kVK_ANSI_K), modifiers: [.control, .option])]
        }
        return controller
    }

    private static func showShortcut(_ state: String, in recorder: ShortcutRecorderModel) {
        switch state {
        case "recording":
            // The preview window never has focus, so the recorder's monitor sees no keys.
            recorder.startRecording()
        case "conflict":
            recorder.record(KeyChord(keyCode: UInt16(kVK_Space), modifiers: .command))
        case "taken":
            recorder.record(KeyChord(keyCode: UInt16(kVK_ANSI_K), modifiers: [.control, .option]))
        case "rejected":
            recorder.startRecording()
            recorder.record(KeyChord(keyCode: UInt16(kVK_ANSI_W), modifiers: .command))
        default:
            break
        }
    }

    /// Access as a preview shows it: Reminders allowed, Calendars not asked yet. It never asks
    /// the owner for anything.
    private struct StandInPrivacyAccess: PrivacyAccessGate {
        func status(_ kind: PrivacyAccessKind) -> PrivacyAccessStatus {
            kind == .reminders ? .fullAccess : .notDetermined
        }

        func requestAccess(_ kind: PrivacyAccessKind) async -> PrivacyAccessStatus { status(kind) }
    }

    /// A few episodes of stand-in conversation in a temporary folder, never the real thread.
    private static func standInHistory() -> ThreadStore? {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "mac-os-agent-preview-\(UUID().uuidString)", directoryHint: .isDirectory)
        guard let store = try? ThreadStore(fileURL: folder.appending(path: "thread.jsonl")) else { return nil }
        let now = Date()
        let episodes: [(Double, [(String, String?, String)])] = [
            (6 * 24 * 60, [("what's eating my disk space", "du -sh ~/Library/Caches ~/Downloads ~/Movies 2>/dev/null | sort -hr", "Movies is the big one at 38 GB, then Downloads at 12 GB.")]),
            (3 * 24 * 60, [("turn on dark mode", "osascript -e 'tell application \"System Events\" to tell appearance preferences to set dark mode to true'", "Dark mode is on."),
                           ("and set the accent color to purple", "defaults write -g AppleAccentColor -int 5", "The accent color is purple now. Some apps pick it up after a restart.")]),
            (26 * 60, [("open notion", "open -a Notion", "Notion is open.")]),
            (95, [("how long until my battery is full", "pmset -g batt", "About 42 minutes. It’s at 81% and charging.")]),
            (12, [("move every PDF from Downloads with receipt in its name into a Receipts folder", "mkdir -p ~/Desktop/Receipts && mv ~/Downloads/*receipt*.pdf ~/Desktop/Receipts/", "Moved 7 receipts into Receipts on the desktop."),
                  ("how many are from this year", "ls ~/Desktop/Receipts | grep -c 2026", "Five of the seven are from 2026.")]),
        ]
        var call = 0
        Task {
            for (index, (minutesAgo, exchanges)) in episodes.enumerated() {
                var clock = now.addingTimeInterval(-minutesAgo * 60)
                func tick() -> Date { clock = clock.addingTimeInterval(20); return clock }
                if index > 0 { try? await store.append(.episodeStart(.init(reason: .timeout)), date: clock) }
                for (message, command, reply) in exchanges {
                    try? await store.append(.userMessage(text: message), date: tick())
                    if let command {
                        call += 1
                        let arguments: JSONValue = ["command": .string(command), "destructive": false]
                        try? await store.append(.toolCall(.init(callID: "call_\(call)", name: "run_shell_command", arguments: arguments.encodedString(), provider: "openai", model: "gpt-6-luna")), date: tick())
                        try? await store.append(.toolResult(.init(callID: "call_\(call)", output: "[exit status 0]")), date: tick())
                    }
                    try? await store.append(.assistantMessage(.init(text: reply, provider: "openai", model: "gpt-6-luna")), date: tick())
                }
            }
            controller?.models.history.reload()
        }
        return store
    }
}
