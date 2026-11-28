import AppKit
import MacOSAgentCore
import Observation

/// One row of the list under the text field.
enum SuggestionRow: Equatable, Identifiable {
    /// An app or a quick action, which Return takes without the model.
    case candidate(InstantActionCandidate)
    /// The last row of an instant action list: Return sends the typed text to the agent.
    case ask(String)
    /// A slash command, which Return completes or runs as it does today.
    case command(SlashCommandItem)

    var id: String {
        switch self {
        case .candidate(let candidate): "candidate:" + candidate.id
        case .ask: "ask"
        case .command(let item): "command:" + item.name
        }
    }
}

/// The state of the list under the text field, for the suggestions-in-the-field experiment
/// (`Experiment.suggestionsInFieldAndFooter`). One per window.
///
/// Whether instant action matches are listed is the owner's choice: Down Arrow opens the
/// list, and Up from its first row or Escape closes it. Slash commands are listed whenever
/// the text starts with a slash, as the owner asked for a list by typing one.
///
/// The window decides where the list goes. When it can grow downward by the list's height, it
/// does, and sets `growth` to that height, so the list sits between the text field and the
/// footer and nothing above it moves. When it cannot, `growth` stays zero and the list is
/// drawn over the bottom of the conversation, just above the text field.
@MainActor
@Observable
final class SuggestionListState {
    /// True while the owner has the instant action list open.
    private(set) var isOpen = false
    /// The highlighted row of the instant action list.
    private(set) var highlight = 0
    /// True while an input method composes in the field. See `AgentSession.composingChanged(_:)`.
    var isComposing = false
    /// How far the window has grown downward to hold the list. Set by the window only.
    var growth: CGFloat = 0
    /// With the panel with bars on: how far the match card may reach below the panel's bottom
    /// edge, on the panel's screen, less a margin. The card is shortened to fit it, and opens
    /// upward when it holds less than two rows and a part. Zero in slide over, while hidden or sliding,
    /// and when the panel is at the bottom of the screen. Set by the window only.
    var roomBelow: CGFloat = 0
    /// With the panel with bars on: the room above the pill, up to the title bar, that the card
    /// may cover when it opens upward, with room below for less than two rows and a part. Set by the view.
    var roomAbove: CGFloat = .greatestFiniteMagnitude
    /// With the panel with bars on: the pill's frame in the panel's content, top-left origin.
    /// Set by the view, read by the window to put the card's lower part under it.
    @ObservationIgnored var pillFrame: CGRect = .zero
    /// For previews: the room below the panel the match card has, wherever the panel is, in
    /// place of the room on the screen it is drawn on.
    @ObservationIgnored var previewRoomBelow: CGFloat?
    /// For previews and tests: the experiment's switch, in place of the preferences.
    @ObservationIgnored var forcedOn: Bool?
    /// Called after a key opened, moved, or closed the list, so the window grows or shrinks in
    /// the same turn. Changes from typing reach the window through observation instead.
    @ObservationIgnored var layoutNeedsUpdate: (() -> Void)?
    /// The matches listed, by id, so typing can keep the highlight on the same one.
    @ObservationIgnored fileprivate var listedIDs: [String] = []

    fileprivate func open(listing ids: [String]) {
        isOpen = true
        highlight = 0
        listedIDs = ids
    }

    fileprivate func close() {
        isOpen = false
        highlight = 0
        listedIDs = []
    }

    fileprivate func setHighlight(_ index: Int) {
        if highlight != index { highlight = index }
    }
}

extension AgentSession {
    /// Whether the experiment is on for this window. Read each time, so the switch in Settings
    /// applies at once. The panel with bars uses the gray completion, the status line, and the
    /// list, so it turns them on whatever this experiment's own switch says.
    var suggestionsInFooter: Bool {
        panelWithBars || (suggestionList.forcedOn ?? Experiment.suggestionsInFieldAndFooter.isOn(preferences))
    }

    /// Matches the draft as eagerly as the switch says: from the first character with the
    /// experiment on, and only when confident with it off, since the row above the field pushes
    /// the conversation up. Called before every evaluation of the draft.
    func syncInstantActionMode() {
        instantActions.setMode(suggestionsInFooter ? .inField : .row)
    }

    /// True while the panel shows a suggestion for the draft: slash commands, the instant action
    /// row, or with suggestions in the field, the gray completion or the list under the field.
    /// Up and Down never recall an earlier message then. See `recallMessage(by:)`.
    var isShowingSuggestion: Bool {
        if !commandSuggestions.isEmpty { return true }
        if suggestionsInFooter { return suggestionList.isOpen || listedMatches != nil }
        return instantActions.suggestion != nil
    }

    /// The rows the list shows now, or none when it is closed. Slash commands come first: a
    /// slash rules out an instant action.
    var suggestionRows: [SuggestionRow] {
        guard suggestionsInFooter else { return [] }
        let commands = commandSuggestions
        if !commands.isEmpty { return commands.map(SuggestionRow.command) }
        guard suggestionList.isOpen, let matches = listedMatches else { return [] }
        return matches.map(SuggestionRow.candidate) + [.ask(draft)]
    }

    /// An input method started or stopped composing in the field. While it composes, the
    /// draft holds what is being composed, so nothing is suggested for it: no mark, no gray
    /// text, no list, and the footer says what it says for typing.
    func composingChanged(_ composing: Bool) {
        guard composing != suggestionList.isComposing else { return }
        suggestionList.isComposing = composing
        if composing { _ = closeSuggestionList() }
    }

    /// The instant action matches for the draft as it is, when Return could take one.
    private var listedMatches: [InstantActionCandidate]? {
        guard !isRunning, !suggestionList.isComposing, let suggestion = instantActions.suggestion, suggestion.input == draft,
              !suggestion.matches.isEmpty else { return nil }
        return suggestion.matches
    }

    /// Which row is highlighted: the chosen command, or the instant action list's highlight.
    var highlightedRowIndex: Int {
        let rows = suggestionRows
        guard !rows.isEmpty else { return 0 }
        if case .command = rows[0] { return min(hintSelection, rows.count - 1) }
        return min(suggestionList.highlight, rows.count - 1)
    }

    var highlightedRow: SuggestionRow? {
        let rows = suggestionRows
        return rows.isEmpty ? nil : rows[highlightedRowIndex]
    }

    /// The app or quick action Return will act on now, which the mark beside the field shows
    /// and the gray text names. Nil when Return sends the text as a message, completes a
    /// command, or does nothing, and always nil with the experiment off.
    var returnTarget: InstantActionCandidate? {
        guard suggestionsInFooter, commandSuggestions.isEmpty, let matches = listedMatches else { return nil }
        if suggestionList.isOpen {
            if case .candidate(let candidate) = highlightedRow { return candidate }
            return nil
        }
        // What Return takes with the list closed, as `InstantActions.take(for:)` takes it.
        guard let suggestion = instantActions.suggestion else { return matches[0] }
        return suggestion.choices[min(instantActions.selection, suggestion.choices.count - 1)]
    }

    /// The gray text after the insertion point: the rest of the highlighted command's name, or
    /// the rest of the word and the name of what Return will act on. The field decides whether
    /// the insertion point is where it can show.
    var inlineCompletion: InlineCompletion? {
        guard suggestionsInFooter else { return nil }
        if case .command(let item) = highlightedRow { return InlineCompletion.forCommand(item.name, typed: draft) }
        guard let target = returnTarget else { return nil }
        return InlineCompletion.forName(target.title, typed: draft)
    }

    /// Up (-1) or Down (1), and Shift-Tab or Tab, while the field has text, with the
    /// experiment on. Returns true when it used the key.
    /// - The slash command list keeps its keys as they are.
    /// - While Up and Down move through earlier messages, they belong to that.
    /// - With the list open, they move the highlight. Up from the first row closes the list.
    ///   Down stops at the last row.
    /// - With the list closed, Down opens it when there is at least one match.
    func chooseInFooter(by offset: Int) -> Bool {
        if !commandSuggestions.isEmpty { return moveHintSelection(by: offset) }
        guard !isRecallingMessage else { return false }
        if suggestionList.isOpen {
            let count = suggestionRows.count
            guard count > 0 else {
                _ = closeSuggestionList()
                return false
            }
            let next = suggestionList.highlight + (offset < 0 ? -1 : 1)
            if next < 0, panelWithBars {
                // The card has no closed state to go back to while there is a match: Up stops
                // at the first row, as Down stops at the last.
                return true
            } else if next < 0 {
                _ = closeSuggestionList()
            } else {
                suggestionList.setHighlight(min(next, count - 1))
            }
            suggestionList.layoutNeedsUpdate?()
            return true
        }
        guard offset > 0, let matches = listedMatches else { return false }
        suggestionList.open(listing: matches.map(\.id))
        suggestionList.layoutNeedsUpdate?()
        return true
    }

    /// Closes the instant action list. Returns true when it was open, so Escape stops there.
    @discardableResult
    func closeSuggestionList() -> Bool {
        guard suggestionList.isOpen else { return false }
        suggestionList.close()
        suggestionList.layoutNeedsUpdate?()
        return true
    }

    /// Typing keeps the list open and filters it again. The highlight stays on the same match
    /// when it is still listed, and goes back to the first otherwise. With nothing matching,
    /// the list closes.
    func suggestionListFollowsDraft() {
        // With the panel with bars, the card is there as soon as there is a match: no key opens it.
        if panelWithBars, !suggestionList.isOpen, let matches = listedMatches {
            suggestionList.open(listing: matches.map(\.id))
            return
        }
        guard suggestionList.isOpen else { return }
        guard suggestionsInFooter, let matches = listedMatches else {
            suggestionList.close()
            return
        }
        // The highlight before the change, by the match it was on. On the Ask row it stays
        // on the Ask row.
        let previous = suggestionList.highlight
        let listed = suggestionList.listedIDs
        let index: Int
        if previous >= listed.count {
            index = matches.count
        } else {
            index = matches.firstIndex { $0.id == listed[previous] } ?? 0
        }
        suggestionList.setHighlight(index)
        suggestionList.listedIDs = matches.map(\.id)
    }

    /// Return with the list open: acts on the highlighted row. A match is taken as Return
    /// takes the suggestion, and the Ask row sends the text to the agent. Returns false when
    /// the list is not open, so Return does what it always does.
    func submitFromSuggestionList() -> Bool {
        guard suggestionsInFooter, suggestionList.isOpen, !isRunning else { return false }
        switch highlightedRow {
        case .candidate(let candidate):
            guard let taken = instantActions.take(candidate, for: draft) else { return false }
            suggestionList.close()
            perform(taken)
            suggestionList.layoutNeedsUpdate?()
            return true
        case .ask:
            suggestionList.close()
            submitToAgent()
            suggestionList.layoutNeedsUpdate?()
            return true
        case .command, nil:
            return false
        }
    }

    /// A click on a row: the same as Return on it.
    func activateSuggestionRow(_ index: Int) {
        let rows = suggestionRows
        guard index >= 0, index < rows.count else { return }
        switch rows[index] {
        case .command(let item):
            complete(item)
        case .candidate, .ask:
            suggestionList.setHighlight(index)
            submit()
        }
    }

    /// The height of the list under the field, or zero when nothing is listed.
    var suggestionListHeight: CGFloat {
        SuggestionListView.height(rowCount: SuggestionListView.visibleRows(suggestionRows.count))
    }
}
