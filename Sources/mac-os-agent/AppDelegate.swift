import AppKit
import MacOSAgentCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var session: AgentSession!
    private var panel: SummonPanel!
    private var hotKey: SummonHotKey!
    private var hotKeyRegistered = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let installationID = AgentPaths.installationID()
        let authenticator = ChatGPTAuthenticator(installationID: installationID)
        var loop: AgentLoop?
        var startupError: Error?
        do {
            let thread = try ThreadStore(fileURL: AgentPaths.threadFile)
            let provider = OpenAIResponsesProvider(
                authenticator: authenticator,
                model: { ModelSetting.current() },
                promptCacheKey: "mac-os-agent-\(installationID.uuidString.lowercased())")
            loop = AgentLoop(provider: provider, thread: thread, tools: [ShellCommandTool()])
        } catch {
            startupError = error
        }

        session = AgentSession(loop: loop, authenticator: authenticator)
        session.onStatusChange = { [weak self] in self?.updateStatusIcon() }
        panel = SummonPanel(session: session)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusIcon()

        hotKey = SummonHotKey { [weak self] in self?.panel.toggle() }
        hotKeyRegistered = hotKey.register()

        Task { await session.start() }

        if let startupError {
            let alert = NSAlert()
            alert.messageText = "mac-os-agent could not open its thread"
            alert.informativeText = "\(AgentPaths.threadFile.path)\n\(startupError.localizedDescription)"
            NSApp.activate()
            alert.runModal()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKey?.unregister()
    }

    private func updateStatusIcon() {
        let symbol: String
        let description: String
        if session.pendingConfirmation != nil {
            symbol = "hand.raised.fill"
            description = "mac-os-agent is waiting for your go-ahead"
        } else if session.isRunning {
            symbol = "sparkle.magnifyingglass"
            description = "mac-os-agent is working"
        } else {
            symbol = "sparkle"
            description = "mac-os-agent"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = description
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let open = NSMenuItem(title: "Open mac-os-agent", action: #selector(openPanel), keyEquivalent: SummonShortcut.keyEquivalent)
        open.keyEquivalentModifierMask = SummonShortcut.modifierFlags
        open.target = self
        menu.addItem(open)
        if !hotKeyRegistered {
            menu.addItem(disabledItem("\(SummonShortcut.displayName) is taken by another app"))
        }
        if session.isRunning {
            menu.addItem(item("Stop the Current Task", #selector(stopTask)))
        }
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

    @objc private func openPanel() { panel.summon() }
    @objc private func stopTask() { session.stop() }
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
