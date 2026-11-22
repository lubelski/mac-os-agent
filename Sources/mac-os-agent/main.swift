import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let arguments = CommandLine.arguments
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
        let panel = SummonPanel(session: session, remembersFrame: false)
        panel.summon()
        if arguments.contains("--backdrop") {
            PanelPreview.showBackdrop(behind: panel, dark: dark)
        }
        app.run()
        return
    }

    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
