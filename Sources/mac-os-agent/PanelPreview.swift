import AppKit
import MacOSAgentCore
import SwiftUI

/// Stand-in panel states for screenshots. `--preview-panel <name>` shows one of them in the
/// real panel instead of starting the agent. Screen capture of the window then shows it with
/// its Liquid Glass, which an offscreen render does not draw. Nothing here reads or writes the
/// real thread, the Keychain, or the panel's saved frame.
@MainActor
enum PanelPreview {
    static let names = [
        "empty", "running", "confirmation", "finished", "history", "draft", "multiline-draft",
        "fresh-start", "scrollback", "incognito", "command-hint", "tool-states", "first-message", "streaming",
        "fresh-start-slot", "markdown", "markdown-streaming", "markdown-code-streaming", "controls",
    ] + inspectorStates + InstantActionPreview.names

    /// The states that show the tool call inspector beside the panel, each open on one call.
    static let inspectorStates = [
        "inspector-json", "inspector-table", "inspector-diff", "inspector-long", "inspector-running", "inspector-fields",
    ]

    /// The call the inspector opens on for a state, or nil for a state without it.
    static func inspectedCall(named name: String) -> String? {
        inspectorStates.contains(name) ? "call_" + name.dropFirst("inspector-".count) : nil
    }

    /// A reply that uses most of what the panel draws from Markdown.
    static let markdownReply = """
        ## Disk use

        Movies is the **big one**. Caches are *safe* to clear, and ~~Downloads~~ is mostly installers. See [About Storage](https://support.apple.com/en-us/102624).

        | Folder | Size | Note |
        |:--|--:|:--|
        | `~/Movies` | 38 GB | Screen recordings from last spring, most of them over 2 GB each |
        | `~/Downloads` | 12 GB | Installers |
        | `~/Library/Caches` | 4.1 GB | Cleared by macOS when space runs low |

        To see the largest files yourself:

        ```sh
        du -sh ~/Movies/* | sort -hr | head -20
        ```

        1. Move recordings you want to keep to the external drive.
        2. Empty the Trash.
           - [x] Downloads checked
           - [ ] Caches left alone

        > Nothing was deleted.
        """

    static func session(named name: String) -> AgentSession? {
        if inspectorStates.contains(name) { return inspectorSession() }
        if let session = InstantActionPreview.session(named: name) { return session }
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
        case "fresh-start", "command-hint":
            // The panel summoned after the last episode timed out: an empty page, with the
            // earlier episodes above it.
            var thread = StandInThread(now: Date())
            thread.earlierExchanges()
            let session = AgentSession(previewEntries: thread.entries, freshStart: true)
            if name == "command-hint" { session.draft = "/" }
            return session
        case "scrollback":
            // The same history scrolled to its top, which shows the separators between episodes.
            var thread = StandInThread(now: Date())
            thread.earlierExchanges()
            let session = AgentSession(previewEntries: thread.entries, freshStart: true)
            session.previewStartsAtTop = true
            return session
        case "incognito":
            var thread = StandInThread(now: Date())
            thread.earlierExchanges()
            var incognito = StandInThread(now: Date())
            incognito.user("what's a good farewell gift for a coworker who loves hiking", minutesAgo: 1)
            incognito.reply("A packable rain shell or a national parks pass are both easy to give and get used a lot.")
            return AgentSession(previewEntries: thread.entries, incognitoEntries: incognito.entries)
        case "tool-states":
            // Every state a tool call row can be in, one after another.
            var thread = StandInThread(now: Date())
            thread.user("tidy up my desktop", minutesAgo: 1)
            thread.tool("ls -1 ~/Desktop | head -20", output: "Screenshot 2026-11-20.png\nReceipts\n[exit status 0]")
            thread.tool("mkdir ~/Desktop/Receipts", output: "mkdir: /Users/owner/Desktop/Receipts: File exists\n[exit status 1]")
            thread.tool("rm -rf ~/Desktop/Old\\ Screenshots", output: ShellCommandTool.declinedOutput)
            thread.tool("sleep 30 && open ~/Desktop", output: ShellCommandTool.stoppedBeforeRunningOutput)
            let running = thread.tool("mv ~/Desktop/*.png ~/Pictures/Screenshots/", output: nil)
            let waiting = thread.tool("osascript -e 'tell application \"Finder\" to empty trash'", output: nil)
            let preparing = thread.startedCall()
            let session = AgentSession(previewEntries: thread.entries, isRunning: true, runningCallIDs: [running])
            session.previewSetStatus(waiting, .waitingForConfirmation)
            session.previewToolStarted(preparing)
            return session
        case "first-message":
            // The first message of a new episode, with the reply on its way.
            var thread = StandInThread(now: Date())
            thread.earlierExchanges()
            thread.newEpisode(minutesAgo: 0.5)
            thread.user("what's my battery at", minutesAgo: 0.5)
            return AgentSession(previewEntries: thread.entries, isRunning: true)
        case "streaming":
            // A reply streaming in after a command.
            var thread = StandInThread(now: Date())
            thread.earlierExchanges()
            thread.newEpisode(minutesAgo: 0.5)
            thread.user("what's my battery at", minutesAgo: 0.5)
            thread.tool("pmset -g batt", output: "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1234)\t64%; discharging; 3:10 remaining present: true\n[exit status 0]")
            return AgentSession(previewEntries: thread.entries, streamingText: "It’s at 64% and discharging, with about 3 hours and 10 minutes", isRunning: true)
        case "fresh-start-slot":
            // A fresh page with stand-in blocks in the suggestion slot, to show how content lays out.
            var thread = StandInThread(now: Date())
            thread.earlierExchanges()
            let session = AgentSession(previewEntries: thread.entries, freshStart: true)
            session.previewFreshStartContent = ["Stand-in for slot content", "Stand-in for slot content, a second line"]
            return session
        case "markdown", "markdown-streaming":
            var thread = StandInThread(now: Date())
            thread.user("what's eating my disk space? give me a table", minutesAgo: 1)
            thread.tool("du -sh ~/Library/Caches ~/Downloads ~/Movies 2>/dev/null | sort -hr",
                        output: " 38G\t/Users/owner/Movies\n 12G\t/Users/owner/Downloads\n4.1G\t/Users/owner/Library/Caches\n[exit status 0]")
            if name == "markdown" {
                thread.reply(markdownReply)
                return AgentSession(previewEntries: thread.entries)
            }
            // Cut inside the table's second row and again inside the code block's fence, to show
            // how an unfinished reply renders while it streams.
            let cut = markdownReply.range(of: "| `~/Downloads` | 12")!.upperBound
            return AgentSession(previewEntries: thread.entries, streamingText: String(markdownReply[..<cut]), isRunning: true)
        case "controls":
            // The hover controls all shown at once, since a capture has no pointer.
            var thread = StandInThread(now: Date())
            thread.user("how do I see the biggest files", minutesAgo: 1)
            let start = markdownReply.range(of: "To see the largest")!.lowerBound
            let end = markdownReply.range(of: "1. Move")!.lowerBound
            thread.reply(String(markdownReply[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines))
            let session = AgentSession(previewEntries: thread.entries)
            session.previewRevealsControls = true
            return session
        case "markdown-code-streaming":
            var thread = StandInThread(now: Date())
            thread.user("how do I see the biggest files", minutesAgo: 1)
            let cut = markdownReply.range(of: "du -sh ~/Movies/* | sort")!.upperBound
            let start = markdownReply.range(of: "To see the largest")!.lowerBound
            return AgentSession(previewEntries: thread.entries, streamingText: String(markdownReply[start..<cut]), isRunning: true)
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

    /// One episode with a call of each kind the inspector lays out, the last one still running.
    private static func inspectorSession() -> AgentSession {
        var thread = StandInThread(now: Date())
        thread.earlierExchanges()
        thread.user("what's using the network, and is my reminders list in order", minutesAgo: 3)
        let details = { (seconds: Double, status: Int32?) in
            ToolRunDetails(started: Date().addingTimeInterval(-170), seconds: seconds, source: "Built In", exitStatus: status)
        }
        thread.call("call_json", name: ShellCommandTool.name,
                    arguments: ["command": "curl -s https://api.github.com/repos/apple/swift | jq '{name, stars: .stargazers_count, topics, license: .license.spdx_id, owner: {login: .owner.login, type: .owner.type}}'", "destructive": false],
                    output: """
                        {"name":"swift","stars":69120,"topics":["swift","compiler","language"],"license":"Apache-2.0","owner":{"login":"apple","type":"Organization"},"archived":false,"default_branch":"main","size_kb":1048576}
                        [exit status 0]
                        """, details: details(0.62, 0))
        thread.call("call_table", name: ShellCommandTool.name,
                    arguments: ["command": "lsof -nP -iTCP -sTCP:ESTABLISHED | head -8", "destructive": false],
                    output: """
                        COMMAND     PID  USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
                        Safari      812 owner   23u  IPv4 0x8f2a1c3e9b0d4f11      0t0  TCP 192.168.1.20:51234->17.253.144.10:443 (ESTABLISHED)
                        Mail        901 owner   41u  IPv6 0x8f2a1c3e9b0d5a22      0t0  TCP [2600::1]:51240->[2620:149::1]:993 (ESTABLISHED)
                        Slack      1022 owner   88u  IPv4 0x8f2a1c3e9b0d6b33      0t0  TCP 192.168.1.20:51301->52.4.21.9:443 (ESTABLISHED)
                        Dropbox    1188 owner   12u  IPv4 0x8f2a1c3e9b0d7c44      0t0  TCP 192.168.1.20:51320->162.125.6.18:443 (ESTABLISHED)
                        [exit status 0]
                        """, details: details(0.21, 0))
        thread.call("call_diff", name: ShellCommandTool.name,
                    arguments: ["command": "git -C ~/Documents/notes diff --stat --patch HEAD~1 -- groceries.md", "destructive": false],
                    output: """
                        diff --git a/groceries.md b/groceries.md
                        index 3b18e51..a9c2f04 100644
                        --- a/groceries.md
                        +++ b/groceries.md
                        @@ -1,6 +1,7 @@
                         # Groceries

                         - oat milk
                        -- eggs
                        +- eggs, a dozen, free range
                        +- coffee beans
                         - spinach
                         - lemons
                        [exit status 0]
                        """, details: details(0.05, 0))
        let long = (1...400).map { index in
            "2026-11-21 09:\(String(format: "%02d", index % 60)):\(String(format: "%02d", (index * 7) % 60)).\(String(format: "%03d", index * 13 % 1000)) mDNSResponder[\(400 + index % 9)]: [R\(index)] DNSServiceQueryRecord(example\(index % 17).local, Addr) START, the reply cache has \(index * 3) entries and is \(index % 100) percent full"
        }.joined(separator: "\n")
        thread.call("call_long", name: ShellCommandTool.name,
                    arguments: ["command": "log show --last 5m --predicate 'process == \"mDNSResponder\"' --style compact", "destructive": false],
                    output: long + "\n[exit status 0]", details: details(3.4, 0))
        thread.call("call_fields", name: "change_reminders",
                    arguments: ["changes": [
                        ["id": "3f9a2c1b", "title": nil, "completed": true, "due": nil, "list": nil, "notes": nil, "priority": nil, "delete": nil],
                        ["id": nil, "title": "Water the plants", "completed": nil, "due": "2026-11-22T08:30", "list": "Reminders", "notes": "The fern by the window too", "priority": "high", "delete": nil],
                    ]],
                    output: "Completed \"Buy milk\" in Groceries.\nCreated 9b04e1aa | Water the plants | Reminders | due Sun 2026-11-22 08:30 | high priority",
                    details: ToolRunDetails(started: Date().addingTimeInterval(-60), seconds: 4.1, waitedSeconds: 3.8, goAhead: .approved, source: "Reminders"))
        thread.call("call_running", name: ShellCommandTool.name,
                    arguments: ["command": "softwareupdate --list --all 2>&1 | tee ~/Desktop/updates.txt", "destructive": false],
                    output: nil, details: nil)
        let session = AgentSession(previewEntries: thread.entries, isRunning: true, runningCallIDs: ["call_running"])
        session.toolSources = [ShellCommandTool.name: "Built In", "change_reminders": "Reminders"]
        return session
    }

    /// Builds stand-in thread entries with send times relative to now.
    struct StandInThread {
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

        /// A call to any tool, with its result and run details when given.
        mutating func call(_ callID: String, name: String, arguments: JSONValue, output: String?, details: ToolRunDetails?) {
            entries.append(ThreadEntry(date: tick(), item: .toolCall(.init(
                callID: callID, name: name, arguments: arguments.encodedString(), provider: "openai", model: "gpt-6-luna"))))
            if let output {
                entries.append(ThreadEntry(date: tick(), item: .toolResult(.init(callID: callID, output: output, details: details))))
            }
        }

        /// A call the model has begun, whose arguments have not arrived.
        mutating func startedCall() -> String {
            let callID = "call_\(nextCall)"
            nextCall += 1
            return callID
        }

        mutating func newEpisode(minutesAgo: Double) {
            entries.append(ThreadEntry(date: now.addingTimeInterval(-minutesAgo * 60), item: .episodeStart(.init(reason: .timeout))))
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

    /// Slides the panel out and back in on a schedule, for a recording of the motion: out, in,
    /// then out again with a summon halfway, which turns it around, and out once more.
    static func cycleSlides(of panel: SummonPanel) {
        let slide = PanelSlide.slideDuration * panel.slideTimeScale
        var time = slide + 0.7
        func at(_ delay: Double, _ action: @escaping @MainActor (SummonPanel) -> Void) {
            time += delay
            Timer.scheduledTimer(withTimeInterval: time, repeats: false) { [weak panel] _ in
                MainActor.assumeIsolated {
                    if let panel { action(panel) }
                }
            }
        }
        at(0) { $0.dismiss() }
        at(slide + 0.4) { $0.showForPreview() }
        at(slide + 0.7) { $0.dismiss() }
        at(slide * 0.5) { $0.showForPreview() }
        at(slide + 0.7) { $0.dismiss() }
    }

    /// For checking the glass's edges: shows a busy page behind the panel and prints the rect to
    /// capture, in screen coordinates with the origin at the top left, as
    /// `capture-rect x,y,width,height`.
    static func showBackdrop(behind panel: NSPanel, dark: Bool) {
        let margin: CGFloat = 24
        // The panel and any window attached to it, such as the inspector.
        let covered = (panel.childWindows ?? []).filter(\.isVisible).reduce(panel.frame) { $0.union($1.frame) }
        let frame = covered.insetBy(dx: -margin, dy: -margin)
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
