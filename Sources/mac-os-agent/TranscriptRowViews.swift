import MacOSAgentCore
import SwiftUI

/// One row of the history.
struct RowView: View {
    let row: TranscriptRow
    let now: Date

    var body: some View {
        switch row.kind {
        case .episodeStart(let date):
            EpisodeSeparator(date: date, now: now)
        case .user(let text, let date, let showsTime):
            OwnerMessage(text: text, date: date, showsTime: showsTime, now: now)
        case .assistant(let text):
            AgentMessage(text: text)
        case .tool(let command, let status, let output):
            ToolLine(command: command, state: ToolCallState(status: status, output: output), output: output)
        case .notice(let text):
            StatusLine(text: text, isError: false)
        case .error(let text):
            StatusLine(text: text, isError: true)
        }
    }
}

/// Shared look of the two kinds of message box.
enum MessageStyle {
    static let cornerRadius: CGFloat = 14
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 8
    /// The room a box leaves on its far side, so the two kinds sit on opposite sides.
    static let farSideInset: CGFloat = 56
    /// Between a box and the copy control beside it.
    static let controlGap: CGFloat = 8
}

/// What the owner typed: a box on the right with a faint accent tint. A time label sits above
/// the first message of each stretch, and every message shows its full time on hover.
struct OwnerMessage: View {
    let text: String
    let date: Date
    let showsTime: Bool
    let now: Date
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 8) {
            if showsTime {
                Text(TranscriptTimeLabel.text(for: date, now: now))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
            HStack(spacing: 0) {
                Spacer(minLength: MessageStyle.farSideInset)
                Text(verbatim: text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, MessageStyle.horizontalPadding)
                    .padding(.vertical, MessageStyle.verticalPadding)
                    // The system accent, which stays in color while the app is inactive. The
                    // panel never activates the app, so `Color.accentColor` would turn gray.
                    .background(Color(nsColor: .controlAccentColor).opacity(0.3), in: .rect(cornerRadius: MessageStyle.cornerRadius))
                    .overlay {
                        if contrast == .increased {
                            RoundedRectangle(cornerRadius: MessageStyle.cornerRadius)
                                .strokeBorder(Color(nsColor: .controlAccentColor), lineWidth: 1)
                        }
                    }
                    .help(TranscriptTimeLabel.fullText(for: date))
                    .contextMenu { MessageMenu(source: text, plainText: nil) }
                    // The copy control sits in the empty room to the box's left, so showing it
                    // moves nothing.
                    .overlay(alignment: .topLeading) {
                        CopyControl(help: "Copy the message") { text }
                            .revealed(when: hovering)
                            .fixedSize()
                            // A frame with no width at the box's edge, with the control hanging
                            // out of it to the left.
                            .frame(width: 0, alignment: .trailing)
                            .offset(x: -MessageStyle.controlGap)
                            .padding(.top, MessageStyle.verticalPadding)
                    }
            }
            .onHover { hovering = $0 }
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: "Copy") { MessageActions.copy(text) }
        }
    }
}

/// What the agent said to the owner, as Markdown: a box on the left with a neutral tint that
/// sets it apart from the glass behind it. While it streams it is parsed with its unfinished
/// end completed, so it keeps its shape as the rest arrives.
struct AgentMessage: View {
    let text: String
    var streaming = false
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false

    var body: some View {
        let document = MarkdownCache.document(for: text, streaming: streaming)
        HStack(spacing: 0) {
            MarkdownView(document: document)
                .padding(.horizontal, MessageStyle.horizontalPadding)
                .padding(.vertical, MessageStyle.verticalPadding)
                .background(.primary.opacity(contrast == .increased ? 0.17 : 0.13), in: .rect(cornerRadius: MessageStyle.cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: MessageStyle.cornerRadius)
                    .strokeBorder(.primary.opacity(contrast == .increased ? 0.35 : 0.1), lineWidth: 1))
                .contextMenu { MessageMenu(source: text, plainText: document.plainText) }
                // The copy control sits in the empty room to the box's right, so showing it
                // moves nothing. It copies the Markdown as the agent wrote it.
                .overlay(alignment: .topTrailing) {
                    if !streaming {
                        CopyControl(help: "Copy the reply as Markdown") { text }
                            .revealed(when: hovering)
                            .fixedSize()
                            // A frame with no width at the box's edge, with the control hanging
                            // out of it to the right.
                            .frame(width: 0, alignment: .leading)
                            .offset(x: MessageStyle.controlGap)
                            .padding(.top, MessageStyle.verticalPadding)
                    }
                }
            Spacer(minLength: MessageStyle.farSideInset)
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Copy as Markdown") { MessageActions.copy(text) }
        .accessibilityAction(named: "Copy as plain text") { MessageActions.copy(document.plainText) }
    }
}

/// A command the agent ran, in the scheme of Pi's tool rows: one quiet line that starts with
/// `›`, or `✗` when it failed, with the program in the secondary level and the rest in the
/// tertiary. A state that needs words, such as why it failed or that it is waiting for a
/// go-ahead, adds one `└` line beneath the command. Clicking the row opens its output in an
/// open bracket below it.
struct ToolLine: View {
    let command: String
    let state: ToolCallState
    let output: String?
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            header
            if let branch = state.branchText, !expanded {
                BranchLine(text: branch, style: isFailed ? .secondary : .tertiary)
                    .accessibilityHidden(true)
            }
            if expanded, let output {
                CodeBracket(font: .system(size: 10.5, design: .monospaced)) {
                    ScrollView(.horizontal) {
                        Text(verbatim: output)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize()
                            .padding(.trailing, 8)
                    }
                    .scrollIndicators(.automatic)
                }
                .padding(.leading, Mark.rowColumn)
                .padding(.top, 2)
            }
        }
        .padding(.leading, MessageStyle.horizontalPadding)
    }

    private var isFailed: Bool {
        if case .failed = state { true } else { false }
    }

    private var header: some View {
        let line = HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: isFailed ? Mark.failed : Mark.call)
                .foregroundStyle(isFailed ? HierarchicalShapeStyle.primary : .tertiary)
                .frame(width: Mark.rowColumn, alignment: .leading)
                .accessibilityHidden(true)
            commandText
                .lineLimit(expanded ? nil : 1)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: expanded)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Mark.rowFont)
        .contentShape(.rect)

        return Group {
            if output != nil {
                Button(action: toggle) { line }
                    .buttonStyle(.plain)
                    .help(expanded ? "Hide output" : "Show output")
                    .accessibilityHint(expanded ? "Hides the output" : "Shows the output")
            } else {
                line
            }
        }
        .contextMenu {
            if !command.isEmpty {
                Button("Copy Command") { MessageActions.copy(command) }
            }
            if let output {
                Button("Copy Output") { MessageActions.copy(output) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(command.isEmpty ? "Preparing a command" : "Command: \(command)")
        .accessibilityValue(state.accessibilityText)
        .accessibilityAction(named: "Copy command") { MessageActions.copy(command) }
    }

    @ViewBuilder private var commandText: some View {
        if command.isEmpty {
            Text("Preparing a command…").foregroundStyle(.tertiary)
        } else if state == .declined || state == .stopped {
            // It never ran, so it reads as struck out.
            Text(verbatim: command).strikethrough().foregroundStyle(.tertiary)
        } else {
            ToolSignal.text(for: command)
        }
    }

    private func toggle() {
        if reduceMotion { expanded.toggle() } else { withAnimation(.snappy(duration: 0.18)) { expanded.toggle() } }
    }
}

/// A line the app adds itself: "Stopped.", or an error, which starts with `✗`.
struct StatusLine: View {
    let text: String
    let isError: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if isError {
                Text(verbatim: Mark.failed)
                    .font(Mark.rowFont)
                    .foregroundStyle(.primary)
                    .frame(width: Mark.rowColumn, alignment: .leading)
                    .accessibilityHidden(true)
            }
            Text(verbatim: text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, MessageStyle.horizontalPadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isError ? "Error: \(text)" : text)
    }
}
