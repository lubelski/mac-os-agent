import Testing
@testable import MacOSAgentCore

@Suite struct ToolSignalTests {
    private let home = "/Users/owner"

    private func render(_ segments: [ToolSignal.Segment]) -> String {
        segments.map { $0.tone == .text ? "<\($0.text)>" : $0.text }.joined()
    }

    @Test func everySummaryDrawsItsFirstWordInTheTextToneAndTheRestDim() {
        #expect(render(ToolSignal.summary("Open Safari", home: home)) == "<Open> Safari")
        #expect(render(ToolSignal.summary(#"Search history for "dark mode""#, home: home)) == #"<Search> history for "dark mode""#)
        #expect(render(ToolSignal.summary("List running applications", home: home)) == "<List> running applications")
    }

    /// The shell tool's row reads as every other row does: its name, then the command, with no
    /// part of the command drawn apart from the rest.
    @Test func theShellRowIsBashThenTheCommand() {
        let summary = ShellCommandTool().summary(arguments: ["command": "brew list --cask | grep -i notion", "destructive": false])
        #expect(summary == "Bash brew list --cask | grep -i notion")
        #expect(render(ToolSignal.summary(summary, home: home)) == "<Bash> brew list --cask | grep -i notion")
        // Syntax the old command lexer gave up on reads the same way.
        #expect(render(ToolSignal.summary("Bash echo $(whoami) > ~/out", home: home)) == "<Bash> echo $(whoami) > ~/out")
        #expect(render(ToolSignal.summary("Bash", home: home)) == "<Bash>")
    }

    @Test func aSummaryIsOneLine() {
        #expect(render(ToolSignal.summary("Bash cd ~/Desktop\nls -la", home: home)) == "<Bash> cd ~/Desktop ls -la")
        #expect(ToolSignal.summary("   ", home: home).isEmpty)
    }

    @Test func onlyWholeHomePathsShorten() {
        #expect(render(ToolSignal.summary("Bash open /Users/owner/Desktop/Receipts", home: home)) == "<Bash> open ~/Desktop/Receipts")
        #expect(render(ToolSignal.summary("Bash /Users/owner/bin/tool run", home: home)) == "<Bash> ~/bin/tool run")
        #expect(render(ToolSignal.summary("Bash ls /Users/owner-too/a", home: home)) == "<Bash> ls /Users/owner-too/a")
        #expect(render(ToolSignal.summary("Bash open https://example.com/Users/owner", home: home)) == "<Bash> open https://example.com/Users/owner")
        #expect(render(ToolSignal.summary(#"Bash ls "/Users/owner/My Files""#, home: home)) == #"<Bash> ls "~/My Files""#)
        #expect(render(ToolSignal.summary("Bash cd /Users/owner", home: home + "/")) == "<Bash> cd ~")
        #expect(render(ToolSignal.summary("Bash ls /Users/owner/a", home: "")) == "<Bash> ls /Users/owner/a")
        // The first word is a name, never a path to shorten.
        #expect(render(ToolSignal.summary("Open /Applications/Notion.app", home: home)) == "<Open> /Applications/Notion.app")
    }

    @Test func failureSummaryPrefersAnExplicitErrorLine() {
        let output = "working\nError: permission denied\n    at run (a.ts:1)\nCommand exited with code 1\n[exit status 1]"
        #expect(ToolSignal.failureSummary(output) == "Error: permission denied")
        #expect(ToolSignal.failureSummary("ls: /Applications/Notion.app: No such file or directory\n[exit status 1]")
            == "ls: /Applications/Notion.app: No such file or directory")
    }

    @Test func failureSummaryFallsBackToTheLastLineThenTheExitStatus() {
        #expect(ToolSignal.failureSummary("first\n\nsecond\nthird\tline\n[exit status 2]") == "third line")
        #expect(ToolSignal.failureSummary("[exit status 1]") == "exit status 1")
        #expect(ToolSignal.failureSummary("(no output)\n[exit status 1]") == "exit status 1")
        #expect(ToolSignal.failureSummary(nil) == "failed with no output")
        #expect(ToolSignal.failureSummary("partial\n[Stopped after the 60 second limit.]\n[exit status 15]") == "partial")
    }

    @Test func stateComesFromStatusAndOutput() {
        #expect(ToolCallState(status: .preparing, output: nil) == .preparing)
        #expect(ToolCallState(status: .running, output: nil) == .running)
        #expect(ToolCallState(status: .waitingForConfirmation, output: nil) == .waitingForConfirmation)
        #expect(ToolCallState(status: .finished, output: "ok\n[exit status 0]") == .succeeded)
        #expect(ToolCallState(status: .finished, output: "Opened Notion. It is now in front.") == .succeeded)
        #expect(ToolCallState(status: .finished, output: nil) == .succeeded)
        #expect(ToolCallState(status: .finished, output: "nope\n[exit status 1]") == .failed("nope"))
        #expect(ToolCallState(status: .finished, output: ShellCommandTool.declinedOutput) == .declined)
        #expect(ToolCallState(status: .finished, output: ShellCommandTool.stoppedBeforeRunningOutput) == .stopped)
        // The native tools that ask decline in their own words.
        #expect(ToolCallState(status: .finished, output: "The owner declined. Nothing was changed.") == .declined)
        #expect(ToolCallState(status: .finished, output: "The owner declined. Safari is still running.") == .declined)
    }

    @Test func theWaitingLineSaysWhatTheGoAheadIsFor() {
        let reminders = ConfirmationRequest(
            callID: "r", kind: .reminderChanges, body: .changes([.init(.delete, "\"Buy eggs\" from Groceries")]),
            reason: "deletes a reminder")
        let state = ToolCallState.waitingForConfirmation
        #expect(state.branchText(pendingGoAhead: reminders, callID: "r") == "waiting for your go-ahead to delete a reminder")
        #expect(state.accessibilityText(pendingGoAhead: reminders, callID: "r") == "Waiting for your go-ahead to delete a reminder")
        // Another row, or no request in view, keeps the plain words.
        #expect(state.branchText(pendingGoAhead: reminders, callID: "other") == "waiting for your go-ahead")
        #expect(state.branchText(pendingGoAhead: nil, callID: "r") == "waiting for your go-ahead")
        #expect(ToolCallState.running.branchText(pendingGoAhead: reminders, callID: "r") == "running")
        let shell = ConfirmationRequest(callID: "s", command: "rm -rf ~/old", reason: "deletes files")
        #expect(state.branchText(pendingGoAhead: shell, callID: "s") == "waiting for your go-ahead")
    }

    @Test func onlyStatesThatNeedASecondLineHaveOne() {
        #expect(ToolCallState.succeeded.branchText == nil)
        #expect(ToolCallState.preparing.branchText == nil)
        #expect(ToolCallState.failed("why").branchText == "why")
        #expect(ToolCallState.declined.branchText != nil)
        #expect(ToolCallState.running.branchText != nil)
    }
}
