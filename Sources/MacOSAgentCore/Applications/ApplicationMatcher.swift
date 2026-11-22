import Foundation

/// An application bundle on disk.
public struct InstalledApplication: Sendable, Equatable, Hashable {
    /// The name Finder shows, without `.app`.
    public var name: String
    public var bundleIdentifier: String?
    public var url: URL
    /// Other names from the bundle's Info.plist, such as `CFBundleName`, that also match a search.
    public var alternateNames: [String]
    /// A part of macOS that people rarely open by name, such as the apps directly in
    /// `/System/Library/CoreServices`. These rank below other apps with a similar match.
    public var isSystemComponent: Bool

    public init(name: String, bundleIdentifier: String?, url: URL, alternateNames: [String] = [], isSystemComponent: Bool = false) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.url = url
        self.alternateNames = alternateNames
        self.isSystemComponent = isSystemComponent
    }

    /// Set when the bundle is a menu bar or background app (`LSUIElement` or `LSBackgroundOnly`).
    /// Not used in matching.
    var hasNoDockIcon = false

    public var path: String { url.plainPath }
}

extension URL {
    /// The file path without percent encoding or a trailing slash, so the same bundle always
    /// gives the same text whether or not the URL was marked as a folder.
    var plainPath: String {
        let path = standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

/// One search result, with the score it ranked by.
public struct ApplicationMatch: Sendable, Equatable {
    public var application: InstalledApplication
    public var score: Int
    public var isRunning: Bool
}

/// Matches a short, loosely typed name such as "chrome", "vs code", or "notion" against
/// installed applications and ranks the results. Pure, so it can be tested with a made-up list.
public enum ApplicationMatcher {
    /// Results below this score are dropped. A loose subsequence match scores just above it.
    public static let minimumScore = 25
    /// Results at or above this score are close matches. Below it they are only loose ones.
    public static let closeMatchScore = 60
    /// How far a system component ranks below an ordinary app with the same match.
    public static let systemComponentPenalty = 15

    public static func rank(
        query: String,
        applications: [InstalledApplication],
        runningPaths: Set<String> = [],
        limit: Int = 10
    ) -> [ApplicationMatch] {
        let query = Query(query)
        guard !query.normalized.isEmpty else { return [] }
        var seen = Set<String>()
        var matches: [ApplicationMatch] = []
        for application in applications where seen.insert(application.path).inserted {
            if let score = score(query, application), score >= minimumScore {
                matches.append(ApplicationMatch(
                    application: application, score: score, isRunning: runningPaths.contains(application.path)))
            }
        }
        matches.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.isRunning != b.isRunning { return a.isRunning }
            if a.application.name.count != b.application.name.count {
                return a.application.name.count < b.application.name.count
            }
            if a.application.name != b.application.name { return a.application.name < b.application.name }
            return a.application.path < b.application.path
        }
        return Array(matches.prefix(limit))
    }

    /// The best score for one application, or nil when nothing about it matches.
    public static func score(_ query: String, _ application: InstalledApplication) -> Int? {
        score(Query(query), application)
    }

    struct Query {
        var raw: String
        var normalized: String
        var words: [String]

        init(_ text: String) {
            raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
            normalized = ApplicationMatcher.normalized(raw)
            words = ApplicationMatcher.words(raw)
        }
    }

    static func score(_ query: Query, _ application: InstalledApplication) -> Int? {
        var best: Int?
        func consider(_ value: Int?) {
            if let value, value > (best ?? Int.min) { best = value }
        }
        consider(fieldScore(query, application.name))
        for alternate in application.alternateNames where alternate != application.name {
            consider(fieldScore(query, alternate).map { $0 - 2 })
        }
        if let identifier = application.bundleIdentifier {
            if identifier.caseInsensitiveCompare(query.raw) == .orderedSame { consider(100) }
            // The last part of a bundle identifier is often the short name: com.microsoft.VSCode.
            if let last = identifier.split(separator: ".").last {
                consider(fieldScore(query, String(last)).map { $0 - 5 })
            }
            if query.normalized.count >= 4, normalized(identifier).contains(query.normalized) { consider(40) }
        }
        if application.isSystemComponent, let score = best { return score - systemComponentPenalty }
        return best
    }

    /// How well the query matches one name. Higher is better, nil is no match.
    static func fieldScore(_ query: Query, _ field: String) -> Int? {
        let q = query.normalized
        let name = normalized(field)
        guard !q.isEmpty, !name.isEmpty else { return nil }
        let fieldWords = words(field)

        if name == q { return 100 }
        if name.hasPrefix(q) { return 90 }
        if fieldWords.contains(where: { $0.hasPrefix(q) }) { return 80 }
        if query.words.count > 1, allWordsArePrefixes(query.words, of: fieldWords) { return 75 }
        if q.count >= 2, fieldWords.count > 1, String(fieldWords.compactMap(\.first)).hasPrefix(q) { return 70 }
        if q.count >= 3, name.contains(q) { return 60 }
        if q.count >= 4 {
            let allowed = q.count >= 8 ? 2 : 1
            let candidates = [name] + fieldWords
            if candidates.contains(where: { editDistance(q, $0, limit: allowed) <= allowed }) { return 45 }
        }
        if q.count >= 3, fieldWords.contains(where: { $0.first == q.first }), isSubsequence(q, of: name) { return 30 }
        return nil
    }

    /// Lowercase letters and digits only, with accents removed.
    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
            .lowercased()
    }

    /// Normalized words, split at spaces and punctuation, so "GitHub Desktop" gives github and
    /// desktop and "zoom.us" gives zoom and us.
    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { normalized(String($0)) }
            .filter { !$0.isEmpty }
    }

    static func allWordsArePrefixes(_ queryWords: [String], of fieldWords: [String]) -> Bool {
        var remaining = fieldWords
        for word in queryWords {
            guard let index = remaining.firstIndex(where: { $0.hasPrefix(word) }) else { return false }
            remaining.remove(at: index)
        }
        return true
    }

    static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var iterator = haystack.makeIterator()
        for character in needle {
            var found = false
            while let next = iterator.next() {
                if next == character { found = true; break }
            }
            if !found { return false }
        }
        return true
    }

    /// Levenshtein distance, giving up early once it is certain to pass `limit`.
    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a), b = Array(b)
        if abs(a.count - b.count) > limit { return limit + 1 }
        var previous = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var current = [i] + Array(repeating: 0, count: b.count)
            var rowMinimum = current[0]
            for j in 1...max(b.count, 1) where !b.isEmpty {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                rowMinimum = min(rowMinimum, current[j])
            }
            if rowMinimum > limit { return limit + 1 }
            previous = current
        }
        return previous[b.count]
    }
}
