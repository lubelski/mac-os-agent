import AppKit
import MacOSAgentCore
import SwiftUI

/// A conversation window's content on Liquid Glass: the bar along the top and its divider, the
/// history, the go-ahead card when one is pending, the instant action row or the command hint,
/// and the text field at the bottom.
///
/// With the panel with bars experiment on, the top bar is a title bar and the text field is a
/// pill in a band at the bottom, with the status line under it. See `PanelFrame`.
///
/// The main panel and the incognito window are both this view, over sessions of different
/// kinds. The incognito window adds its label and Clear to the top bar, the theme's incognito
/// tint for its whole life, and a question before closing or clearing while a task runs.
struct SummonView: View {
    @Bindable var session: AgentSession
    var onDismiss: () -> Void = {}
    @Environment(ToolInspector.self) private var inspector: ToolInspector?
    /// Changes whenever the text field should take keyboard focus.
    @State private var focusRequest = 0
    /// The reference time for the history's time labels, refreshed on every summon.
    @State private var now = Date()
    /// Read here so the panel redraws when a switch changes in Settings. The session reads the
    /// switches from its own preferences.
    @AppStorage(Experiment.suggestionsInFieldAndFooter.key) private var suggestionsSwitch = false
    @AppStorage(Experiment.panelWithBarsAndInputPill.key) private var barsSwitch = false
    @Environment(PanelPlacement.self) private var placement: PanelPlacement?
    @AppStorage(HarnessBehavior.recallEarlierMessages.key) private var recallSwitch = HarnessBehavior.recallEarlierMessages.defaultValue
    @AppStorage(ModelSetting.key) private var modelID = OpenAIModel.defaultID
    @AgentName private var agentName

    var body: some View {
        VStack(spacing: 0) {
            PanelTopBar(
                incognito: session.isIncognito
                    ? .init(canClear: canClear, clear: { session.requestDiscard(.clear) })
                    : nil,
                style: session.panelWithBars ? .titled : .named)
            PanelDivider()
            HistoryView(session: session, now: now)
            if let discard = session.pendingDiscard {
                DiscardCard(discard: discard, session: session)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            } else if let request = session.pendingConfirmation {
                ConfirmationCard(request: request, session: session)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
            // With the panel with bars on, queued messages are in the conversation instead.
            if session.queuedMessagePlacement == .aboveField {
                MessageQueueRows(session: session)
            }
            if session.panelWithBars {
                // The band: the hairline, then the pill on the bars' fill, then the status line.
                // Nothing is added above the hairline. A match opens the pill into the match
                // card, upward over the conversation here, or downward in a window of its own.
                VStack(spacing: 0) {
                    PanelDivider()
                    InputBand {
                        TaskLinksRow(links: session.taskLinks, clear: session.clearTaskLinks)
                    } field: {
                        InputPill(card: session.matchCardSide) { field(metrics: .pill) }
                            .overlay(alignment: .top) { matchCardAbove }
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.panelSpace)) } action: { pill in
                                session.suggestionList.pillFrame = pill
                                let above = pill.minY - PanelTopBar.height - 1
                                if session.suggestionList.roomAbove != above { session.suggestionList.roomAbove = above }
                                let update = session.suggestionList.layoutNeedsUpdate
                                DispatchQueue.main.async { update?() }
                            }
                    }
                }
                footer
            } else if session.suggestionsInFooter {
                // The suggestions are in the field and the footer, so nothing is added above it.
                VStack(spacing: 0) {
                    PanelDivider()
                    inputRow
                }
                .overlay(alignment: .top) { overlaidList }
                listBelow
                footer
            } else {
                InstantActionRow(actions: session.instantActions)
                CommandHint(
                    suggestions: session.commandSuggestions, selection: session.hintSelection,
                    incognito: session.isIncognito, choose: session.complete)
                PanelDivider()
                inputRow
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(.named(Self.panelSpace))
        // A faint tint on the surface, with the label in the top bar, keeps the incognito window
        // apart from the main panel for its whole life.
        .themedPanel(incognito: session.isIncognito)
        .onChange(of: session.focusRequest, initial: true) {
            now = Date()
            // A theme file edited in place, which the folder watch misses, shows on the next summon.
            ThemeModel.shared.reload()
            focusRequest += 1
        }
        .onChange(of: session.isRunning) { _, running in
            if !running { focusRequest += 1 }
            // A match in the field when a task ends opens the card again.
            if session.panelWithBars { session.suggestionListFollowsDraft() }
        }
        .onExitCommand(perform: onDismiss)
        // The experiment matches from the first character and the row only when confident, so
        // a draft already in the field is judged again when the switch changes in Settings.
        .onChange(of: suggestionsSwitch) { session.syncInstantActionMode() }
        // The panel with bars turns that matching on too, and has a larger outer radius, which
        // the surface and the window's clip read from the placement.
        .onChange(of: barsSwitch, initial: true) {
            placement?.cornerRadius = PanelFrame.cornerRadius(panelWithBars: session.panelWithBars)
            session.syncInstantActionMode()
            // The match card opens by itself for a match already in the field.
            if session.panelWithBars { session.suggestionListFollowsDraft() }
        }
        // VoiceOver hears what Return will act on when it changes, since the gray text is drawn
        // only and the mark is beside the field.
        .onChange(of: session.returnTarget?.id) {
            guard let target = session.returnTarget else { return }
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
                .announcement: "Return \(target.target.actionLabel) \(target.title)",
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
        }
        // The inspector shows a call from the history in view. Clearing an incognito
        // conversation drops that history, so the inspector closes.
        .onChange(of: session.conversation) { inspector?.close() }
    }

    /// Whether the incognito window has anything to clear: a row past the opening separator,
    /// a reply on its way, or a draft.
    private var canClear: Bool {
        session.transcript.rows.contains { !$0.isEpisodeStart } || session.isRunning || !session.draft.isEmpty
    }

    private var inputRow: some View {
        HStack(alignment: .top, spacing: 10) {
            // The field holds one icon and the text. The icon is the sparkle, and with the
            // suggestions experiment on, the icon of what Return will act on takes its place.
            InputMark(target: session.returnTarget)
            field(metrics: .standard)
            // Nothing else goes in the field. Stop is at the end of the thread, on the working row.
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        // The band with the field is on the bars' fill, as the top bar is. With the experiment
        // on, the list and the footer below continue it.
        .background(PanelBarFill())
    }

    /// The text field itself, with its placeholder, in the field's font.
    private func field(metrics: InputFieldMetrics) -> some View {
            InputField(
                text: $session.draft,
                placeholder: placeholder,
                // With the queue experiment on, the field stays open while a task runs.
                isEnabled: !session.isRunning || session.queuesWhileRunning,
                focusRequest: focusRequest,
                onSubmit: session.submit,
                onCancel: onDismiss,
                onMove: { offset in inspector?.move(by: offset) ?? false },
                onSubmitToAgent: session.submitToAgent,
                onChoose: { offset in
                    session.suggestionsInFooter
                        ? session.chooseInFooter(by: offset)
                        : session.moveHintSelection(by: offset) || session.instantActions.move(by: offset)
                },
                onComplete: session.completeHint,
                onCommandNumber: session.runMatchCardRow(number:),
                onRecall: session.recallMessage(by:),
                onInterrupt: session.interrupt,
                onDoubleDelete: session.startNewEpisodeFromKeys,
                onComposingChange: session.composingChanged,
                inlineCompletion: session.inlineCompletion,
                metrics: metrics)
                .overlay(alignment: .topLeading) {
                    if session.draft.isEmpty {
                        Text(placeholder)
                            .font(.system(size: metrics.font.pointSize))
                            .foregroundStyle(.tertiary)
                            .padding(.top, metrics.verticalInset)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
    }

    // MARK: The suggestions experiment

    private var footer: some View {
        // The switches are read through the session, from its preferences. Reading them here
        // too keeps the footer in step when one changes in Settings.
        _ = (suggestionsSwitch, recallSwitch, barsSwitch)
        // No hairline above it: the footer continues the band with the field on the same fill,
        // so the two read as one bar at the bottom of the panel.
        return InputFooter(content: .make(
            session.footerState, agentName: agentName, modelName: InputFooterContent.modelName(id: modelID),
            recallsMessages: HarnessBehavior.recallEarlierMessages.isOn(session.preferences),
            queuesWhileRunning: session.queuesWhileRunning,
            statusLine: session.panelWithBars))
    }

    private var suggestionList: some View {
        SuggestionListView(
            rows: session.suggestionRows, highlight: session.highlightedRowIndex, agentName: agentName,
            incognito: session.isIncognito, usesLogo: session.panelWithBars, activate: session.activateSuggestionRow)
    }

    /// The list between the field and the footer, in the room the window grew by. The room
    /// stays until the window shrinks, so nothing above it moves in between.
    @ViewBuilder private var listBelow: some View {
        let growth = session.suggestionList.growth
        if growth > 0 {
            ZStack(alignment: .top) {
                if !session.suggestionRows.isEmpty { suggestionList }
            }
            .frame(height: growth, alignment: .top)
            .frame(maxWidth: .infinity)
            .clipped()
            .background(PanelBarFill())
        }
    }

    /// The list drawn over the bottom of the conversation, just above the field, when the
    /// window has no room to grow downward. The conversation does not move or reflow.
    @ViewBuilder private var overlaidList: some View {
        if session.suggestionList.growth == 0, !session.suggestionRows.isEmpty {
            // Moved up by its own height, so its bottom meets the top of the field's divider.
            suggestionList
                .background(PanelBarFill(opaque: true))
                .offset(y: -session.suggestionListHeight)
        }
    }

    // MARK: The match card

    /// The panel's content, in which the pill's frame is measured for the match card's window.
    static let panelSpace = "panel"

    /// The rows of a match card that opens upward, over the end of the conversation, with their
    /// bottom on the pill's top. A card that opens downward is drawn by `MatchCardWindow`.
    @ViewBuilder private var matchCardAbove: some View {
        if session.matchCardSide == .above {
            let height = MatchCard.heightAbovePill(rows: session.matchCardVisibleRows)
            MatchCardAbove(session: session, agentName: agentName)
                .frame(height: height)
                .offset(y: -height)
        }
    }

    /// The incognito window says what it is for where the owner types, too.
    private var placeholder: String {
        session.isIncognito ? "Open an app or ask a question" : "Tell your Mac what to do"
    }
}

/// Asks before closing or clearing the incognito window while a task runs, since the task
/// stops and the conversation is gone. Escape, or Keep, answers no.
private struct DiscardCard: View {
    let discard: AgentSession.Discard
    let session: AgentSession
    @Environment(\.panelPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(discard == .close
                 ? "A task is still running. Stop it and close this window? Everything in it is discarded."
                 : "A task is still running. Stop it and clear this conversation? Everything in it is discarded.")
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(discard == .close ? "Keep Open" : "Keep") { session.cancelDiscard() }
                    .panelGlassButton()
                    .keyboardShortcut(.cancelAction)
                Button(discard == .close ? "Stop and Close" : "Stop and Clear") { session.confirmDiscard() }
                    .panelGlassButton(prominent: true)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .background(palette.goAheadFill, in: PanelShape.card)
        .overlay(PanelShape.card.strokeBorder(palette.goAheadEdge, lineWidth: 1))
    }
}

/// The commands that match what the owner is typing, such as `/new` after a slash, and in the
/// main panel the skills the owner can invoke, each with its description. It shows nothing
/// until the text starts with a slash. The chosen one is set on a faint capsule, the arrow keys
/// choose, Tab or Return puts it in the field, and a click does too. The incognito window
/// describes the app's commands as they act there, and has no skills.
struct CommandHint: View {
    let suggestions: [SlashCommandItem]
    let selection: Int
    let incognito: Bool
    var choose: (SlashCommandItem) -> Void = { _ in }
    @Environment(\.panelPalette) private var palette

    /// The most commands listed at once. The rest scroll into the list as the arrows reach them.
    static let visibleLimit = 6

    var body: some View {
        if !suggestions.isEmpty {
            let chosen = min(selection, suggestions.count - 1)
            let window = Self.window(count: suggestions.count, selection: chosen)
            let several = suggestions.count > 1
            VStack(alignment: .leading, spacing: 2) {
                // A grid keeps the descriptions in one column, however long the names are.
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 2) {
                    ForEach(window, id: \.self) { index in
                        let item = suggestions[index]
                        let isChosen = several && index == chosen
                        GridRow {
                            Text(verbatim: item.name)
                                .font(.system(size: 12, design: .monospaced))
                                // The weight stays the same whether chosen or not. Only the level
                                // and the capsule change.
                                .foregroundStyle(isChosen ? .primary : .secondary)
                                .lineLimit(1)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 1)
                                .background {
                                    if isChosen { Capsule().fill(palette.textTint(0.08)) }
                                }
                                .frame(minWidth: 94, alignment: .leading)
                            Text(verbatim: item.summary(incognito: incognito))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(.rect)
                        .onTapGesture { choose(item) }
                    }
                }
                if suggestions.count > window.count {
                    Text(verbatim: "\(suggestions.count - window.count) more   \(Mark.up)\(Mark.down) chooses   tab completes")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 7)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 37)
            .padding(.trailing, 16)
            .padding(.vertical, 8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText(chosen: chosen))
        }
    }

    /// The indexes listed: the first few, moved along so the chosen one is always in view.
    static func window(count: Int, selection: Int, limit: Int = visibleLimit) -> [Int] {
        guard count > limit else { return Array(0..<count) }
        let start = max(0, min(selection - limit + 1, count - limit))
        return Array(start..<(start + limit))
    }

    private func accessibilityText(chosen: Int) -> String {
        let item = suggestions[chosen]
        var text = "\(item.name), \(item.summary(incognito: incognito))."
        if suggestions.count > 1 {
            text += " \(suggestions.count) commands match. Up and Down choose. Tab completes."
        }
        return text + " Escape dismisses."
    }
}

struct ConfirmationCard: View {
    let request: ConfirmationRequest
    let session: AgentSession
    @Environment(\.panelPalette) private var palette

    private func selectable(_ text: String) -> some View {
        Text(verbatim: text)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A short body shows whole. A long one scrolls within a few lines.
    private func scrollsWhenLong(_ content: some View) -> some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
                .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxHeight: 120)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// One change per line, its action first in a column of its own.
    private func changeList(_ changes: [ConfirmationRequest.Change]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: change.action.rawValue)
                        .foregroundStyle(.primary)
                        .frame(minWidth: 50, alignment: .leading)
                    selectable(change.subject)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder private var requestBody: some View {
        switch request.body {
        case .command(let command):
            CodeBracket(font: .system(size: 12, design: .monospaced)) {
                scrollsWhenLong(selectable(command))
            }
        case .changes(let changes):
            scrollsWhenLong(changeList(changes))
                .font(.callout)
        case .item(let name, let detail):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: name).foregroundStyle(.primary)
                if let detail { selectable(detail) }
            }
            .font(.callout)
        case .toolCall(let server, let tool, let arguments):
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: tool).foregroundStyle(.primary)
                    selectable("on \(server)")
                }
                .font(.callout)
                CodeBracket(font: .system(size: 12, design: .monospaced)) {
                    scrollsWhenLong(selectable(arguments))
                }
            }
        case .setting(let change, let notes):
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: change).foregroundStyle(.primary)
                ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                    selectable(note)
                }
            }
            .font(.callout)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: request.prompt)
                .foregroundStyle(.primary)
            requestBody
            if let note = request.alwaysNote {
                Text(verbatim: note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Left to right from the strongest no to the plainest yes: Deny, Always Deny,
            // Always Allow, Allow Once. Return allows once and Escape denies.
            HStack {
                Spacer()
                Button(request.declineTitle) { session.resolveConfirmation(.deny) }
                    .panelGlassButton()
                    .keyboardShortcut(.cancelAction)
                if request.offersAlways {
                    Button(ConfirmationRequest.alwaysDenyTitle) { session.resolveConfirmation(.alwaysDeny) }
                        .panelGlassButton()
                    Button(ConfirmationRequest.alwaysAllowTitle) { session.resolveConfirmation(.alwaysAllow) }
                        .panelGlassButton()
                }
                Button(request.approveTitle) { session.resolveConfirmation(.allowOnce) }
                    .panelGlassButton(prominent: true)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .background(palette.goAheadFill, in: PanelShape.card)
        .overlay(PanelShape.card.strokeBorder(palette.goAheadEdge, lineWidth: 1))
    }
}
