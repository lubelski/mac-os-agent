import AppKit
import MacOSAgentCore

MainActor.assumeIsolated {
    let app = NSApplication.shared
    // A render never shows anything: no Dock icon, no menu bar, no activation.
    app.setActivationPolicy(PreviewRender.isRendering ? .prohibited : .accessory)

    MainMenu.install()
    let arguments = CommandLine.arguments
    if arguments.contains(MCPServerCheck.argument) {
        // Starts the MCP servers in the data folder, reports to standard output and to
        // mcp-check.txt there, and quits. Only with --data-folder, so it never starts the
        // owner's own servers.
        guard arguments.contains(AgentPaths.dataFolderArgument) else {
            print("\(MCPServerCheck.argument) needs \(AgentPaths.dataFolderArgument) <folder>.")
            exit(2)
        }
        Task.detached {
            let report = await MCPServerCheck.run()
            print(report)
            try? report.write(to: AgentPaths.applicationSupport.appending(path: "mcp-check.txt"), atomically: true, encoding: .utf8)
            exit(0)
        }
        app.run()
        return
    }
    if arguments.contains("--preview-settings") || arguments.contains("--preview-panel") {
        // Previews keep their theme choices in preferences of their own, never the owner's.
        // `--preview-theme <id>` shows a theme without saving it, and `--preview-glass off`
        // shows the panel as it draws with Use Glass off. `--preview-message-layout full-width`
        // shows the full width message layout without saving it.
        // Without --data-folder, a preview reads an empty temporary themes folder, never the real one.
        let folder = arguments.contains(AgentPaths.dataFolderArgument)
            ? AgentPaths.themesFolder
            : FileManager.default.temporaryDirectory.appending(path: "mac-os-agent-preview-themes", directoryHint: .isDirectory)
        let model = ThemeModel(
            library: ThemeLibrary(folder: folder),
            preferences: ThemePreferences(suiteName: "dev.lubelski.mac-os-agent.preview"))
        if let index = arguments.firstIndex(of: "--preview-theme"), index + 1 < arguments.count {
            model.previewOverride = model.entries.first { $0.id == arguments[index + 1] }?.theme
        }
        if let index = arguments.firstIndex(of: "--preview-glass"), index + 1 < arguments.count {
            model.previewUsesGlass = arguments[index + 1] != "off"
        }
        if let index = arguments.firstIndex(of: "--preview-message-layout"), index + 1 < arguments.count {
            model.previewMessageLayout = arguments[index + 1] == "full-width" ? .fullWidth : .sides
        }
        ThemeModel.shared = model
    }
    if let index = arguments.firstIndex(of: "--preview-settings"), index + 1 < arguments.count,
       let section = SettingsSection(rawValue: arguments[index + 1])
    {
        // Shows the Settings window with a stand-in session and nothing else, for pull request
        // screenshots. Pass --data-folder too, so its files are not the real ones.
        if let index = arguments.firstIndex(of: "--appearance"), index + 1 < arguments.count {
            app.appearance = NSAppearance(named: arguments[index + 1] == "light" ? .aqua : .darkAqua)
        }
        var item: String?
        if let index = arguments.firstIndex(of: "--preview-item"), index + 1 < arguments.count {
            item = arguments[index + 1]
        }
        SettingsPreview.show(section, item: item)
        app.run()
        return
    }
    if let index = arguments.firstIndex(of: "--preview-panel"), index + 1 < arguments.count,
       let session = PanelPreview.session(named: arguments[index + 1])
    {
        // Shows the panel with stand-in data and nothing else: no menu bar item, no hotkey,
        // no thread, no sign-in. Used for pull request screenshots.
        var dark = true
        if let index = arguments.firstIndex(of: "--appearance"), index + 1 < arguments.count {
            dark = arguments[index + 1] != "light"
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        }
        let name = arguments[index + 1]
        // A render draws one window, so states made of two windows are captured instead.
        if PreviewRender.isRendering, name == "incognito-beside" || PanelPreview.inspectedCall(named: name) != nil
            || arguments.contains("--backdrop") || arguments.contains("--preview-slide-cycle")
        {
            FileHandle.standardError.write(Data("render: \(name) needs two windows or motion. Use scripts/capture-panel-previews.sh.\n".utf8))
            exit(2)
        }
        let panel = SummonPanel(session: session, role: PanelPreview.role(named: name), remembersFrame: false)
        // `incognito-beside` shows the main panel as well, with the incognito window placed
        // beside it the way it opens.
        var mainPanel: SummonPanel?
        if name == "incognito-beside", let history = PanelPreview.session(named: "history") {
            let main = SummonPanel(session: history, remembersFrame: false)
            main.showForPreview()
            panel.mainPanelFrame = { [weak main] in main?.placedFrame }
            mainPanel = main
        }
        // `--preview-reduce-motion` fades instead of sliding, as with Reduce Motion on.
        if arguments.contains("--preview-reduce-motion") {
            panel.reduceMotion = { true }
        }
        // `--panel-size 480x360` shows the panel as if the owner had resized it.
        if let index = arguments.firstIndex(of: "--panel-size"), index + 1 < arguments.count {
            let parts = arguments[index + 1].split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 { panel.setContentSize(NSSize(width: parts[0], height: parts[1])) }
        }
        // `--preview-preset slideOverRight` shows the panel in that layout. A slide over
        // panel slides in from its edge. `--preview-slide-scale 4` slows each slide down by
        // that factor, and `--preview-slide-cycle` slides it out and back in a few times, with
        // one summon during a slide out, to show the motion and its interruption.
        if let index = arguments.firstIndex(of: "--preview-preset"), index + 1 < arguments.count,
           let preset = PanelPreset(rawValue: arguments[index + 1])
        {
            panel.choose(preset)
        }
        if let index = arguments.firstIndex(of: "--preview-slide-scale"), index + 1 < arguments.count,
           let value = Double(arguments[index + 1])
        {
            panel.slideTimeScale = value
        }
        if arguments.contains("--preview-slide-cycle") {
            PanelPreview.cycleSlides(of: panel)
        }
        // The preview never takes keyboard focus from the app the owner is using, and it quits
        // on its own after a few seconds, so a failed capture script cannot leave it on screen.
        panel.showForPreview()
        // An inspector state opens the inspector on its call, beside the panel.
        if let callID = PanelPreview.inspectedCall(named: arguments[index + 1]) {
            panel.inspector.open(callID)
        }
        if arguments.contains("--backdrop") {
            if PanelWithBarsPreview.opensBelow(name) {
                // The match card's window is placed once the panel has laid out the pill, so
                // the backdrop waits for it, to cover both windows.
                Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { _ in
                    MainActor.assumeIsolated { PanelPreview.showBackdrop(behind: panel, dark: dark) }
                }
            } else {
                PanelPreview.showBackdrop(behind: panel, dark: dark)
            }
        }
        if let mainPanel {
            // The capture covers both windows.
            let both = mainPanel.frame.union(panel.frame)
            let primaryHeight = NSScreen.screens.first?.frame.height ?? both.maxY
            print("capture-rect \(Int(both.minX)),\(Int(primaryHeight - both.maxY)),\(Int(both.width)),\(Int(both.height))")
            fflush(stdout)
        }
        var seconds = 4.0
        if let index = arguments.firstIndex(of: "--preview-seconds"), index + 1 < arguments.count,
           let value = Double(arguments[index + 1])
        {
            seconds = value
        }
        Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in exit(0) }
        app.run()
        return
    }

    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
