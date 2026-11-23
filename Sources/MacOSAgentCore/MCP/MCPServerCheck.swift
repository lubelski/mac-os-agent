import Foundation

/// `--check-mcp-servers`: starts the servers in the data folder as a launch does, waits for
/// each, calls an `echo` tool if one is there, stops them the way quitting does, and reports
/// what happened. It is for checking a bundled build against real servers, with the PATH and
/// hardened runtime of an app, without its menu bar item, hotkey, or windows.
public enum MCPServerCheck {
    public static let argument = "--check-mcp-servers"

    public static func run() async -> String {
        var lines: [String] = []
        let problems = ProblemLog()
        // An explicit request for MCP, so it acts as if the experiment is on, without reading
        // or writing the preference.
        let pool = MCPServerPool.fromDataFolder(problems: problems, experimentOn: true)
        let config = await pool.config
        let tools = pool.makeTools()
        lines.append("servers in file: \(config.servers.map(\.name).joined(separator: ", "))")
        lines.append("tools at launch, from the cache: \(tools.count)")
        lines.append("PATH: \(MCPEnvironment.searchPath.joined(separator: ":"))")
        await pool.start()
        for entry in config.usableServers where pool.settings.isEnabled(entry.name) {
            do {
                _ = try await pool.connection(to: entry.name)
            } catch {
                lines.append("\(entry.name): could not connect: \(MCPServerPool.describe(error))")
            }
        }
        for status in await pool.statuses() {
            var line = "\(status.entry.name): \(status.state.label)"
            if case .failed(let reason) = status.state { line += " (\(reason))" }
            if case .invalid(let problem) = status.state { line += " (\(problem))" }
            line += ", \(status.liveTools?.count ?? 0) tools"
            if let note = status.nextLaunchNote { line += ". \(note)" }
            lines.append(line)
        }
        for case let tool as MCPTool in tools where tool.info.name == "echo" {
            let context = ToolRunContext(callID: "check") { _ in true }
            lines.append("\(tool.name): \(await tool.run(arguments: ["message": "hello from the bundled app"], context: context))")
        }
        let groups = MCPServerProcess.runningProcessGroups
        lines.append("server process groups running: \(groups.sorted())")
        // The same stop as quitting the app.
        MCPServerProcess.stopAll()
        try? await Task.sleep(for: .milliseconds(300))
        let left = groups.filter { killpg($0, 0) == 0 }
        lines.append("process groups left after stopping: \(left.sorted())")
        for problem in problems.problems { lines.append("problem: \(problem.area): \(problem.message)") }
        return lines.joined(separator: "\n")
    }
}
