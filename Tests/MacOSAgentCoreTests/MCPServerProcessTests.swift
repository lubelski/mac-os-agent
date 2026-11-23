import Foundation
import Testing
@testable import MacOSAgentCore

/// The server process's lifecycle: the group is cleared when the leader exits, and nothing is
/// ever sent to the group after the leader is reaped, since its number can then be reused.
@Suite(.serialized) struct MCPServerProcessTests {
    private func launch(_ script: String) throws -> MCPServerProcess {
        try MCPServerProcess.launch(executable: "/bin/sh", arguments: ["-c", script], environment: ["PATH": "/usr/bin:/bin"])
    }

    /// Reads the first line the process writes to standard output.
    private func firstLine(of process: MCPServerProcess) -> String {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while read(process.outputDescriptor, &byte, 1) == 1, byte != UInt8(ascii: "\n") { bytes.append(byte) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func isGone(_ pid: pid_t) async -> Bool {
        for _ in 0..<100 {
            if kill(pid, 0) == -1, errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    @Test func aChildLeftByALeaderThatExitsIsKilledWithoutStop() async throws {
        // The leader starts a child in its group, says its ID, and exits.
        let process = try launch("sleep 30 >/dev/null 2>&1 & echo $!; exit 0")
        let child = try #require(pid_t(firstLine(of: process)))
        #expect(kill(child, 0) == 0)
        #expect(await process.waitForExit() == 0)
        #expect(await isGone(child), "the child is gone with no call to stop()")
        #expect(process.signalsSent == 0)
        #expect(!MCPServerProcess.runningProcessGroups.contains(process.processID))
        process.closeDescriptors()
    }

    @Test func stopSendsNothingToAProcessThatAlreadyExited() async throws {
        let process = try launch("exit 0")
        _ = await process.waitForExit()
        let start = ContinuousClock.now
        await process.stop(gracePeriod: .seconds(2))
        #expect(ContinuousClock.now - start < .milliseconds(500))
        #expect(process.signalsSent == 0)
    }

    @Test func stopEndsARunningServerAndItsChildren() async throws {
        let process = try launch("sleep 30 >/dev/null 2>&1 & echo $!; sleep 30")
        let child = try #require(pid_t(firstLine(of: process)))
        await process.stop(gracePeriod: .seconds(2))
        #expect(await process.waitForExit() == 128 + SIGTERM)
        #expect(process.signalsSent == 1, "SIGTERM was enough, so no SIGKILL was sent")
        #expect(await isGone(child))
    }

    @Test func stopAllEndsRunningServersAndSkipsExitedOnes() async throws {
        let running = try launch("sleep 30")
        let exited = try launch("exit 0")
        _ = await exited.waitForExit()
        MCPServerProcess.stopAll(gracePeriod: 2)
        #expect(running.exitStatus == 128 + SIGTERM)
        #expect(running.signalsSent == 1)
        #expect(exited.signalsSent == 0)
        #expect(MCPServerProcess.runningProcessGroups.isEmpty)
        running.closeDescriptors()
        exited.closeDescriptors()
    }
}
