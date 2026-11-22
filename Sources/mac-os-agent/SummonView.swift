import AppKit
import MacOSAgentCore
import SwiftUI

/// A conversation window's content on Liquid Glass: the bar along the top and its divider, the
/// history, the go-ahead card when one is pending, the instant action row or the command hint,
/// and the text field at the bottom.
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

    var body: some View {
        VStack(spacing: 0) {
            PanelTopBar(incognito: session.isIncognito
                ? .init(canClear: canClear, clear: { session.requestDiscard(.clear) })
                : nil)
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
            InstantActionRow(actions: session.instantActions)
            CommandHint(suggestions: SlashCommand.suggestions(for: session.draft), incognito: session.isIncognito)
            PanelDivider()
            inputRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        }
        .onExitCommand(perform: onDismiss)
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
            // A prompt mark in the text color, in the scheme of the tool rows.
            Text(verbatim: Mark.prompt)
                .font(.system(size: 17, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: InputField.rowHeight)
                .accessibilityHidden(true)
            InputField(
                text: $session.draft,
                placeholder: placeholder,
                isEnabled: !session.isRunning,
                focusRequest: focusRequest,
                onSubmit: session.submit,
                onCancel: onDismiss,
                onMove: { offset in inspector?.move(by: offset) ?? false },
                onSubmitToAgent: session.submitToAgent,
                onChoose: { offset in session.instantActions.move(by: offset) })
                .overlay(alignment: .topLeading) {
                    if session.draft.isEmpty {
                        Text(placeholder)
                            .font(.system(size: 15))
                            .foregroundStyle(.tertiary)
                            .padding(.top, InputField.verticalInset)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            if session.isRunning {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Button("Stop", action: session.stop)
                        .buttonStyle(.glass)
                        .keyboardShortcut(".", modifiers: .command)
                }
                .frame(height: InputField.rowHeight)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button(discard == .close ? "Stop and Close" : "Stop and Clear") { session.confirmDiscard() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .background(palette.goAheadFill, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(palette.goAheadEdge, lineWidth: 1))
    }
}

/// The commands that match what the owner is typing, such as `/new` after a slash. It shows
/// nothing until the text starts with a slash. The incognito window describes them as they
/// act there.
private struct CommandHint: View {
    let suggestions: [SlashCommand]
    let incognito: Bool

    var body: some View {
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(suggestions, id: \.self) { command in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(command.name)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 80, alignment: .leading)
                        Text(incognito ? command.incognitoSummary : command.summary)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 44)
            .padding(.trailing, 16)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        }
    }
}

private struct ConfirmationCard: View {
    let request: ConfirmationRequest
    let session: AgentSession
    @Environment(\.panelPalette) private var palette

    private var commandText: some View {
        Text(verbatim: request.command)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Run this command? It \(request.reason).")
                .foregroundStyle(.primary)
            CodeBracket(font: .system(size: 12, design: .monospaced)) {
                // A short command shows whole. A long one scrolls within a few lines.
                ViewThatFits(in: .vertical) {
                    commandText
                    ScrollView { commandText }
                        .scrollBounceBehavior(.basedOnSize)
                }
                .frame(maxHeight: 120)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Don’t Run") { session.resolveConfirmation(false) }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button("Run") { session.resolveConfirmation(true) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .background(palette.goAheadFill, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(palette.goAheadEdge, lineWidth: 1))
    }
}
