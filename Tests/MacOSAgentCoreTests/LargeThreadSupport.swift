import Foundation
@testable import MacOSAgentCore

/// Writes a thread file of `count` generated entries straight to disk, the way `ThreadStore`
/// writes them, without going through `append`, which syncs every line.
func writeLargeThread(count: Int, to file: URL) throws {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    let start = Date(timeIntervalSince1970: 1_790_000_000)
    var data = Data()
    for position in 0..<count {
        let item: ThreadItem
        switch position % 4 {
        case 0: item = .userMessage(text: "open report \(position) about the garden budget")
        case 1: item = toolCall("call_\(position)", name: ShellCommandTool.name, arguments: ["command": .string("ls ~/Documents/report-\(position)")])
        case 2: item = .toolResult(.init(callID: "call_\(position - 1)", output: "report-\(position).pdf\n[exit status 0]"))
        default: item = assistant("Report \(position) is open in Preview.")
        }
        data.append(try encoder.encode(ThreadEntry(date: start.addingTimeInterval(Double(position) * 5), item: item)))
        data.append(0x0A)
    }
    try data.write(to: file)
}
