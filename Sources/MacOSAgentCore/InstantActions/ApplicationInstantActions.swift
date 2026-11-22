import Foundation

/// The instant action provider for installed applications: "saf" or "open safari" opens Safari.
///
/// It matches against a list of applications read ahead of time, never Spotlight, so a match
/// never waits. The names are normalized once when the list is made, so matching an input
/// against a few hundred apps takes well under a millisecond.
public struct ApplicationInstantActions: InstantActionProvider {
    public static let launchVerbs: Set<String> = ["open", "launch", "start", "switch to", "go to", "bring up"]
    /// A running app ranks this much above the same match that is not running.
    static let runningBonus = 2

    public var verbs: Set<String> { Self.launchVerbs }

    struct Prepared: Sendable {
        var application: InstalledApplication
        /// The names it answers to, normalized, with their words: the Finder name, the other
        /// Info.plist names, and the last part of the bundle identifier.
        var names: [(whole: String, words: [String])]
    }

    private let prepared: [Prepared]
    private let runningPaths: Set<String>

    /// - Parameters:
    ///   - applications: the installed apps, in the catalog's folder order. A second app with the
    ///     same name, such as a copy in `~/Applications`, is left out.
    ///   - runningPaths: paths of the running apps, which win a tie.
    public init(applications: [InstalledApplication], runningPaths: Set<String> = []) {
        var seenPaths = Set<String>()
        var seenNames = Set<String>()
        var prepared: [Prepared] = []
        prepared.reserveCapacity(applications.count)
        for application in applications {
            let name = ApplicationMatcher.normalized(application.name)
            guard !name.isEmpty, seenPaths.insert(application.path).inserted, seenNames.insert(name).inserted else { continue }
            var fields = [application.name] + application.alternateNames
            if let last = application.bundleIdentifier?.split(separator: ".").last { fields.append(String(last)) }
            var names: [(String, [String])] = []
            for field in fields {
                let whole = ApplicationMatcher.normalized(field)
                if !whole.isEmpty, !names.contains(where: { $0.0 == whole }) {
                    names.append((whole, ApplicationMatcher.words(field)))
                }
            }
            prepared.append(Prepared(application: application, names: names))
        }
        self.prepared = prepared
        self.runningPaths = runningPaths
    }

    public var applicationCount: Int { prepared.count }

    public static func id(for application: InstalledApplication) -> String { "application:" + application.path }

    public func candidates(for phrase: InstantPhrase) -> [InstantActionCandidate] {
        let query = ApplicationMatcher.normalized(phrase.subject)
        let queryWords = ApplicationMatcher.words(phrase.subject)
        guard !query.isEmpty else { return [] }
        var result: [InstantActionCandidate] = []
        for entry in prepared {
            var best: InstantMatchStrength?
            for name in entry.names {
                if let strength = Self.strength(query: query, queryWords: queryWords, name: name.whole, words: name.words) {
                    best = max(best ?? strength, strength)
                }
            }
            guard let strength = best else { continue }
            let application = entry.application
            var score = ApplicationMatcher.score(phrase.subject, application) ?? 0
            if runningPaths.contains(application.path) { score += Self.runningBonus }
            result.append(InstantActionCandidate(
                id: Self.id(for: application), title: application.name, strength: strength, score: score,
                target: .application(application)))
        }
        // Best first, then the shorter name, then the catalog's order, which the sort keeps.
        return result.enumerated().sorted { a, b in
            if a.element.score != b.element.score { return a.element.score > b.element.score }
            if a.element.title.count != b.element.title.count { return a.element.title.count < b.element.title.count }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// How strongly one name matches, or nil when it is weaker than initials. Loose matches the
    /// agent's search accepts, such as a letter missing or the subject inside a word, do not
    /// count here.
    static func strength(query: String, queryWords: [String], name: String, words: [String]) -> InstantMatchStrength? {
        if name == query { return .exact }
        if name.hasPrefix(query) { return .prefix }
        if words.count > 1, words.contains(query) { return .wordExact }
        if words.contains(where: { $0.hasPrefix(query) }) { return .wordPrefix }
        if queryWords.count > 1, ApplicationMatcher.allWordsArePrefixes(queryWords, of: words) { return .wordPrefix }
        if query.count >= 2, words.count > 1, String(words.compactMap(\.first)).hasPrefix(query) { return .initials }
        return nil
    }
}
