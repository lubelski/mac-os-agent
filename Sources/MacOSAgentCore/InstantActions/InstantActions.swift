import Foundation

/// Instant actions answer a short input on the spot, with no model request: "saf" or
/// "open safari" opens Safari when Return is pressed. The panel checks every input as the
/// owner types. When the input is confidently an action, a row above the text field says what
/// Return will do. Otherwise nothing shows and Return sends the text to the agent as usual, so
/// the model is the fallback and never a second guess.
///
/// The mechanism is general. A provider turns a subject into candidates, each with how strongly
/// it matched. `InstantActionRule` decides from those, the phrase's shape, and the learned use
/// whether to offer anything. Applications are the only provider so far.

/// How strongly a candidate's name matched the subject, strongest last.
public enum InstantMatchStrength: Int, Sendable, Comparable, CaseIterable {
    /// The subject is the initials of a name of several words: "vsc" for Visual Studio Code.
    case initials = 1
    /// Every word of the subject starts a word of the name: "chr" or "vs code".
    case wordPrefix
    /// The subject is one whole word of the name: "chrome" for Google Chrome.
    case wordExact
    /// The name starts with the subject: "saf" for Safari.
    case prefix
    /// The subject is the name: "safari".
    case exact

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// What an instant action does when it is taken.
public enum InstantActionTarget: Sendable, Equatable, Hashable {
    case application(InstalledApplication)

    /// What Return does, in the row's words: "opens".
    public var actionLabel: String {
        switch self {
        case .application: "opens"
        }
    }
}

/// One thing an input could mean.
public struct InstantActionCandidate: Sendable, Equatable, Identifiable {
    /// Stable across launches, such as `application:/System/Applications/Notes.app`. The learned
    /// use is kept under it.
    public var id: String
    /// The name shown in the row.
    public var title: String
    public var strength: InstantMatchStrength
    /// The provider's own ranking score, higher is better.
    public var score: Int
    /// What the learned use adds to the score.
    public var boost: Int = 0
    /// True when the owner has taken this candidate for this exact subject before.
    public var wasPickedForSubject = false
    public var target: InstantActionTarget

    public init(id: String, title: String, strength: InstantMatchStrength, score: Int, target: InstantActionTarget) {
        self.id = id
        self.title = title
        self.strength = strength
        self.score = score
        self.target = target
    }

    public var rankingScore: Int { score + boost }
}

/// What the panel offers for an input: one candidate, or a few to choose between with the
/// first chosen.
public struct InstantActionSuggestion: Sendable, Equatable {
    /// The input this answers, so a suggestion is never used for text that has since changed.
    public var input: String
    public var phrase: InstantPhrase
    public var choices: [InstantActionCandidate]

    public var top: InstantActionCandidate { choices[0] }
}

/// Turns a subject into candidates. Called on every keystroke, so it must be fast and must
/// never wait on anything.
public protocol InstantActionProvider: Sendable {
    /// The verbs that address this provider, lowercased, such as "open" and "switch to".
    var verbs: Set<String> { get }
    /// Candidates for the subject, best first, with their strength and score. Only matches of
    /// at least `InstantMatchStrength.initials` belong here.
    func candidates(for phrase: InstantPhrase) -> [InstantActionCandidate]
}

/// When an input is confidently an instant action, and which candidates the row offers.
/// It is strict on purpose: opening an app when the owner meant to send a message is worse
/// than being slow.
///
/// - The shape comes first (`InstantPhrase.parse`): a few words at most, no line breaks, and no
///   sentence punctuation. Anything else is for the agent.
/// - A subject with a word such as "the", "is", or "it" is a sentence fragment and offers
///   nothing, unless a candidate's name is exactly the subject, such as "Find My".
/// - With a verb ("open", "launch", "start", "switch to", "go to", "bring up"), the intent is
///   explicit, so any match of initials or better counts, and a single character is enough.
/// - Without a verb, the input itself has to look like a name: at least two characters, a
///   word prefix or better, and initials only from three characters.
/// - A single everyday word, such as "find", "help", or "what", offers only a candidate whose
///   name it is exactly, or with a verb, a candidate that has it as a whole word ("open word").
/// - The best candidate has to lead the next by `clearLead` points to be offered alone.
///   Otherwise the row offers the close ones to choose between, up to `maximumChoices`, but
///   only for a verb or a subject of three or more characters. Shorter bare input with no
///   clear leader offers nothing.
/// - Learned use reorders candidates. A candidate the owner took before for this exact subject
///   also lifts the single character and everyday word limits, since the owner has shown what
///   the input means to them. It never lifts the shape rule or the function word rule.
public enum InstantActionRule {
    public static let clearLead = 10
    public static let choiceWindow = 12
    public static let maximumChoices = 3

    public static func choices(for phrase: InstantPhrase, candidates: [InstantActionCandidate]) -> [InstantActionCandidate] {
        let length = phrase.normalizedLength
        guard length > 0 else { return [] }
        let learned = candidates.contains(where: \.wasPickedForSubject)
        let hasVerb = phrase.verb != nil

        if phrase.hasFunctionWord, !candidates.contains(where: { $0.strength == .exact }) { return [] }

        var kept = candidates.filter { candidate in
            if candidate.wasPickedForSubject { return true }
            if hasVerb { return true }
            if length < 2 { return false }
            if candidate.strength == .initials { return length >= 3 }
            return true
        }
        if phrase.isEverydayWord, !learned {
            // A name that only starts with the word ("find" for Finder) is never enough.
            kept = kept.filter { $0.strength == .exact || (hasVerb && $0.strength == .wordExact) }
        }
        guard !kept.isEmpty else { return [] }

        let ranked = kept.enumerated().sorted { a, b in
            if a.element.rankingScore != b.element.rankingScore { return a.element.rankingScore > b.element.rankingScore }
            return a.offset < b.offset
        }.map(\.element)
        let top = ranked[0]
        guard ranked.count > 1 else { return [top] }
        let second = ranked[1]
        if top.rankingScore - second.rankingScore >= clearLead { return [top] }
        // An exact name is what was meant, ahead of names that only start the same way.
        if top.strength == .exact, second.strength != .exact, !second.wasPickedForSubject { return [top] }
        guard hasVerb || length >= 3 || learned else { return [] }
        let close = ranked.filter { top.rankingScore - $0.rankingScore < choiceWindow }
        return Array(close.prefix(maximumChoices))
    }
}

/// Runs the providers over an input and applies the rule.
public struct InstantActionEngine: Sendable {
    public var providers: [any InstantActionProvider]

    public init(providers: [any InstantActionProvider]) {
        self.providers = providers
    }

    public var verbs: Set<String> { providers.reduce(into: []) { $0.formUnion($1.verbs) } }

    /// The suggestion for the input, or nil when it should go to the agent.
    public func suggestion(for input: String, history: InstantActionHistory = InstantActionHistory(), now: Date = Date()) -> InstantActionSuggestion? {
        guard let phrase = InstantPhrase.parse(input, verbs: verbs) else { return nil }
        var candidates: [InstantActionCandidate] = []
        for provider in providers {
            if let verb = phrase.verb, !provider.verbs.contains(verb) { continue }
            candidates += provider.candidates(for: phrase)
        }
        candidates = candidates.map { candidate in
            var candidate = candidate
            candidate.boost = history.boost(for: candidate.id, subject: phrase.key, now: now)
            candidate.wasPickedForSubject = history.wasPicked(candidate.id, for: phrase.key)
            return candidate
        }
        let choices = InstantActionRule.choices(for: phrase, candidates: candidates)
        guard !choices.isEmpty else { return nil }
        return InstantActionSuggestion(input: input, phrase: phrase, choices: choices)
    }
}
