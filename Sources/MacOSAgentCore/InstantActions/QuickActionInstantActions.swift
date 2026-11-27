import Foundation

/// The instant action provider for the owner's quick actions: "screensaver" or "run
/// screensaver" offers the action named Start Screensaver, or one with "screensaver" among its
/// phrases. It is ranked beside the apps by the same rule and the same learned use.
///
/// An action's name can start with a launch verb, such as "Start Screensaver", so this
/// provider is asked whatever verb the input starts with, and matches the whole input as well
/// as the part after the verb.
public struct QuickActionInstantActions: InstantActionProvider {
    public static let runVerbs: Set<String> = ["run"]

    public var verbs: Set<String> { Self.runVerbs }
    public var matchesAnyVerb: Bool { true }

    struct Prepared: Sendable {
        var action: QuickAction
        var detail: String
        var names: [(whole: String, words: [String])]
    }

    private let prepared: [Prepared]

    /// - Parameters:
    ///   - actions: the actions to offer, which should be the ones that are on.
    ///   - summaries: what each step's tool says it does, for the row's short reading.
    public init(actions: [QuickAction], summaries: ToolCallSummaries = .builtIn) {
        prepared = actions.map { action in
            var names: [(String, [String])] = []
            for field in action.matchNames {
                let whole = ApplicationMatcher.normalized(field)
                if !whole.isEmpty, !names.contains(where: { $0.0 == whole }) {
                    names.append((whole, ApplicationMatcher.words(field)))
                }
            }
            return Prepared(action: action, detail: Self.reading(of: action, summaries: summaries), names: names)
        }
    }

    public var actionCount: Int { prepared.count }

    /// The row's id. The prefix stays "action:", from before quick actions were renamed: it is the
    /// key learned use is kept under in instant-actions.json.
    public static func id(for action: QuickAction) -> String { "action:" + action.id }

    /// The steps in a few plain words for the row, such as "Open ScreenSaverEngine" or
    /// "Open Music, then Set the volume". Each step reads as its tool's own summary.
    public static func reading(of action: QuickAction, summaries: ToolCallSummaries = .builtIn) -> String {
        let parts = action.steps.map { step -> String in
            let text = summaries.summary(name: step.tool, arguments: step.arguments.encodedString())
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            return line.count > 60 ? String(line.prefix(59)) + "…" : line
        }
        if parts.count > 3 { return parts.prefix(2).joined(separator: ", then ") + ", and \(parts.count - 2) more steps" }
        return parts.joined(separator: ", then ")
    }

    public func candidates(for phrase: InstantPhrase) -> [InstantActionCandidate] {
        // The subject after a verb, and with any verb but "run", the whole input too.
        var queries: [String] = []
        if phrase.verb == nil || Self.runVerbs.contains(phrase.verb!) { queries.append(phrase.subject) }
        if phrase.verb != nil { queries.append(phrase.text) }
        var result: [InstantActionCandidate] = []
        for entry in prepared {
            var best: (strength: InstantMatchStrength, score: Int)?
            var startsName = false
            for query in queries {
                let normalized = ApplicationMatcher.normalized(query)
                guard !normalized.isEmpty else { continue }
                let queryWords = ApplicationMatcher.words(query)
                for (index, name) in entry.names.enumerated() {
                    guard let strength = ApplicationInstantActions.strength(
                        query: normalized, queryWords: queryWords, name: name.whole, words: name.words)
                    else { continue }
                    // "dark" for Dark mode: the subject is the name's first whole word or words.
                    if !queryWords.isEmpty, name.words.starts(with: queryWords) { startsName = true }
                    // A phrase is a name the owner chose, so it counts as fully as the name, a
                    // point lower so the name wins a tie with its own phrase.
                    let score = ApplicationInstantActions.baseScore[strength]! - (index > 0 ? 1 : 0)
                    if best == nil || score > best!.score { best = (strength, score) }
                }
            }
            guard let best else { continue }
            var candidate = InstantActionCandidate(
                id: Self.id(for: entry.action), title: entry.action.name, detail: entry.detail,
                strength: best.strength, score: best.score, target: .quickAction(id: entry.action.id))
            candidate.subjectStartsOwnersName = startsName
            result.append(candidate)
        }
        return result.enumerated().sorted { a, b in
            if a.element.score != b.element.score { return a.element.score > b.element.score }
            return a.offset < b.offset
        }.map(\.element)
    }
}
