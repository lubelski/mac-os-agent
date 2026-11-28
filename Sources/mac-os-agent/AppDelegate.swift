import AppKit
import MacOSAgentCore
import os

let log = Logger(subsystem: "dev.lubelski.mac-os-agent", category: "app")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()
    private var session: AgentSession!
    private var panel: SummonPanel!
    private var incognito: IncognitoWindowController!
    private var summonTrigger: SummonTriggerController!
    private var settings: SettingsWindowController!
    /// Read once at launch, with the panel with bars experiment's switch, which decides whether
    /// the tool list has `set_links` and the instructions say what the links row is for, and the
    /// settings tools experiment's, which decides whether it has the settings group behind
    /// `find_tools` and `use_tool` and the instructions list it.
    private let prompt = AgentPrompt(
        memories: MemoryLibrary(), taskLinks: Experiment.panelWithBarsAndInputPill.isOn(),
        toolGroups: Experiment.settingsTools.isOn() ? [SettingsToolGroup.listing] : [])
    /// Each line says which Mac and build wrote it, read at the first request, after launch has
    /// set the data folder.
    private let usageLog = UsageLog(device: { UsageDevice.thisMac })
    /// The models Ollama serves on this Mac, read at launch and each time the menu opens, with
    /// the local models experiment on.
    private let localModels = LocalModelList()
    /// Created at launch, so it checks on its own schedule. In a build with no feed it does nothing.
    private var updater: AppUpdater!
    /// Journals a change made to the memory folder outside the app, such as in an editor.
    private var memoryWatcher: FolderWatcher?
    /// The MCP servers for this run, started in the background after launch. Behind the MCP
    /// servers experiment: with it off, nothing is read or started.
    private var mcp: MCPServerPool?
    /// Follows the MCP servers experiment's switch while the app runs.
    private var mcpExperimentObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything reads the quick actions folder, which used to be `actions/`.
        let quickActionsMove = QuickActionLibrary.moveFolderFromOldName()
        let installationID = AgentPaths.installationID()
        if Experiment.localModelsThroughOllama.isOn() {
            Task { [localModels] in await localModels.refresh() }
        }
        // A release build moves the sign-in from secrets.json to the Keychain here, once. A
        // development build still keeps other secrets, such as a Brave Search key, in the file.
        let secretStorage = SecretStorage.forThisRun()
        // A development build reaches its models through inference-gateway and has no sign-in,
        // so it never creates an authenticator or reads the sign-in.
        let modelAccess = ModelAccess.forThisRun()
        let authenticator: ChatGPTAuthenticator? = modelAccess == .signIn
            ? ChatGPTAuthenticator(secrets: secretStorage.store, installationID: installationID)
            : nil
        let providerAccess: OpenAIResponsesProvider.Access = authenticator.map { .signIn($0) }
            ?? .gateway(InferenceGateway.baseURL)
        var loop: AgentLoop?
        var startupError: Error?
        var thread: ThreadStore?
        do {
            thread = try ThreadStore(fileURL: AgentPaths.threadFile, searchIndexURL: AgentPaths.historyIndexFile)
        } catch {
            startupError = error
        }
        // The MCP servers' tools come from their cached lists, so launch never waits for a server.
        let problems = ProblemLog()
        var mcpExperimentOn = Experiment.mcpServers.isOn()
        let mcp = MCPServerPool.fromDataFolder(problems: problems, experimentOn: mcpExperimentOn)
        self.mcp = mcp
        // The tool list stays as it was built. Turning the experiment on starts the servers now,
        // so their lists are cached for the next launch, and off stops them.
        mcpExperimentObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main
        ) { _ in
            let on = Experiment.mcpServers.isOn()
            MainActor.assumeIsolated {
                guard on != mcpExperimentOn else { return }
                mcpExperimentOn = on
                Task { await mcp.setActive(on) }
            }
        }
        // Read once, since it changes the tool list or the request, which stay fixed for the run.
        let webSearch = WebSearchContext(launched: WebSearchSetting.current(), key: BraveSearchKey(secrets: secretStorage.store))
        let mcpTools = mcp.makeTools()
        // The settings group reads this run's servers and the experiments as they were at launch.
        let onDemandGroups = prompt.toolGroups.isEmpty ? [] : [
            SettingsToolGroup.make(access: AppSettingsAccess(
                mcp: mcp,
                toolsInThisRun: Dictionary(mcpTools.compactMap { ($0 as? MCPTool).map { ($0.server, 1) } }, uniquingKeysWith: +),
                experimentsOnAtLaunch: Set(Experiment.allCases.filter { $0.isOn() }))),
        ]
        // Built once, so the tool list stays the same for the whole run, and shared with Settings.
        let tools = ToolRegistry(
            builtIn: BuiltInTools.make(
                skills: prompt.skills, history: thread, memories: prompt.memories ?? MemoryLibrary(),
                webSearch: webSearch.launched == .brave ? SearchWebTool(key: webSearch.key) : nil,
                taskLinks: prompt.taskLinks ? SetLinksTool(isOn: { Experiment.panelWithBarsAndInputPill.isOn() }) : nil,
                onDemandGroups: onDemandGroups),
            additional: mcpTools
        // Read once, like web search, since it changes the tool list.
        ).addingRunScript(Experiment.scripts.isOn())
        if let thread {
            let provider = OpenAIResponsesProvider(
                access: providerAccess,
                model: { ModelSetting.effective() },
                promptCacheKey: "mac-os-agent-\(installationID.uuidString.lowercased())")
            let prompt = prompt
            let usageLog = usageLog
            let timeout: @Sendable () -> TimeInterval = { EpisodeTimeoutSetting.current() }
            loop = AgentLoop(
                provider: provider, thread: thread,
                tools: tools.tools,
                instructionsForEpisode: { episodeID in prompt.current(episodeID: episodeID) },
                usageLog: usageLog,
                episodeTimeout: timeout,
                webSearch: webSearch.launched.usesHostedSearch,
                instructionsForNewEpisode: { prompt.forNewEpisode() },
                // The main panel keeps attached images in the images folder. The incognito
                // window's loop keeps them in memory, its default.
                images: ImageFolder())
        }
        // The incognito window has a provider of its own with its own cache key, so its
        // requests, with their own instructions and tools, are a separate cached prefix.
        let incognitoProvider = OpenAIResponsesProvider(
            access: providerAccess,
            model: { ModelSetting.effective() },
            promptCacheKey: "mac-os-agent-incognito-\(installationID.uuidString.lowercased())")
        let makeIncognitoLoop = { [prompt = self.prompt, usageLog = self.usageLog] in
            IncognitoWindowController.makeLoop(provider: incognitoProvider, prompt: prompt, usageLog: usageLog)
        }

        session = AgentSession(
            loop: loop, authenticator: authenticator, signedIn: modelAccess == .gateway, problems: problems)
        session.modelAccess = modelAccess
        session.mcpSettings = mcp.settings
        // Read at each send: the model setting, and what Ollama last said about a local model.
        let imageInputSupported: () -> Bool? = { [localModels] in
            ImageInput.isSupported(modelID: ModelSetting.effective(), localCapabilities: localModels.capabilities)
        }
        session.imageInputSupported = imageInputSupported
        session.onStatusChange = { [weak self] in self?.statusDidChange() }
        session.toolSources = tools.sourceTitles
        session.instantActions = .live(summaries: tools.summaries)
        // The skills the owner can invoke with a slash, kept live as the folder changes.
        session.skillCommands = SkillCommandsModel(library: prompt.skills)
        session.memories = prompt.memories
        // The links row reads what `set_links` kept, only when the tool is in this run's list.
        if prompt.taskLinks { session.taskLinkStore = TaskLinkStore() }
        panel = SummonPanel(session: session)
        // A change made while the app was not running, or while it runs, is journaled as made
        // outside the app, so the history has no holes.
        if let memories = prompt.memories {
            memories.reconcile()
            memoryWatcher = FolderWatcher(folder: memories.folder) { memories.reconcile() }
        }

        incognito = IncognitoWindowController(makeSession: { [weak self] in
            let incognito = AgentSession(incognito: makeIncognitoLoop, signedIn: self?.session.signInState == .signedIn)
            if let main = self?.session {
                incognito.toolSources = main.toolSources
                incognito.instantActions = main.instantActions.incognitoCopy()
            }
            incognito.imageInputSupported = imageInputSupported
            return incognito
        })
        incognito.mainPanelFrame = { [weak self] in self?.panel.placedFrame }
        incognito.onChange = { [weak self] in self?.updateStatusIcon() }
        session.openIncognito = { [weak self] in self?.incognito.open() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusMenu.delegate = self
        // No menu attached, so a left click reaches the action. See `StatusItemClick`.
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemPressed(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.setAccessibilityHelp("Shows or hides the panel. Opens the menu with a right click or Control-click.")
        statusItem.button?.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Show or Hide the Panel") { [weak self] in
                self?.panel.toggle()
                return true
            },
            NSAccessibilityCustomAction(name: "Show Menu") { [weak self] in
                guard let self else { return false }
                statusItem.showMenu(statusMenu)
                return true
            },
        ])
        updateStatusIcon()

        summonTrigger = SummonTriggerController(registrar: CarbonHotKey { [weak self] in self?.panel.toggle() })
        summonTrigger.onChange = { [weak self] in self?.updateStatusIcon() }
        if let problem = summonTrigger.start() {
            session.problems.record("Shortcut", problem)
        }
        updateStatusIcon()
        if quickActionsMove == .moved { log.notice("Renamed the actions folder to quick-actions") }
        if let problem = quickActionsMove.problem {
            log.notice("\(problem, privacy: .public)")
            session.problems.record("Quick actions", problem)
        }
        if modelAccess == .gateway {
            log.notice("Models through inference-gateway at \(InferenceGateway.address(), privacy: .public). No sign-in in this build.")
        } else {
            log.notice("Sign-in kept in \(secretStorage.status.place, privacy: .public). \(secretStorage.status.explanation, privacy: .public)")
        }
        if case .failed = secretStorage.status.migration {
            session.problems.record("Sign-in", secretStorage.status.explanation)
        }
        if let startupError {
            session.problems.record("Startup", "Could not open the thread: \(startupError.localizedDescription)")
        }
        let updater = AppUpdater { [weak self] in self?.relaunchActivity() ?? .init() }
        self.updater = updater
        // The panel menu's Check for Updates runs the same check as the menu bar menu's, and
        // like it is there only in a build with a feed. The incognito window's menu has none.
        if updater.isAvailable {
            panel.placement.updateCheck = PanelPlacement.UpdateCheck(
                canCheck: { updater.canCheck },
                check: { [weak self] in self?.checkForUpdates() })
        }
        settings = SettingsWindowController(
            session: session, prompt: prompt, usageLog: usageLog, tools: tools, history: thread, problems: session.problems,
            signInStatus: { await authenticator?.status() },
            secretStorage: secretStorage.status, modelAccess: modelAccess,
            summonTrigger: summonTrigger, mcp: mcp, webSearch: webSearch, updater: updater)
        log.notice("Hotkey \(self.summonTrigger.displayName ?? "none", privacy: .public) registered: \(self.summonTrigger.isRegistered, privacy: .public). Status item button: \(self.statusItem.button != nil, privacy: .public)")

        Task { await session.start() }
        Task { await mcp.start() }

        // For checking the panel without pressing the hotkey, such as from a script.
        if CommandLine.arguments.contains("--summon-at-launch") {
            panel.summon()
        }

        if let startupError {
            let alert = NSAlert()
            alert.messageText = "mac-os-agent could not open its thread"
            alert.informativeText = "\(AgentPaths.threadFile.path)\n\(startupError.localizedDescription)"
            NSApp.activate()
            alert.runModal()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        summonTrigger?.stop()
        // Waits up to a second for the servers to exit, then kills what is left, so none
        // outlives the app.
        MCPServerProcess.stopAll()
    }

    /// The main panel's session changed: the icon follows it, and the incognito window's
    /// sign-in follows the main panel's.
    private func statusDidChange() {
        incognito?.session?.followSignIn(session.signInState)
        updateStatusIcon()
    }

    /// The icon shows a task running, or waiting for a go-ahead, in either window.
    private func updateStatusIcon() {
        let symbol: String
        let description: String
        let incognitoSession = incognito?.session
        if session.pendingConfirmation != nil || incognitoSession?.pendingConfirmation != nil {
            symbol = "hand.raised.fill"
            description = "mac-os-agent is waiting for your go-ahead"
        } else if session.isRunning || incognitoSession?.isRunning == true {
            symbol = "sparkle.magnifyingglass"
            description = "mac-os-agent is working"
        } else {
            symbol = "sparkle"
            description = "mac-os-agent"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        image?.isTemplate = true
        statusItem.button?.image = image
        // The tooltip names the shortcut, read when the pointer rests on the icon.
        statusItem.button?.toolTip = summonTrigger?.displayName.map { "\(description)\n\($0) shows or hides the panel" } ?? description
        // A task ending, a go-ahead answered, or the incognito window closing can be what an
        // update that is ready was waiting for.
        updater?.installPendingUpdate()
    }

    /// What a relaunch into an update would cut off, in either window.
    private func relaunchActivity() -> AppUpdates.Activity {
        let sessions = [session, incognito?.session].compactMap { $0 }
        return AppUpdates.Activity(
            taskRunning: sessions.contains { $0.isRunning },
            waitingForGoAhead: sessions.contains { $0.pendingConfirmation != nil },
            queuedMessages: sessions.contains { !$0.queue.isEmpty },
            incognitoConversation: incognito?.session?.transcript.rows.contains { !$0.isEpisodeStart } == true)
    }

    // MARK: - Menu

    @objc private func statusItemPressed(_ sender: Any?) {
        switch StatusItemClick.action(for: NSApp.currentEvent) {
        case .togglePanel: panel.toggle()
        case .showMenu: statusItem.showMenu(statusMenu)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // For the next time it opens. The menu draws with the list as last read.
        if Experiment.localModelsThroughOllama.isOn() {
            Task { [localModels] in await localModels.refresh() }
        }
        menu.removeAllItems()

        // The panel's presented state, not whether its window is on screen, so during a slide
        // out the item already says Show and brings it back.
        let open = NSMenuItem(
            title: panel.menuItemHides ? "Hide mac-os-agent" : "Show mac-os-agent",
            action: #selector(togglePanel), keyEquivalent: "")
        if let chord = summonTrigger.trigger?.keyChord {
            open.keyEquivalent = chord.menuKeyEquivalent(keys: summonTrigger.keys())
            open.keyEquivalentModifierMask = chord.eventModifierFlags
        }
        open.target = self
        menu.addItem(open)
        if let name = summonTrigger.displayName, !summonTrigger.isRegistered {
            menu.addItem(disabledItem("\(name) is taken by another app"))
        }
        if session.isRunning {
            menu.addItem(item("Stop the Current Task", #selector(stopTask)))
        }
        if incognito.session?.isRunning == true {
            menu.addItem(item("Stop the Incognito Task", #selector(stopIncognitoTask)))
        }
        menu.addItem(item(incognito.isOpen ? "Show Incognito Window" : "Open Incognito Window", #selector(openIncognito)))
        menu.addItem(.separator())

        switch session.modelAccess == .gateway ? nil : session.signInState {
        case nil:
            menu.addItem(disabledItem("Models through inference-gateway"))
        case .signedIn:
            menu.addItem(disabledItem("Signed in with ChatGPT"))
            menu.addItem(item("Sign Out", #selector(signOut)))
        case .signingIn:
            menu.addItem(disabledItem("Waiting for the browser…"))
            menu.addItem(item("Cancel Sign-in", #selector(cancelSignIn)))
        case .signedOut:
            menu.addItem(item("Sign in with ChatGPT…", #selector(signIn)))
        }

        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        let models = NSMenu()
        let current = ModelSetting.effective()
        let choices = session.modelChoices(current: current)
        for model in choices.models where model.id != current || !choices.currentIsUnlisted {
            let entry = item(model.name, #selector(chooseModel(_:)))
            entry.representedObject = model.id
            entry.state = model.id == current ? .on : .off
            models.addItem(entry)
        }
        if choices.currentIsUnlisted {
            let custom = disabledItem("\(choices.models.last?.name ?? current), not in your account's list")
            custom.state = .on
            models.addItem(custom)
        }
        var listed = choices.models.map(\.id)
        if Experiment.localModelsThroughOllama.isOn() {
            models.addItem(.separator())
            let local = localModels.models
            if local.isEmpty { models.addItem(disabledItem("No models in Ollama")) }
            for name in local {
                let id = Ollama.modelID(name)
                let entry = item(Ollama.displayName(name), #selector(chooseModel(_:)))
                entry.representedObject = id
                entry.state = id == current ? .on : .off
                models.addItem(entry)
                listed.append(id)
            }
        }
        if !listed.contains(current) {
            let custom = disabledItem(current)
            custom.state = .on
            models.addItem(custom)
        }
        modelItem.submenu = models
        menu.addItem(modelItem)

        menu.addItem(.separator())
        let settingsItem = item("Settings…", #selector(openSettings(_:)))
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        menu.addItem(item("Show Thread in Finder", #selector(showThread)))
        // Only a release build has a feed. A development build never updates itself, so it
        // has no item.
        if updater.isAvailable {
            menu.addItem(updater.canCheck
                ? item(AppUpdater.checkTitle, #selector(checkForUpdates))
                : disabledItem(AppUpdater.checkTitle))
        }
        menu.addItem(NSMenuItem(title: "Quit mac-os-agent", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// From the menu, which takes keyboard focus while it is open, so the panel is never key
    /// here: a presented panel hides and a hidden one, or one sliding out, shows.
    @objc private func togglePanel() {
        panel.toggleFromMenu()
    }
    @objc func openSettings(_ sender: Any?) { settings.show() }
    @objc private func stopTask() { session.stop() }

    @objc private func stopIncognitoTask() { incognito.session?.stop() }

    /// Opens the incognito window beside the main panel, or brings it forward. The main panel
    /// stays as it is.
    @objc private func openIncognito() {
        incognito.open()
    }
    @objc private func checkForUpdates() { updater.checkForUpdates() }
    @objc private func signIn() { session.signIn() }
    @objc private func cancelSignIn() { session.cancelSignIn() }
    @objc private func signOut() { session.signOut() }

    @objc private func chooseModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        ModelSetting.set(id)
    }

    @objc private func showThread() {
        let file = AgentPaths.threadFile
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            NSWorkspace.shared.open(AgentPaths.applicationSupport)
        }
    }
}
