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
    private let prompt = AgentPrompt()
    private let usageLog = UsageLog()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let installationID = AgentPaths.installationID()
        let authenticator = ChatGPTAuthenticator(installationID: installationID)
        var loop: AgentLoop?
        var startupError: Error?
        var thread: ThreadStore?
        do {
            thread = try ThreadStore(fileURL: AgentPaths.threadFile, searchIndexURL: AgentPaths.historyIndexFile)
        } catch {
            startupError = error
        }
        // Built once, so the tool list stays the same for the whole run, and shared with Settings.
        let tools = ToolRegistry(builtIn: BuiltInTools.make(skills: prompt.skills, history: thread))
        if let thread {
            let provider = OpenAIResponsesProvider(
                authenticator: authenticator,
                model: { ModelSetting.current() },
                promptCacheKey: "mac-os-agent-\(installationID.uuidString.lowercased())")
            let prompt = prompt
            let usageLog = usageLog
            let timeout: @Sendable () -> TimeInterval = { EpisodeTimeoutSetting.current() }
            loop = AgentLoop(
                provider: provider, thread: thread,
                tools: tools.tools,
                instructions: { prompt.current() },
                usageLog: usageLog,
                episodeTimeout: timeout)
        }
        // The incognito window has a provider of its own with its own cache key, so its
        // requests, with their own instructions and tools, are a separate cached prefix.
        let incognitoProvider = OpenAIResponsesProvider(
            authenticator: authenticator,
            model: { ModelSetting.current() },
            promptCacheKey: "mac-os-agent-incognito-\(installationID.uuidString.lowercased())")
        let makeIncognitoLoop = { [prompt = self.prompt, usageLog = self.usageLog] in
            IncognitoWindowController.makeLoop(provider: incognitoProvider, prompt: prompt, usageLog: usageLog)
        }

        session = AgentSession(loop: loop, authenticator: authenticator)
        session.onStatusChange = { [weak self] in self?.statusDidChange() }
        session.toolSources = tools.sourceTitles
        session.instantActions = .live()
        panel = SummonPanel(session: session)

        incognito = IncognitoWindowController(makeSession: { [weak self] in
            let incognito = AgentSession(incognito: makeIncognitoLoop, signedIn: self?.session.signInState == .signedIn)
            if let main = self?.session {
                incognito.toolSources = main.toolSources
                incognito.instantActions = main.instantActions.incognitoCopy()
            }
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
        if let startupError {
            session.problems.record("Startup", "Could not open the thread: \(startupError.localizedDescription)")
        }
        settings = SettingsWindowController(
            session: session, prompt: prompt, usageLog: usageLog, tools: tools, history: thread, problems: session.problems,
            signInStatus: { await authenticator.status() },
            summonTrigger: summonTrigger)
        log.notice("Hotkey \(self.summonTrigger.displayName ?? "none", privacy: .public) registered: \(self.summonTrigger.isRegistered, privacy: .public). Status item button: \(self.statusItem.button != nil, privacy: .public)")

        Task { await session.start() }

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
    }

    // MARK: - Menu

    @objc private func statusItemPressed(_ sender: Any?) {
        switch StatusItemClick.action(for: NSApp.currentEvent) {
        case .togglePanel: panel.toggle()
        case .showMenu: statusItem.showMenu(statusMenu)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
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

        switch session.signInState {
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
        let current = ModelSetting.current()
        for model in OpenAIModel.all {
            let entry = item(model.name, #selector(chooseModel(_:)))
            entry.representedObject = model.id
            entry.state = model.id == current ? .on : .off
            models.addItem(entry)
        }
        if !OpenAIModel.all.contains(where: { $0.id == current }) {
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
