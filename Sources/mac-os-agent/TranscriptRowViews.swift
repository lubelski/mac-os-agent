import MacOSAgentCore
import SwiftUI

/// One row of the history.
struct RowView: View {
    let row: TranscriptRow
    let now: Date
    /// The command line a shell call ran, by call id, for Copy Command. Read only when the
    /// owner copies, so drawing a row never parses a call's arguments.
    var commandOfCall: (String) -> String? = { _ in nil }
    /// The words a call's row leads with when they are more than its first word, by call id,
    /// such as an MCP tool's display name.
    var leadOfCall: (String) -> String? = { _ in nil }

    var body: some View {
        switch row.kind {
        case .episodeStart(let date):
            EpisodeSeparator(date: date, now: now)
        case .user(let text, let date, let showsTime):
            OwnerMessage(text: text, date: date, showsTime: showsTime, now: now, images: row.images)
        case .assistant(let text):
            AgentMessage(text: text)
        case .tool(let command, let status, let output):
            ToolLine(
                callID: row.id, summary: command, lead: leadOfCall(row.id), state: ToolCallState(status: status, output: output),
                output: output, commandOfCall: commandOfCall)
        case .notice(let text):
            StatusLine(text: text, isError: false)
        case .error(let text):
            StatusLine(text: text, isError: true)
        case .line(let line):
            ConversationLine(line: line)
        }
    }
}

/// Shared look of the two kinds of message box.
enum MessageStyle {
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 8
    /// The room a box leaves on its far side, so the two kinds sit on opposite sides.
    static let farSideInset: CGFloat = 56
    /// Between a box and the copy control beside it.
    static let controlGap: CGFloat = 8
}

extension MessageLayout.LineAlignment {
    /// The alignment a line that is not a message takes across the conversation.
    var frameAlignment: Alignment { self == .center ? .center : .leading }
    var textAlignment: TextAlignment { self == .center ? .center : .leading }
    /// A line at the left starts where the text in a box starts.
    var leadingInset: CGFloat { self == .center ? 0 : MessageStyle.horizontalPadding }
}

/// What the owner typed: a box on the right with a faint accent tint, or across the full width
/// with the full width layout. A time label sits above the first message of each stretch, and
/// every message shows its full time on hover.
struct OwnerMessage: View {
    let text: String
    let date: Date
    let showsTime: Bool
    let now: Date
    /// The images sent with it, drawn as thumbnails above the box. A message of images alone
    /// has no box.
    var images: [ImageAttachment] = []
    @Environment(\.panelPalette) private var palette
    @Environment(\.messageLayout) private var layout
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 8) {
            if showsTime {
                Text(TranscriptTimeLabel.text(for: date, now: now))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, layout.timeLabelAlignment.leadingInset)
                    .frame(maxWidth: .infinity, alignment: layout.timeLabelAlignment.frameAlignment)
            }
            if !images.isEmpty {
                MessageImages(images: images)
                    .help(TranscriptTimeLabel.fullText(for: date))
            }
            if !text.isEmpty {
                if layout.boxesFillWidth { fullWidthTextBox } else { textBox }
            }
        }
    }

    /// The box across the full width. There is no room beside it, so the copy control sits
    /// inside it at the top right, and its room is kept while it is hidden, so showing it moves
    /// nothing.
    private var fullWidthTextBox: some View {
        HStack(alignment: .top, spacing: MessageStyle.controlGap) {
            Text(verbatim: text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            CopyControl(help: "Copy the message") { text }
                .revealed(when: hovering)
                .fixedSize()
        }
        .padding(.horizontal, MessageStyle.horizontalPadding)
        .padding(.vertical, MessageStyle.verticalPadding)
        .background(palette.ownerFill, in: PanelShape.message)
        .overlay { PanelShape.message.strokeBorder(palette.ownerEdge(layout), lineWidth: 1) }
        .help(TranscriptTimeLabel.fullText(for: date))
        .contextMenu { MessageMenu(source: text, plainText: nil) }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Copy") { MessageActions.copy(text) }
    }

    private var textBox: some View {
            HStack(spacing: 0) {
                Spacer(minLength: MessageStyle.farSideInset)
                Text(verbatim: text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, MessageStyle.horizontalPadding)
                    .padding(.vertical, MessageStyle.verticalPadding)
                    // The theme's fill and edge. Glass tints it with the system accent, and draws
                    // the edge only with Increase Contrast.
                    .background(palette.ownerFill, in: PanelShape.message)
                    .overlay {
                        PanelShape.message
                            .strokeBorder(palette.ownerEdge, lineWidth: 1)
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

/// What the agent said to the owner, as Markdown: a box on the left with a neutral tint that
/// sets it apart from the glass behind it, or across the full width with the full width layout. While it streams it is parsed with its unfinished
/// end completed, so it keeps its shape as the rest arrives.
struct AgentMessage: View {
    let text: String
    var streaming = false
    @Environment(\.panelPalette) private var palette
    @Environment(\.messageLayout) private var layout
    @State private var hovering = false

    var body: some View {
        let document = MarkdownCache.document(for: text, streaming: streaming)
        if layout.boxesFillWidth {
            fullWidth(document)
        } else {
            sides(document)
        }
    }

    /// The box across the full width, with the copy control inside it at the top right, as
    /// the owner's is. Its room is kept while the reply streams, so the finished reply that
    /// replaces it moves nothing.
    private func fullWidth(_ document: MarkdownDocument) -> some View {
        HStack(alignment: .top, spacing: MessageStyle.controlGap) {
            MarkdownView(document: document)
                .frame(maxWidth: .infinity, alignment: .leading)
            CopyControl(help: "Copy the reply as Markdown") { text }
                .revealed(when: hovering && !streaming)
                .opacity(streaming ? 0 : 1)
                .disabled(streaming)
                .accessibilityHidden(streaming)
                .fixedSize()
        }
        .padding(.horizontal, MessageStyle.horizontalPadding)
        .padding(.vertical, MessageStyle.verticalPadding)
        .background(palette.agentFill, in: PanelShape.message)
        .overlay(PanelShape.message.strokeBorder(palette.agentEdge(layout), lineWidth: 1))
        .contextMenu { MessageMenu(source: text, plainText: document.plainText) }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Copy as Markdown") { MessageActions.copy(text) }
        .accessibilityAction(named: "Copy as plain text") { MessageActions.copy(document.plainText) }
    }

    private func sides(_ document: MarkdownDocument) -> some View {
        HStack(spacing: 0) {
            MarkdownView(document: document)
                .padding(.horizontal, MessageStyle.horizontalPadding)
                .padding(.vertical, MessageStyle.verticalPadding)
                .background(palette.agentFill, in: PanelShape.message)
                .overlay(PanelShape.message
                    .strokeBorder(palette.agentEdge, lineWidth: 1))
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

/// A tool call the agent made, in the scheme of Pi's tool rows: one quiet line that starts with
/// `›`, or `✗` when it failed, then the tool's summary, with its first word in the secondary
/// level and the rest in the tertiary, such as `Open Safari` or `Bash du -sh ~/Movies`. Every
/// tool's row is drawn the same way. A state that needs words, such as why it failed or that it is waiting for a
/// go-ahead, adds one `└` line beneath the command. Opening the row, with a click or with
/// Return or Space when it has keyboard focus, shows the call in the inspector beside the
/// panel. The row never grows in place. The call the inspector shows has a faint fill.
struct ToolLine: View {
    @Environment(\.panelPalette) private var palette
    let callID: String
    /// The tool's one-line summary of the call. Empty while the model is still writing it.
    let summary: String
    /// The words the summary leads with when they are more than its first word.
    var lead: String?
    let state: ToolCallState
    let output: String?
    let commandOfCall: (String) -> String?
    @Environment(ToolInspector.self) private var inspector: ToolInspector?
    @Environment(\.pendingGoAhead) private var pendingGoAhead

    private var isSelected: Bool { inspector?.selectedCallID == callID }

    private var branchText: String? {
        state.branchText(pendingGoAhead: pendingGoAhead, callID: callID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            header
            if let branch = branchText {
                BranchLine(text: branch, style: isFailed ? .secondary : .tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, MessageStyle.horizontalPadding)
        .background(alignment: .leading) {
            if isSelected {
                PanelShape.control
                    .fill(palette.textTint(0.07))
                    .padding(.leading, MessageStyle.horizontalPadding - 5)
                    .padding(.vertical, -2)
                    .accessibilityHidden(true)
            }
        }
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
            summaryText
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Mark.rowFont)
        .contentShape(.rect)

        return Group {
            if let inspector {
                Button { inspector.open(callID) } label: { line }
                    .buttonStyle(.plain)
                    .help("Show this call in the inspector")
                    .accessibilityHint("Shows the call in the inspector")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .onKeyPress(.return) {
                        inspector.open(callID)
                        return .handled
                    }
            } else {
                line
            }
        }
        .contextMenu {
            if !summary.isEmpty {
                Button("Copy Command") { MessageActions.copy(copiedCommand) }
            }
            if let output {
                Button("Copy Output") { MessageActions.copy(output) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summary.isEmpty ? "Preparing a command" : ToolSignal.cleanSummary(summary))
        .accessibilityValue(state.accessibilityText(pendingGoAhead: pendingGoAhead, callID: callID))
        .accessibilityAction(named: "Copy command") { MessageActions.copy(copiedCommand) }
    }

    /// A shell call's command line as it ran, without the `Bash` its row starts with. Any
    /// other call copies its summary.
    private var copiedCommand: String {
        commandOfCall(callID) ?? summary
    }

    @ViewBuilder private var summaryText: some View {
        if summary.isEmpty {
            Text("Preparing a command…").foregroundStyle(.tertiary)
        } else if state == .declined || state == .stopped {
            // It never ran, so it reads as struck out.
            Text(verbatim: ToolSignal.cleanSummary(summary)).strikethrough().foregroundStyle(.tertiary)
        } else {
            ToolSignal.text(for: summary, lead: lead)
        }
    }
}

/// Something the owner did without a message, with the panel with bars experiment on: "Ran",
/// a quick action's icon, and its name; "Opened", an app's own icon, and its name; or a quick
/// action's icon, its name, and why it failed, in red. Centered and faint, like a time stamp,
/// with the icon at 10 points, or at the left with the full width layout. It is not a message,
/// so it has no box, and it opens nothing.
struct ConversationLine: View {
    let line: TranscriptLine
    @Environment(\.messageLayout) private var layout

    static let iconSize: CGFloat = 10
    static let fontSize: CGFloat = 11

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            if let leading = line.leadingText {
                Text(verbatim: leading)
            }
            icon
            Text(verbatim: line.trailingText)
                .lineLimit(2)
                .multilineTextAlignment(layout.conversationLineAlignment.textAlignment)
        }
        .font(.system(size: Self.fontSize))
        .foregroundStyle(line.isFailure ? AnyShapeStyle(Color.red) : AnyShapeStyle(.tertiary))
        .padding(.leading, layout.conversationLineAlignment.leadingInset)
        .frame(maxWidth: .infinity, alignment: layout.conversationLineAlignment.frameAlignment)
        .help(TranscriptTimeLabel.fullText(for: line.date))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.spokenText)
    }

    @ViewBuilder private var icon: some View {
        switch line.icon {
        case .quickAction:
            Image(systemName: "bolt.fill")
                .font(.system(size: Self.iconSize - 1))
                .frame(width: Self.iconSize, height: Self.iconSize)
        case .application(let path):
            Image(nsImage: SuggestionIcon.icon(for: URL(filePath: path)))
                .resizable()
                .interpolation(.high)
                .frame(width: Self.iconSize, height: Self.iconSize)
        }
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

extension EnvironmentValues {
    /// The go-ahead the task is waiting on, so its tool row can say what it waits for.
    @Entry var pendingGoAhead: ConfirmationRequest? = nil
}
