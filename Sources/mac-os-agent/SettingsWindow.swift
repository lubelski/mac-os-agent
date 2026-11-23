import AppKit
import Carbon.HIToolbox
import MacOSAgentCore
import Observation
import SwiftUI

/// The sections of the Settings window, in sidebar order.
///
/// Debugging is always last. A new section goes above it, with its view in
/// `SettingsRootView.detail`.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case appearance
    case instructions
    case memory
    case skills
    // The raw value stays "actions": it is the section kept in the preferences, and the
    // name `--preview-settings` takes, from before quick actions were renamed.
    case quickActions = "actions"
    case tools
    case mcpServers = "mcp-servers"
    case history
    case behaviors
    case experiments
    case debugging

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .instructions: "Instructions"
        case .memory: "Memory"
        case .skills: "Skills"
        case .quickActions: "Quick Actions"
        case .tools: "Tools"
        case .mcpServers: "MCP Servers"
        case .history: "History"
        case .behaviors: "Behaviors"
        case .experiments: "Experiments"
        case .debugging: "Debugging"
        }
    }

    /// The sections in the sidebar. MCP Servers shows only with its experiment on.
    static func visible(mcpServersOn: Bool) -> [SettingsSection] {
        allCases.filter { $0 != .mcpServers || mcpServersOn }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .instructions: "text.quote"
        case .memory: "brain"
        case .skills: "puzzlepiece.extension"
        case .quickActions: "bolt"
        case .tools: "wrench.and.screwdriver"
        case .mcpServers: "server.rack"
        case .history: "clock.arrow.circlepath"
        case .behaviors: "keyboard"
        case .experiments: "flask"
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

    /// Whether the MCP Servers section is in the sidebar: the MCP servers experiment is on.
    private(set) var mcpServersOn: Bool

    /// Called after the section changes, so the window can title itself with it.
    @ObservationIgnored var didChange: ((SettingsSection) -> Void)?

    @ObservationIgnored private let defaults: UserDefaults
    /// Set for a preview that asks for MCP, which shows the section whatever the preference says.
    @ObservationIgnored private let mcpServersOverride: Bool?

    init(defaults: UserDefaults, mcpServersOverride: Bool? = nil) {
        self.defaults = defaults
        self.mcpServersOverride = mcpServersOverride
        let mcpServersOn = mcpServersOverride ?? Experiment.mcpServers.isOn(defaults)
        self.mcpServersOn = mcpServersOn
        let stored = defaults.string(forKey: Self.key).flatMap(SettingsSection.init(rawValue:))
        // A remembered section that is hidden now falls back as an unknown one does.
        section = stored.flatMap { SettingsSection.visible(mcpServersOn: mcpServersOn).contains($0) ? $0 : nil } ?? .general
    }

    var sections: [SettingsSection] { SettingsSection.visible(mcpServersOn: mcpServersOn) }

    /// The MCP servers experiment was turned on or off. Turning it off while its section shows
    /// lands on Experiments, where the switch is.
    func mcpServersExperimentChanged(_ on: Bool) {
        guard mcpServersOverride == nil, on != mcpServersOn else { return }
        mcpServersOn = on
        if !on, section == .mcpServers { section = .experiments }
    }
}

/// What the Settings window shows, one model per section that keeps state.
@MainActor
struct SettingsModels {
    let session: AgentSession
    let shortcut: ShortcutRecorderModel
    let navigation: SettingsNavigation
    let instructions: InstructionsSettingsModel
    let memory: MemorySettingsModel
    let skills: SkillsSettingsModel
    let quickActions: QuickActionsSettingsModel
    let tools: ToolsSettingsModel
    let mcpServers: MCPServersSettingsModel
    let history: HistorySettingsModel
    let debugging: DebuggingSettingsModel
    let updater: AppUpdater
}

/// The window's content: a sidebar of sections and the selected section beside it. The window's
/// own title bar spans both and says the section's name.
struct SettingsRootView: View {
    /// The sidebar's width. It is fixed: the sidebar cannot be dragged wider or collapsed.
    static let sidebarWidth: CGFloat = 200

    let models: SettingsModels
    @Bindable var navigation: SettingsNavigation
    @AppStorage(Experiment.mcpServers.key) private var mcpServersExperiment = false

    var body: some View {
        // A plain row rather than a split view, so the sidebar keeps its width: it cannot be
        // dragged or collapsed, and there is no sidebar button.
        HStack(spacing: 0) {
            List(selection: Binding<SettingsSection?>(
                get: { navigation.section },
                set: { if let section = $0 { navigation.section = section } }
            )) {
                ForEach(navigation.sections) { section in
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
        .onChange(of: mcpServersExperiment) { _, on in navigation.mcpServersExperimentChanged(on) }
    }

    @ViewBuilder private var detail: some View {
        switch navigation.section {
        case .general:
            GeneralSettingsView(session: models.session, shortcut: models.shortcut, updater: models.updater)
        case .appearance:
            AppearanceSettingsView(model: ThemeModel.shared)
        case .instructions:
            InstructionsSettingsView(model: models.instructions)
        case .memory:
            MemorySettingsView(model: models.memory)
        case .skills:
            SkillsSettingsView(model: models.skills)
        case .quickActions:
            QuickActionsSettingsView(model: models.quickActions)
        case .tools:
            ToolsSettingsView(model: models.tools)
        case .mcpServers:
            MCPServersSettingsView(model: models.mcpServers)
        case .history:
            HistorySettingsView(model: models.history)
        case .behaviors:
            BehaviorsSettingsView()
        case .experiments:
            ExperimentsSettingsView()
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
        secretStorage: SecretStorage.Status? = nil,
        summonTrigger: SummonTriggerController, defaults: UserDefaults = .standard, remembersFrame: Bool = true,
        privacyAccess: any PrivacyAccessGate = EventKitStore.shared,
        quickActions: QuickActionLibrary = QuickActionLibrary(),
        mcp: MCPServerPool = .empty, mcpServersOverride: Bool? = nil,
        updater: AppUpdater = .unavailable()
    ) {
        models = SettingsModels(
            session: session,
            shortcut: ShortcutRecorderModel(controller: summonTrigger),
            navigation: SettingsNavigation(defaults: defaults, mcpServersOverride: mcpServersOverride),
            instructions: InstructionsSettingsModel(prompt: prompt),
            memory: MemorySettingsModel(prompt: prompt),
            skills: SkillsSettingsModel(library: prompt.skills),
            quickActions: QuickActionsSettingsModel(library: quickActions, tools: tools.definitions, summaries: tools.summaries),
            tools: ToolsSettingsModel(registry: tools, access: privacyAccess, mcpSettings: mcp.settings),
            mcpServers: MCPServersSettingsModel(pool: mcp),
            history: HistorySettingsModel(history: history),
            debugging: DebuggingSettingsModel(
                prompt: prompt, usageLog: usageLog, tools: tools, problems: problems,
                signInStatus: signInStatus, secretStorage: secretStorage, defaults: defaults),
            updater: updater)

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
        models.quickActions.reload()
        models.instructions.reloadIfUnchanged()
        models.memory.reload()
        models.debugging.reload()
        models.history.reload()
        models.tools.reloadAccess()
        Task { await models.mcpServers.reload() }
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
        }), memories: MemoryLibrary())
        let problems = ProblemLog()
        problems.record(
            "Request", "OpenAI API error (429): The usage limit for this plan was reached. Try again in 12 minutes.",
            date: Date().addingTimeInterval(-40 * 60))
        let history = standInHistory()
        // A stand-in hotkey that never registers, so a preview cannot take the installed app's.
        let hotKey = StandInHotKey()
        let summonTrigger = SettingsPreview.summonTrigger(hotKey: hotKey, defaults: defaults, state: section == .general ? item : nil)
        // A preview of MCP Servers, or of an MCP tool, asks for MCP, so it shows as if the
        // experiment were on without reading or writing its preference. Other previews follow
        // the preview's own preferences, where it is off.
        let showsMCP = section == .mcpServers || (section == .tools && item?.contains(MCPToolNaming.separator) == true)
        let mcp = showsMCP ? standInMCPServers() : .empty
        let controller = SettingsWindowController(
            session: session, prompt: prompt, usageLog: UsageLog(),
            tools: ToolRegistry(builtIn: BuiltInTools.make(skills: prompt.skills, history: history), additional: mcp.makeTools()),
            history: history,
            problems: problems,
            signInStatus: {
                SignInStatus(
                    isSignedIn: true, accessTokenExpires: Date().addingTimeInterval(52 * 60),
                    lastTokenDate: Date().addingTimeInterval(-8 * 60))
            },
            // A stand-in. A preview decides nothing about the real store and never opens the Keychain.
            secretStorage: SecretStorage.Status(location: .file, reason: .anotherDataFolder, migration: nil),
            summonTrigger: summonTrigger, defaults: defaults, remembersFrame: false,
            privacyAccess: StandInPrivacyAccess(), mcp: mcp, mcpServersOverride: showsMCP ? true : nil)
        self.controller = controller
        if section == .general, let item {
            showShortcut(item, in: controller.models.shortcut)
        } else if let item {
            controller.models.history.query = section == .history ? item : ""
            controller.models.skills.selection = item
            if section == .quickActions { controller.models.quickActions.selection = item }
            controller.models.tools.selection = item
            if section == .mcpServers { controller.models.mcpServers.selection = item }
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

    /// The MCP servers in the data folder's files, with stand-in connections that start no
    /// process. Without `--data-folder` it reads nothing and shows no servers. Each server acts
    /// by its name: `notes` fails, `files` never finishes starting, and the rest connect with
    /// their cached tools, or a stand-in list when they have none.
    private static func standInMCPServers() -> MCPServerPool {
        guard CommandLine.arguments.contains(AgentPaths.dataFolderArgument) else { return .empty }
        let settings = MCPSettingsStore()
        let cache = MCPToolCache.read()
        let pool = MCPServerPool(
            config: MCPServerConfig.read(), settings: settings, cache: cache, cacheFile: nil,
            factory: { entry in StandInMCPConnection(name: entry.name, cached: cache.servers[entry.name]?.tools) })
        Task { await pool.start() }
        return pool
    }

    /// A connection that acts by the server's name and never starts a process.
    private struct StandInMCPConnection: MCPServerConnection {
        let name: String
        let cached: [MCPToolInfo]?

        func connect() async throws {
            switch name {
            case "notes":
                throw MCPConnectionError.exited(status: 1, message: "Error: NOTES_API_TOKEN is not set.")
            case "files":
                try await Task.sleep(for: .seconds(60))
            default:
                break
            }
        }

        func listTools() async throws -> [MCPToolInfo] {
            cached ?? [
                MCPToolInfo(name: "current_time", description: "The current time in a time zone.", inputSchema: [
                    "type": "object", "properties": ["zone": ["type": "string", "description": "An IANA time zone, such as Europe/Lisbon."]],
                ], readOnly: true),
                MCPToolInfo(name: "set_timer", description: "Starts a countdown timer.", inputSchema: [
                    "type": "object", "properties": ["minutes": ["type": "number"]], "required": ["minutes"],
                ]),
            ]
        }

        func callTool(name: String, arguments: JSONValue) async throws -> MCPCallResult {
            MCPCallResult(content: [.text("A stand-in result.")])
        }

        func stop() async {}
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
