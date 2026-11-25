import Foundation
import Testing
@testable import MacOSAgentCore

/// The ranked matches behind the list under the text field, and the gray text the field draws
/// after the insertion point, for the suggestions-in-the-field experiment.
struct SuggestionMatchesTests {
    private let engine = InstantActionEngine(providers: [ApplicationInstantActions(applications: standInApplications)])

    @Test(arguments: ["chr", "saf", "open safari", "cal", "no", "open g", "vsc", "mic", "term", "find"])
    func theMatchesStartWithTheChoicesInTheSameOrder(_ input: String) {
        guard let suggestion = engine.suggestion(for: input) else { return }
        #expect(suggestion.matches.first == suggestion.top, "the first match is what Return takes")
        #expect(Array(suggestion.matches.prefix(suggestion.choices.count)) == suggestion.choices)
        #expect(suggestion.matches.count <= InstantActionRule.maximumMatches)
        #expect(Set(suggestion.matches.map(\.id)).count == suggestion.matches.count)
    }

    @Test func aClearLeaderStillListsTheOthers() throws {
        // "chr" is Google Chrome by a clear lead, so the row offers it alone, and Canary is
        // one more match for the list.
        let suggestion = try #require(engine.suggestion(for: "chr"))
        #expect(suggestion.choices.map(\.title) == ["Google Chrome"])
        #expect(suggestion.matches.map(\.title).contains("Google Chrome Canary"))
    }

    @Test func theListIsCappedAtSix() throws {
        let suggestion = try #require(engine.suggestion(for: "open m"))
        #expect(suggestion.matches.count == InstantActionRule.maximumMatches)
    }

    @Test func inputThatOffersNothingListsNothing() {
        #expect(engine.suggestion(for: "c") == nil, "a single bare character offers nothing, so it lists nothing")
        #expect(engine.suggestion(for: "what is the weather") == nil)
        let phrase = InstantPhrase.parse("c", verbs: engine.verbs)!
        let evaluated = InstantActionRule.evaluate(phrase, candidates: ApplicationInstantActions(applications: standInApplications).candidates(for: phrase))
        #expect(evaluated.choices.isEmpty)
        #expect(evaluated.matches.isEmpty)
    }

    @Test func theChoicesAreWhatTheyWereBefore() {
        // `choices(for:candidates:)` is the rule as it was. The list adds to it and changes
        // nothing it returns.
        for input in ["chr", "cal", "open safari", "mic", "no"] {
            guard let phrase = InstantPhrase.parse(input, verbs: engine.verbs) else { continue }
            let candidates = ApplicationInstantActions(applications: standInApplications).candidates(for: phrase)
            #expect(InstantActionRule.choices(for: phrase, candidates: candidates) == InstantActionRule.evaluate(phrase, candidates: candidates).choices)
        }
    }
}

struct InlineCompletionTests {
    @Test func theRestOfTheWordThenTheWholeName() {
        #expect(InlineCompletion.forName("Google Chrome", typed: "chr") == InlineCompletion(rest: "ome", name: "Google Chrome"))
        #expect(InlineCompletion.forName("Google Chrome", typed: "CHR") == InlineCompletion(rest: "ome", name: "Google Chrome"))
        #expect(InlineCompletion.forName("Visual Studio Code", typed: "vs co") == InlineCompletion(rest: "de", name: "Visual Studio Code"))
    }

    @Test func noNameWhenTheWordSpellsIt() {
        #expect(InlineCompletion.forName("Safari", typed: "saf") == InlineCompletion(rest: "ari", name: nil))
        #expect(InlineCompletion.forName("Safari", typed: "Safari") == nil, "nothing to add")
        #expect(InlineCompletion.forName("Google Chrome", typed: "google chr") == InlineCompletion(rest: "ome", name: nil))
    }

    @Test func onlyTheNameWhenNoWordStartsWithWhatWasTyped() {
        #expect(InlineCompletion.forName("Visual Studio Code", typed: "vsc") == InlineCompletion(rest: "", name: "Visual Studio Code"))
        #expect(InlineCompletion.forName("Google Chrome", typed: "chr ") == InlineCompletion(rest: "", name: "Google Chrome"),
                "after a space there is no word to finish")
    }

    @Test func aVerbIsKeptAndTheNameShown() {
        #expect(InlineCompletion.forName("Safari", typed: "open saf") == InlineCompletion(rest: "ari", name: "Safari"))
    }

    @Test func aCommandCompletesItsName() {
        #expect(InlineCompletion.forCommand("/new", typed: "/ne") == InlineCompletion(rest: "w"))
        #expect(InlineCompletion.forCommand("/new", typed: "/") == InlineCompletion(rest: "new"))
        #expect(InlineCompletion.forCommand("/new", typed: "/NE") == InlineCompletion(rest: "w"))
        #expect(InlineCompletion.forCommand("/new", typed: "/new") == nil, "typed in full")
        #expect(InlineCompletion.forCommand("/rename-photos", typed: "/rename-photos these") == nil, "a skill's text is being typed")
        #expect(InlineCompletion.forCommand("/new", typed: "/x") == nil)
    }
}
