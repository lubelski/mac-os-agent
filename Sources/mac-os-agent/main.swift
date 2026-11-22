import AppKit

let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--render-panel-previews"), index + 1 < arguments.count {
    // Draws the panel in a few stand-in states into PNG files and exits. Used for pull
    // request screenshots, since screen capture from an agent session often shows nothing.
    let directory = URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
    MainActor.assumeIsolated {
        NSApplication.shared.setActivationPolicy(.prohibited)
        PanelPreviewRenderer.render(into: directory)
    }
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
