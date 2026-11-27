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
        "fresh-start", "scrollback", "command-hint", "tool-states", "first-message", "streaming",
        "fresh-start-slot", "markdown", "markdown-streaming", "markdown-code-streaming", "controls", "links",
    ] + goAheadStates + incognitoStates + inspectorStates + InstantActionPreview.names + FooterPreview.names
        + PanelWithBarsPreview.names + ImagePreview.names

    /// The states shown in the incognito window rather than the main panel. `incognito-beside`
    /// shows the main panel too, with the incognito window beside it.
    static let incognitoStates = [
        "incognito", "incognito-empty", "incognito-closing", "incognito-command-hint", "incognito-beside",
    ]

    /// Which window a state is shown in.
    static func role(named name: String) -> SummonPanel.Role {
        incognitoStates.contains(name) || name == "footer-incognito" ? .incognito : .main
    }

    /// The go-ahead card for each tool that asks, beside the shell tool's `confirmation`.
    static let goAheadStates = [
        "confirmation-reminders", "confirmation-events", "confirmation-quit", "confirmation-theme", "confirmation-mcp",
        "confirmation-settings-server", "confirmation-settings-experiment",
    ]

    /// The states that show the tool call inspector beside the panel, each open on one call.
    static let inspectorStates = [
        "inspector-json", "inspector-table", "inspector-diff", "inspector-long", "inspector-running", "inspector-fields",
    ]

    /// The call the inspector opens on for a state, or nil for a state without it.
    static func inspectedCall(named name: String) -> String? {
        inspectorStates.contains(name) ? "call_" + name.dropFirst("inspector-".count) : nil
    }

    /// A reply with links in each place a reply draws inline text, all to placeholder addresses.
    static let linksReply = """
        The [setup guide](https://example.com/guide) covers it, and https://example.org has the rest.

        - See [the notes](https://example.com/notes) for the details.

        | Page | Where |
        |:--|:--|
        | Overview | [example.net](https://example.net) |
        """

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
        if let session = FooterPreview.session(named: name) { return session }
        if let session = PanelWithBarsPreview.session(named: name) { return session }
        if let session = ImagePreview.session(named: name) { return session }
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
        case "script-running", "script-confirmation", "script-finished":
            return scriptSession(named: name)
        case "confirmation-reminders", "confirmation-events", "confirmation-quit", "confirmation-theme", "confirmation-mcp",
             "confirmation-settings-server", "confirmation-settings-experiment":
            return goAheadSession(named: name)
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
        case "incognito", "incognito-beside":
            return AgentSession(previewEntries: incognitoExchange().entries, incognito: true)
        case "incognito-empty":
            return AgentSession(previewEntries: [], incognito: true)
        case "incognito-command-hint":
            let session = AgentSession(previewEntries: incognitoExchange().entries, incognito: true)
            session.draft = "/"
            return session
        case "incognito-closing":
            var thread = incognitoExchange()
            thread.user("is it supposed to rain in Yosemite this weekend", minutesAgo: 0.2)
            let session = AgentSession(
                previewEntries: thread.entries, streamingText: "I can’t check a forecast from here, since this window",
                isRunning: true, incognito: true)
            session.previewPendingDiscard(.close)
            return session
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
        case "links":
            // A reply with links in a paragraph, a list, and a table, all to placeholder
            // addresses, for checking that a click opens them and dragging still selects.
            var thread = StandInThread(now: Date())
            thread.user("where can I read more about this", minutesAgo: 1)
            thread.reply(linksReply)
            return AgentSession(previewEntries: thread.entries)
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
        case "web-search":
            // OpenAI's hosted search, as its rows read from the saved thread, then a Brave search.
            var thread = StandInThread(now: Date())
            thread.user("when does swift 6.2 come out", minutesAgo: 3)
            thread.hostedSearch("ws_1", action: ["type": "search", "query": "swift 6.2 release date"])
            thread.hostedSearch("ws_2", action: ["type": "open_page", "url": "https://www.swift.org/blog/"])
            thread.reply("Swift 6.2 shipped on September 15, with Xcode 26. See the [announcement](https://www.swift.org/blog/swift-6.2-released/).")
            thread.user("any news on 6.3 this week", minutesAgo: 1)
            thread.call("call_brave", name: SearchWebTool.name,
                        arguments: ["query": "Swift 6.3 release", "count": .null, "freshness": "pw"],
                        output: "1. Swift 6.3 Release Process\n   https://forums.swift.org/t/swift-6-3-release-process\n   The release branch is cut, and the final release is planned for spring.\n   Age: 3 days ago",
                        details: ToolRunDetails(source: ToolSource.webSearch.title))
            thread.reply("Only the release process post so far. The branch is cut, and the release is planned for spring.")
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

    /// A short incognito conversation: a question, and an app opened through a tool.
    private static func incognitoExchange() -> StandInThread {
        var thread = StandInThread(now: Date())
        thread.user("what's a good farewell gift for a coworker who loves hiking", minutesAgo: 3)
        thread.reply("A packable rain shell or a national parks pass are both easy to give and get used a lot.")
        thread.user("open maps so I can find an outdoor shop nearby", minutesAgo: 1)
        thread.call("call_maps", name: OpenApplicationTool.name,
                    arguments: ["bundle_identifier_or_path": "com.apple.Maps"],
                    output: "Opened Maps. It is now in front.",
                    details: ToolRunDetails(started: Date().addingTimeInterval(-58), seconds: 0.31, source: "Built In"))
        thread.reply("Maps is open. Search for “outdoor gear” to see the shops around you.")
        return thread
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

    /// A tool that is not the shell waiting for its go-ahead, with the request it would make.
    static func goAheadSession(named name: String) -> AgentSession {
        var thread = StandInThread(now: Date())
        thread.earlierExchanges()
        let callID = "call_waiting"
        let request: ConfirmationRequest
        switch name {
        case "confirmation-reminders":
            thread.user("clear out the groceries list and remind me to call the dentist tomorrow", minutesAgo: 1)
            thread.call(callID, name: ChangeRemindersTool.name, arguments: ["changes": [
                ["id": "3f9a2c1b", "delete": true], ["id": "7c21d0e4", "delete": true],
                ["id": nil, "title": "Call the dentist", "due": "2026-11-22T10:00"],
            ]], output: nil, details: nil)
            request = ConfirmationRequest(callID: callID, kind: .reminderChanges, body: .changes([
                .init(.delete, "\"Buy eggs\" from Groceries"),
                .init(.delete, "\"Oat milk\" from Groceries"),
                .init(.create, "\"Call the dentist\" in Reminders, due Sun 2026-11-22 10:00"),
            ]), reason: "changes 3 reminders at once, deleting 2")
        case "confirmation-events":
            thread.user("move standup to 9:45 from now on", minutesAgo: 1)
            thread.call(callID, name: ChangeEventsTool.name, arguments: ["changes": [
                ["id": "a4be19f0-20261123", "start": "2026-11-23T09:45", "include_future": true],
            ]], output: nil, details: nil)
            request = ConfirmationRequest(callID: callID, kind: .eventChanges, body: .changes([
                .init(.change, "\"Standup\" (Mon 2026-11-23 09:30 to 09:45) and its later occurrences: start Mon 2026-11-23 09:45"),
            ]), reason: "changes a repeating event from this occurrence on")
        case "confirmation-quit":
            thread.user("quit safari", minutesAgo: 1)
            thread.call(callID, name: QuitOrHideApplicationTool.name, arguments: ["application": "Safari", "action": "quit"], output: nil, details: nil)
            request = ConfirmationRequest(
                callID: callID, kind: .quitApplication, body: .item(name: "Safari", detail: "com.apple.Safari"),
                reason: "may ask you to save unsaved work first")
        case "confirmation-mcp":
            thread.user("add a task to call the landlord on friday", minutesAgo: 1)
            let arguments: JSONValue = ["title": "Call the landlord", "due": "2026-11-27", "list": "Home"]
            thread.call(callID, name: "tasks__create_task", arguments: arguments, output: nil, details: nil)
            request = ConfirmationRequest(
                callID: callID, kind: .mcpToolCall,
                body: .toolCall(server: "tasks", tool: "create_task", arguments: arguments.prettyEncodedString()),
                reason: "comes from an MCP server and is set to ask before each call")
        case "confirmation-settings-server":
            // The settings tools experiment: adding a remote server through the mcp-remote bridge.
            thread.user("set up the figma mcp for moa, its endpoint is https://mcp.figma.com/mcp", minutesAgo: 1)
            let arguments: JSONValue = ["group": "settings", "name": "change_settings", "arguments": [
                "area": "mcp_servers",
                "change": ["add": ["name": "figma", "command": "npx", "args": ["-y", "mcp-remote", "https://mcp.figma.com/mcp"], "env_names": []]],
            ]]
            thread.call(callID, name: UseToolTool.name, arguments: arguments, output: nil, details: nil)
            request = ConfirmationRequest(
                callID: callID, kind: .settingsChange,
                body: .setting(change: "Add the MCP server figma", notes: [
                    "Command: npx -y mcp-remote https://mcp.figma.com/mcp",
                    "figma is a remote server. MOA will reach it through mcp-remote, run with npx.",
                    "Its tools join at the next launch.",
                ]),
                reason: "adds a program MOA starts, whose tools the agent can call")
        case "confirmation-settings-experiment":
            thread.user("turn on the scripts experiment", minutesAgo: 1)
            let arguments: JSONValue = ["group": "settings", "name": "change_settings", "arguments": [
                "area": "experiments", "change": ["experiment": "scripts", "on": true],
            ]]
            thread.call(callID, name: UseToolTool.name, arguments: arguments, output: nil, details: nil)
            request = ConfirmationRequest(
                callID: callID, kind: .settingsChange,
                body: .setting(change: "Turn on the experiment “\(Experiment.scripts.title)”", notes: [
                    "Takes effect: \(Experiment.scripts.whenAChangeTakesEffect)",
                ]),
                reason: "changes how MOA works")
        default:
            thread.user("delete the night swim theme", minutesAgo: 1)
            thread.call(callID, name: ChangeThemeTool.name, arguments: ["action": "delete", "theme_id": "night-swim", "file": nil], output: nil, details: nil)
            request = ConfirmationRequest(
                callID: callID, kind: .deleteTheme, body: .item(name: "Night Swim", detail: "themes/night-swim.json"),
                reason: "removes its file from the themes folder")
        }
        return AgentSession(previewEntries: thread.entries, pendingConfirmation: request, isRunning: true)
    }

    /// Builds stand-in thread entries with send times relative to now.
    /// `run_script`, the scripts experiment: a script that reads the reminders, then deletes
    /// the finished ones. `script-running` while it runs, `script-confirmation` with the delete
    /// waiting for a go-ahead the script asked for, and `script-finished` with its result.
    static func scriptSession(named name: String) -> AgentSession {
        var thread = StandInThread(now: Date())
        thread.earlierExchanges()
        thread.user("clear out the reminders I've finished in Errands", minutesAgo: 1)
        let code = """
            const list = await tools.read_reminders({list: "Errands", include_completed: true})
            const done = list.split("\n").filter((line) => line.startsWith("[x]"))
            text(`${done.length} finished`)
            return await tools.change_reminders({changes: done.map((line) => ({action: "delete", id: line.slice(4, 12)}))})
            """
        let finished = name == "script-finished"
        thread.call(
            "call_script", name: RunScriptTool.name, arguments: ["code": .string(code)],
            output: finished ? "Script completed in 6.2 seconds.\n3 finished\nDeleted 3 reminders from Errands." : nil,
            details: finished ? ToolRunDetails(source: RunScriptTool.scripts.title) : nil)
        switch name {
        case "script-finished":
            thread.reply("Done. I deleted the 3 finished reminders in Errands: Return library books, Pick up dry cleaning, and Buy stamps.")
            return AgentSession(previewEntries: thread.entries)
        case "script-confirmation":
            var request = ConfirmationRequest(
                callID: "call_script", kind: .reminderChanges,
                body: .changes([
                    .init(.delete, "\"Return library books\" from Errands"),
                    .init(.delete, "\"Pick up dry cleaning\" from Errands"),
                    .init(.delete, "\"Buy stamps\" from Errands"),
                ]),
                reason: "deletes 3 reminders")
            request.fromScript = true
            return AgentSession(previewEntries: thread.entries, pendingConfirmation: request, isRunning: true)
        default:
            return AgentSession(previewEntries: thread.entries, isRunning: true, runningCallIDs: ["call_script"])
        }
    }

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

        /// A web search the model ran on OpenAI's side, kept as its provider item.
        mutating func hostedSearch(_ id: String, action: JSONValue) {
            let payload: JSONValue = ["type": "web_search_call", "id": .string(id), "status": "completed", "action": action]
            entries.append(ThreadEntry(date: tick(), item: .providerItem(.init(provider: "openai", model: "gpt-6-luna", payload: payload))))
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
