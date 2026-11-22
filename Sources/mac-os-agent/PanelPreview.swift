import AppKit
import MacOSAgentCore
import SwiftUI

/// Stand-in panel states for screenshots. `--preview-panel <name>` shows one of them in the
/// real panel instead of starting the agent. Screen capture of the window then shows it with
/// its Liquid Glass, which an offscreen render does not draw. Nothing here reads or writes the
/// real thread, the Keychain, or the panel's saved frame.
@MainActor
enum PanelPreview {
    static let names = ["empty", "running", "confirmation", "finished", "history", "draft", "multiline-draft"]

    static func session(named name: String) -> AgentSession? {
        switch name {
        case "empty":
            return AgentSession(previewEntries: [])
        case "running":
            var thread = StandInThread(now: Date())
            thread.earlierExchanges()
            thread.user("change the wallpaper to a sunset", minutesAgo: 1)
            thread.tool("mdfind -onlyin /System/Library/Desktop\\ Pictures 'kMDItemDisplayName == \"*Sunset*\"c'",
                        output: "/System/Library/Desktop Pictures/Sunset.heic\n[exit status 0]")
            let running = thread.tool("osascript -e 'tell application \"System Events\" to tell every desktop to set picture to \"/System/Library/Desktop Pictures/Sunset.heic\"'", output: nil)
            return AgentSession(previewEntries: thread.entries, isRunning: true, runningCallIDs: [running])
        case "confirmation":
            var thread = StandInThread(now: Date())
            thread.earlierExchanges()
            thread.user("delete zoom", minutesAgo: 1)
            thread.tool("mdfind \"kMDItemCFBundleIdentifier == 'us.zoom.xos'\"", output: "/Applications/zoom.us.app\n[exit status 0]")
            let command = "osascript -e 'tell application \"Finder\" to delete POSIX file \"/Applications/zoom.us.app\"'"
            let waiting = thread.tool(command, output: nil)
            return AgentSession(
                previewEntries: thread.entries,
                pendingConfirmation: ConfirmationRequest(callID: waiting, command: command, reason: "scripts an app to delete or quit"),
                isRunning: true)
        case "draft", "multiline-draft":
            var thread = StandInThread(now: Date())
            thread.earlierExchanges()
            let session = AgentSession(previewEntries: thread.entries)
            session.draft = name == "draft"
                ? "find the screenshot I took this morning"
                : "make a folder on the desktop called Receipts\nmove every PDF from Downloads with “receipt” in its name into it\nthen open the folder in Finder\nand tell me how many you moved"
            return session
        case "finished":
            var thread = StandInThread(now: Date())
            thread.user("change the wallpaper to a sunset", minutesAgo: 2)
            thread.tool("osascript -e 'tell application \"System Events\" to tell every desktop to set picture to \"/System/Library/Desktop Pictures/Sunset.heic\"'",
                        output: "[exit status 0]")
            thread.reply("Done. Every desktop now shows the Sunset picture from the system wallpapers.")
            return AgentSession(previewEntries: thread.entries)
        case "history":
            var thread = StandInThread(now: Date())
            thread.earlierExchanges()
            thread.user("open notion", minutesAgo: 6)
            thread.tool("mdfind 'kMDItemCFBundleIdentifier == \"notion.id\"' ; ls -d /Applications/Notion.app \"$HOME/Applications/Notion.app\" 2>/dev/null",
                        output: "ls: /Applications/Notion.app: No such file or directory\n[exit status 1]")
            thread.tool("mdfind 'kMDItemFSName == \"*Notion*.app\"cd'", output: "[exit status 0]")
            thread.tool("brew list --cask 2>/dev/null | grep -i notion", output: "[exit status 1]")
            thread.tool("open https://www.notion.so", output: "[exit status 0]")
            thread.reply("I couldn’t find the Notion app, so I opened Notion in your browser.")
            thread.user("ok install it with brew then", minutesAgo: 4)
            thread.tool("brew install --cask notion", output: "==> Downloading https://desktop-release.notion-static.com/Notion-4.12.0-arm64.dmg\n==> Installing Cask notion\n==> Moving App 'Notion.app' to '/Applications/Notion.app'\nnotion was successfully installed!\n[exit status 0]")
            thread.tool("open -a Notion", output: "[exit status 0]")
            thread.reply("Installed Notion 4.12 with Homebrew and opened it. It’s in `/Applications` now, so next time it will open directly.")
            return AgentSession(previewEntries: thread.entries)
        default:
            return nil
        }
    }

    /// Builds stand-in thread entries with send times relative to now.
    private struct StandInThread {
        let now: Date
        var entries: [ThreadEntry] = []
        private var clock: Date
        private var nextCall = 1

        init(now: Date) {
            self.now = now
            clock = now
        }

        mutating func user(_ text: String, minutesAgo: Double) {
            clock = now.addingTimeInterval(-minutesAgo * 60)
            entries.append(ThreadEntry(date: clock, item: .userMessage(text: text)))
        }

        @discardableResult
        mutating func tool(_ command: String, output: String?) -> String {
            let callID = "call_\(nextCall)"
            nextCall += 1
            let arguments: JSONValue = ["command": .string(command), "destructive": false]
            entries.append(ThreadEntry(date: tick(), item: .toolCall(.init(
                callID: callID, name: "run_shell_command", arguments: arguments.encodedString(),
                provider: "openai", model: "gpt-6-luna"))))
            if let output {
                entries.append(ThreadEntry(date: tick(), item: .toolResult(.init(callID: callID, output: output))))
            }
            return callID
        }

        mutating func reply(_ text: String) {
            entries.append(ThreadEntry(date: tick(), item: .assistantMessage(.init(text: text, provider: "openai", model: "gpt-6-luna"))))
        }

        private mutating func tick() -> Date {
            clock = clock.addingTimeInterval(2)
            return clock
        }

        /// A few exchanges from the past days, so the panel shows a thread with history.
        mutating func earlierExchanges() {
            user("what's eating my disk space", minutesAgo: 3 * 24 * 60 + 40)
            tool("du -sh ~/Library/Caches ~/Downloads ~/Movies 2>/dev/null | sort -hr",
                 output: " 38G\t/Users/owner/Movies\n 12G\t/Users/owner/Downloads\n4.1G\t/Users/owner/Library/Caches\n[exit status 0]")
            reply("Movies is the big one at 38 GB, then Downloads at 12 GB. Caches are 4.1 GB, and macOS clears those on its own when space runs low.")
            user("turn on dark mode", minutesAgo: 26 * 60)
            tool("osascript -e 'tell application \"System Events\" to tell appearance preferences to set dark mode to true'", output: "[exit status 0]")
            reply("Dark mode is on.")
            user("how long until my battery is full", minutesAgo: 95)
            tool("pmset -g batt", output: "Now drawing from 'AC Power'\n -InternalBattery-0 (id=1234)\t81%; charging; 0:42 remaining present: true\n[exit status 0]")
            reply("About 42 minutes. It’s at 81% and charging.")
        }
    }

    /// For checking the glass's edges: shows a busy page behind the panel and prints the rect to
    /// capture, in screen coordinates with the origin at the top left, as
    /// `capture-rect x,y,width,height`.
    static func showBackdrop(behind panel: NSPanel, dark: Bool) {
        let margin: CGFloat = 24
        let frame = panel.frame.insetBy(dx: -margin, dy: -margin)
        let backdrop = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        backdrop.ignoresMouseEvents = true
        backdrop.isReleasedWhenClosed = false
        backdrop.contentView = NSHostingView(rootView: BackdropPage(dark: dark))
        backdrop.orderFront(nil)
        panel.orderFront(nil)

        let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.maxY
        print("capture-rect \(Int(frame.minX)),\(Int(primaryHeight - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))")
        fflush(stdout)
    }
}

/// A plain document page, white or dark, with lines of text and a few colored blocks.
private struct BackdropPage: View {
    let dark: Bool

    var body: some View {
        let ink: Color = dark ? .white.opacity(0.75) : .black.opacity(0.8)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<48, id: \.self) { line in
                HStack(spacing: 10) {
                    Text("Line \(line + 1): the quick brown fox jumps over the lazy dog, and the lazy dog does not mind at all.")
                        .font(.system(size: 13))
                        .foregroundStyle(ink)
                        .lineLimit(1)
                    if line % 7 == 3 {
                        RoundedRectangle(cornerRadius: 4).fill(.blue.opacity(0.7)).frame(width: 80, height: 14)
                    }
                    if line % 9 == 5 {
                        RoundedRectangle(cornerRadius: 4).fill(.orange.opacity(0.8)).frame(width: 60, height: 14)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(dark ? Color(white: 0.12) : .white)
    }
}
