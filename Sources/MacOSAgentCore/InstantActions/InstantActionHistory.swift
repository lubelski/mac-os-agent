import Foundation
import Synchronization

/// What the owner has taken through instant actions, used to rank candidates: which candidate
/// they took for which typed subject, and how often and how recently each was taken. So "s"
/// can come to mean Safari for one owner and Slack for another.
///
/// It holds names of apps and the short text typed for them, never anything sent to the
/// model. It is kept in `instant-actions.json` in Application Support, and never written
/// from an incognito window.
public struct InstantActionHistory: Codable, Sendable, Equatable {
    public struct Use: Codable, Sendable, Equatable {
        public var count: Int
        /// The most recent times it was taken, newest last, at most `recentLimit`.
        public var recent: [Date]
    }

    public struct Pick: Codable, Sendable, Equatable {
        public var count: Int
        public var last: Date
    }

    public var version = 1
    /// Candidate id to how often and when it was taken.
    public var uses: [String: Use] = [:]
    /// Typed subject, as `InstantPhrase.key`, to the candidates taken for it.
    public var picks: [String: [String: Pick]] = [:]

    public static let recentLimit = 10
    /// How many typed subjects and candidates are kept. The least recent go first.
    public static let subjectLimit = 300
    public static let useLimit = 300
    /// The most that how often and how recently a candidate is used adds to its score. It is
    /// less than the gap between an exact name and a prefix, so use alone never puts a prefix
    /// ahead of an exact name.
    public static let maximumUseBoost = 8
    /// What having taken a candidate for this exact subject adds, at least and at most. The
    /// least is above `InstantActionRule.clearLead`, so one pick is enough to make it the
    /// only choice next time.
    public static let firstPickBoost = 14
    public static let maximumPickBoost = 26
    /// After this long without being taken again, a pick counts half.
    public static let pickFades: TimeInterval = 90 * 24 * 3600

    public init() {}

    public mutating func record(_ id: String, subject: String, at date: Date) {
        var use = uses[id] ?? Use(count: 0, recent: [])
        use.count += 1
        use.recent.append(date)
        if use.recent.count > Self.recentLimit { use.recent.removeFirst(use.recent.count - Self.recentLimit) }
        uses[id] = use
        if !subject.isEmpty {
            var forSubject = picks[subject] ?? [:]
            var pick = forSubject[id] ?? Pick(count: 0, last: date)
            pick.count += 1
            pick.last = date
            forSubject[id] = pick
            picks[subject] = forSubject
        }
        prune()
    }

    public func wasPicked(_ id: String, for subject: String) -> Bool {
        (picks[subject]?[id]?.count ?? 0) > 0
    }

    /// What learned use adds to a candidate's score for this subject.
    public func boost(for id: String, subject: String, now: Date) -> Int {
        useBoost(for: id, now: now) + pickBoost(for: id, subject: subject, now: now)
    }

    /// From how often and how recently the candidate was taken, whatever was typed: each
    /// recent use counts more the newer it is.
    public func useBoost(for id: String, now: Date) -> Int {
        guard let use = uses[id] else { return 0 }
        let weight = use.recent.reduce(0.0) { total, date in
            let age = now.timeIntervalSince(date)
            let day: TimeInterval = 24 * 3600
            return total + (age < day ? 1.0 : age < 7 * day ? 0.6 : age < 30 * day ? 0.3 : 0.1)
        }
        return min(Self.maximumUseBoost, Int((weight * 2).rounded()))
    }

    public func pickBoost(for id: String, subject: String, now: Date) -> Int {
        guard let pick = picks[subject]?[id], pick.count > 0 else { return 0 }
        let boost = min(Self.maximumPickBoost, Self.firstPickBoost + 4 * (pick.count - 1))
        return now.timeIntervalSince(pick.last) > Self.pickFades ? boost / 2 : boost
    }

    private mutating func prune() {
        if picks.count > Self.subjectLimit {
            let ordered = picks.sorted { ($0.value.values.map(\.last).max() ?? .distantPast) < ($1.value.values.map(\.last).max() ?? .distantPast) }
            for (subject, _) in ordered.prefix(picks.count - Self.subjectLimit) { picks[subject] = nil }
        }
        if uses.count > Self.useLimit {
            let ordered = uses.sorted { ($0.value.recent.last ?? .distantPast) < ($1.value.recent.last ?? .distantPast) }
            for (id, _) in ordered.prefix(uses.count - Self.useLimit) { uses[id] = nil }
        }
    }
}

/// The history on disk. Reads once, keeps a copy in memory, and writes the whole small file
/// after each change, off the caller's thread.
public final class InstantActionHistoryStore: Sendable {
    public let fileURL: URL
    private let state: Mutex<InstantActionHistory>
    private let writes = Mutex<Task<Void, Never>?>(nil)

    public init(fileURL: URL) {
        self.fileURL = fileURL
        var history = InstantActionHistory()
        if let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let decoded = try? decoder.decode(InstantActionHistory.self, from: data) { history = decoded }
        }
        state = Mutex(history)
    }

    public var history: InstantActionHistory { state.withLock { $0 } }

    /// Records that a candidate was taken for a subject, and saves.
    public func record(_ id: String, subject: String, at date: Date = Date()) {
        let snapshot = state.withLock { history in
            history.record(id, subject: subject, at: date)
            return history
        }
        let url = fileURL
        writes.withLock { previous in
            let earlier = previous
            previous = Task.detached(priority: .utility) {
                await earlier?.value
                Self.write(snapshot, to: url)
            }
        }
    }

    /// Waits for the last save, for tests.
    public func waitForWrites() async {
        await writes.withLock { $0 }?.value
    }

    private static func write(_ history: InstantActionHistory, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(history) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
