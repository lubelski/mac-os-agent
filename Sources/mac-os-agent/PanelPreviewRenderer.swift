import AppKit
import MacOSAgentCore
import SwiftUI

/// Renders the panel with stand-in data, without showing a window.
@MainActor
enum PanelPreviewRenderer {
    static func render(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let states: [(String, AgentSession)] = [
            ("empty", AgentSession(previewRows: [])),
            ("running", AgentSession(
                previewRows: [
                    ExchangeRow(id: "1", kind: .user("change the wallpaper to a sunset")),
                    ExchangeRow(id: "2", kind: .tool(
                        command: "mdfind -onlyin /System/Library/Desktop\\ Pictures 'kMDItemDisplayName == \"*Sunset*\"c'",
                        status: .finished,
                        output: "/System/Library/Desktop Pictures/Sunset.heic\n[exit status 0]")),
                    ExchangeRow(id: "3", kind: .tool(
                        command: "osascript -e 'tell application \"System Events\" to tell every desktop to set picture to \"/System/Library/Desktop Pictures/Sunset.heic\"'",
                        status: .running,
                        output: nil)),
                ],
                isRunning: true)),
            ("confirmation", AgentSession(
                previewRows: [
                    ExchangeRow(id: "1", kind: .user("delete zoom")),
                    ExchangeRow(id: "2", kind: .tool(
                        command: "mdfind \"kMDItemCFBundleIdentifier == 'us.zoom.xos'\"",
                        status: .finished,
                        output: "/Applications/zoom.us.app\n[exit status 0]")),
                    ExchangeRow(id: "3", kind: .tool(
                        command: "osascript -e 'tell application \"Finder\" to delete POSIX file \"/Applications/zoom.us.app\"'",
                        status: .waitingForConfirmation,
                        output: nil)),
                ],
                pendingConfirmation: ConfirmationRequest(
                    callID: "3",
                    command: "osascript -e 'tell application \"Finder\" to delete POSIX file \"/Applications/zoom.us.app\"'",
                    reason: "scripts an app to delete or quit"),
                isRunning: true)),
            ("finished", AgentSession(previewRows: [
                ExchangeRow(id: "1", kind: .user("change the wallpaper to a sunset")),
                ExchangeRow(id: "2", kind: .tool(
                    command: "osascript -e 'tell application \"System Events\" to tell every desktop to set picture to \"/System/Library/Desktop Pictures/Sunset.heic\"'",
                    status: .finished,
                    output: "[exit status 0]")),
                ExchangeRow(id: "3", kind: .assistant("Done. Every desktop now shows the Sunset picture from the system wallpapers.")),
            ])),
        ]
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            for (name, session) in states {
                let suffix = appearance == .darkAqua ? "dark" : "light"
                render(session, appearance: appearance, to: directory.appending(path: "panel-\(name)-\(suffix).png"))
            }
        }
    }

    private static func render(_ session: AgentSession, appearance: NSAppearance.Name, to url: URL) {
        let content = SummonView(session: session)
            .padding(40)
            .background(
                LinearGradient(
                    colors: appearance == .darkAqua
                        ? [Color(red: 0.16, green: 0.12, blue: 0.30), Color(red: 0.55, green: 0.25, blue: 0.20)]
                        : [Color(red: 0.55, green: 0.70, blue: 0.95), Color(red: 0.98, green: 0.75, blue: 0.55)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
        let host = NSHostingView(rootView: content)
        host.appearance = NSAppearance(named: appearance)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}
