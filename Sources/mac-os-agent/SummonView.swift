import AppKit
import MacOSAgentCore
import SwiftUI

/// The panel's content on Liquid Glass: the bar along the top, the incognito indicator while
/// one is on, the thread's history, the go-ahead card when one is pending, the command hint,
/// and the text field at the bottom.
struct SummonView: View {
    @Bindable var session: AgentSession
    var onDismiss: () -> Void = {}
    /// Changes whenever the text field should take keyboard focus.
    @State private var focusRequest = 0
    /// The reference time for the history's time labels, refreshed on every summon.
    @State private var now = Date()

    var body: some View {
        VStack(spacing: 0) {
            PanelTopBar()
            if session.isIncognito {
                IncognitoIndicator()
            }
            HistoryView(session: session, now: now)
            if let request = session.pendingConfirmation {
                ConfirmationCard(request: request, session: session)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
            CommandHint(suggestions: SlashCommand.suggestions(for: session.draft))
            Divider().opacity(0.5)
            inputRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A faint tint on the glass, with the indicator, keeps incognito in sight the whole time.
        .glassEffect(session.isIncognito ? .regular.tint(IncognitoIndicator.tint) : .regular,
                     in: .rect(cornerRadius: SummonPanel.cornerRadius))
        .onChange(of: session.focusRequest, initial: true) {
            now = Date()
            focusRequest += 1
        }
        .onChange(of: session.isRunning) { _, running in
            if !running { focusRequest += 1 }
        }
        .onExitCommand(perform: onDismiss)
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
                onCancel: onDismiss)
                .overlay(alignment: .topLeading) {
                    if session.draft.isEmpty {
                        Text(placeholder)
                            .font(.system(size: 15))
                            .foregroundStyle(Color(nsColor: .placeholderTextColor))
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

    /// An incognito episode says so where the owner types, too.
    private var placeholder: String {
        session.isIncognito ? "Incognito. Tell your Mac what to do" : "Tell your Mac what to do"
    }
}

/// Shows for as long as an incognito episode is on, above the history.
private struct IncognitoIndicator: View {
    static let tint = Color.indigo.opacity(0.14)

    var body: some View {
        Text("Incognito. Nothing from this episode is kept.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.primary.opacity(0.07), in: .capsule)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The commands that match what the owner is typing, such as `/new` after a slash. It shows
/// nothing until the text starts with a slash.
private struct CommandHint: View {
    let suggestions: [SlashCommand]

    var body: some View {
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(suggestions, id: \.self) { command in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(command.name)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 80, alignment: .leading)
                        Text(command.summary)
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
    @Environment(\.colorSchemeContrast) private var contrast

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
        .background(.primary.opacity(0.08), in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(contrast == .increased ? 0.4 : 0.16), lineWidth: 1))
    }
}
