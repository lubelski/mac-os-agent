import Foundation
import Synchronization

/// Token counts for one model request, in a shape that does not depend on the provider.
public struct TokenUsage: Sendable, Equatable, Codable {
    /// Every input token, including the cached ones.
    public var inputTokens: Int
    /// The input tokens read from the prompt cache.
    public var cachedInputTokens: Int
    /// Every output token, including reasoning.
    public var outputTokens: Int
    /// The output tokens spent on reasoning, when the provider reports them.
    public var reasoningTokens: Int?

    public init(inputTokens: Int, cachedInputTokens: Int, outputTokens: Int, reasoningTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
    }

    /// The share of input tokens that came from the cache, from 0 to 1.
    public var cachedShare: Double {
        inputTokens > 0 ? Double(cachedInputTokens) / Double(inputTokens) : 0
    }
}

/// One line of the usage log. It holds counts only, never message content.
public struct UsageRecord: Sendable, Equatable, Codable {
    public var date: Date
    public var provider: String
    public var model: String
    public var input: Int
    public var cached: Int
    public var output: Int
    public var reasoning: Int?
    /// How long the request took, from sending it to the end of the reply. Missing from lines
    /// written before it was recorded.
    public var seconds: Double?
    /// A fingerprint of the instructions and tool list sent with the request. When it changes
    /// between requests, the prompt cache starts over. See `PromptFingerprint`.
    public var prompt: String?

    public init(
        date: Date, provider: String, model: String, usage: TokenUsage, seconds: Double? = nil, prompt: String? = nil
    ) {
        self.date = date
        self.provider = provider
        self.model = model
        input = usage.inputTokens
        cached = usage.cachedInputTokens
        output = usage.outputTokens
        reasoning = usage.reasoningTokens
        self.seconds = seconds
        self.prompt = prompt
    }

    public var usage: TokenUsage {
        TokenUsage(inputTokens: input, cachedInputTokens: cached, outputTokens: output, reasoningTokens: reasoning)
    }
}

/// Totals over a set of requests.
public struct UsageTotals: Sendable, Equatable {
    public var requests = 0
    public var input = 0
    public var cached = 0
    public var output = 0
    public var reasoning = 0

    public init() {}

    public var cachedShare: Double { input > 0 ? Double(cached) / Double(input) : 0 }

    public mutating func add(_ record: UsageRecord) {
        requests += 1
        input += record.input
        cached += record.cached
        output += record.output
        reasoning += record.reasoning ?? 0
    }
}

/// A JSON Lines file with one line per model request, kept apart from the thread so the
/// thread holds only the conversation. Used to see whether prompt caching works.
public final class UsageLog: Sendable {
    public let fileURL: URL
    private let lock = Mutex(())

    public init(fileURL: URL = AgentPaths.usageLogFile) {
        self.fileURL = fileURL
    }

    /// Adds one line. A failure to write is ignored, since the log must never stop a task.
    public func append(_ record: UsageRecord) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var line = try? encoder.encode(record) else { return }
        line.append(UInt8(ascii: "\n"))
        lock.withLock { _ in
            let manager = FileManager.default
            if !manager.fileExists(atPath: fileURL.plainPath) {
                try? manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                manager.createFile(atPath: fileURL.plainPath, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        }
    }

    /// Every record in the file, oldest first. Lines that do not parse are skipped.
    public func records() -> [UsageRecord] {
        guard let data = lock.withLock({ _ in try? Data(contentsOf: fileURL) }) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(UsageRecord.self, from: $0) }
    }

    /// The most recent requests, newest first.
    public func recent(_ limit: Int) -> [UsageRecord] {
        Array(records().suffix(limit).reversed())
    }

    /// The most recent request and the totals for the day that contains `now`.
    public func summary(now: Date = Date(), calendar: Calendar = .current) -> (last: UsageRecord?, today: UsageTotals) {
        let all = records()
        var today = UsageTotals()
        for record in all where calendar.isDate(record.date, inSameDayAs: now) { today.add(record) }
        return (all.last, today)
    }
}
