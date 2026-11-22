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
        if let index = arguments.firstIndex(of: "--appearance"), index + 1 < arguments.count {
            app.appearance = NSAppearance(named: arguments[index + 1] == "light" ? .aqua : .darkAqua)
        }
        let panel = SummonPanel(session: session)
        panel.summon()
        app.run()
        return
    }

    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
