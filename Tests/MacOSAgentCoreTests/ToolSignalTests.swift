import Testing
@testable import MacOSAgentCore

@Suite struct ToolSignalTests {
    private let home = "/Users/owner"

    private func render(_ segments: [ToolSignal.Segment]) -> String {
        segments.map { $0.tone == .text ? "<\($0.text)>" : $0.text }.joined()
    }

    @Test func programsDrawInTheTextToneAndTheRestStaysDim() {
        #expect(render(ToolSignal.command("pmset -g batt", home: home)) == "<pmset> -g batt")
        #expect(render(ToolSignal.command("brew list --cask 2>/dev/null | grep -i notion", home: home))
            == "brew list --cask 2>/dev/null | grep -i notion")
        #expect(render(ToolSignal.command("brew list --cask | grep -i notion", home: home)) == "<brew> list --cask | <grep> -i notion")
    }

    @Test func quotedWordsAndOperatorsWithoutSpacesAreRead() {
        let rendered = render(ToolSignal.command(#"CI=1 env git status&&printf "a|b";cat /Users/owner/file"#, home: home))
        #expect(rendered == #"CI=1 env <git> status&&<printf> "a|b";<cat> ~/file"#)
    }

    @Test func wrappersAreDimAndTheProgramAfterThemIsNot() {
        #expect(render(ToolSignal.command("sudo npm test | head", home: home)) == "sudo <npm> test | <head>")
    }

    @Test(arguments: [
        "sudo -u root npm test", "env -C /tmp npm test", "echo $(whoami)", "echo `pwd`", "cat <<EOF",
        #"echo "unfinished"#, "if true; then echo ok; fi", "echo hi > file", #"echo a\ b"#, "echo x # comment",
        "sleep 5 &",
    ])
    func syntaxItCannotReadFallsBackToDim(command: String) {
        #expect(ToolSignal.command(command, home: home) == [ToolSignal.Segment(.dim, command)])
    }

    @Test func multipleLinesFallBackToOneDimLine() {
        #expect(ToolSignal.command("echo hi\ncat file", home: home) == [ToolSignal.Segment(.dim, "echo hi cat file")])
    }

    @Test func onlyWholeHomePathsShorten() {
        #expect(render(ToolSignal.command("open /Users/owner/Desktop/Receipts", home: home)) == "<open> ~/Desktop/Receipts")
        #expect(render(ToolSignal.command("/Users/owner/bin/tool run", home: home)) == "<~/bin/tool> run")
        #expect(render(ToolSignal.command("ls /Users/owner-too/a", home: home)) == "<ls> /Users/owner-too/a")
        #expect(render(ToolSignal.command("open https://example.com/Users/owner", home: home)) == "<open> https://example.com/Users/owner")
        #expect(render(ToolSignal.command(#"ls "/Users/owner/My Files""#, home: home)) == #"<ls> "~/My Files""#)
    }

    @Test func compactPathKeepsOtherPaths() {
        #expect(ToolSignal.compactPath("/Users/owner", home: home + "/") == "~")
        #expect(ToolSignal.compactPath("/Applications/Notion.app", home: home) == "/Applications/Notion.app")
        #expect(ToolSignal.compactPath("/Users/owner/a", home: "") == "/Users/owner/a")
    }

    @Test func emptyCommandHasNoSegments() {
        #expect(ToolSignal.command("   ", home: home).isEmpty)
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
