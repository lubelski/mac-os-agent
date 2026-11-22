import AppKit
import MacOSAgentCore
import SwiftUI

/// The panel's content on Liquid Glass: a strip to move it by, the thread's history, the
/// go-ahead card when one is pending, and the text field at the bottom.
struct SummonView: View {
    @Bindable var session: AgentSession
    var onDismiss: () -> Void = {}
    @FocusState private var fieldFocused: Bool
    /// The reference time for the history's time labels, refreshed on every summon.
    @State private var now = Date()

    var body: some View {
        VStack(spacing: 0) {
            DragHandle()
                .frame(height: 14)
                .frame(maxWidth: .infinity)
            HistoryView(session: session, now: now)
            if let request = session.pendingConfirmation {
                ConfirmationCard(request: request, session: session)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
            Divider().opacity(0.5)
            inputRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: SummonPanel.cornerRadius))
        .onChange(of: session.focusRequest, initial: true) {
            now = Date()
            fieldFocused = true
        }
        .onChange(of: session.isRunning) { _, running in
            if !running { fieldFocused = true }
        }
        .onExitCommand(perform: onDismiss)
    }

    private var inputRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            TextField("Tell your Mac what to do", text: $session.draft)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($fieldFocused)
                .onSubmit { session.submit() }
                .disabled(session.isRunning)
            if session.isRunning {
                ProgressView().controlSize(.small)
                Button("Stop", action: session.stop)
                    .buttonStyle(.glass)
                    .keyboardShortcut(".", modifiers: .command)
            }
        }
        .frame(minHeight: 28)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - History

/// The whole thread, oldest at the top. It opens at the latest row and follows new rows while
/// the owner is at the bottom. Once they scroll up it stays where they put it, and a button
/// takes them back down.
private struct HistoryView: View {
    let session: AgentSession
    let now: Date
    @State private var position = ScrollPosition(edge: .bottom)
    /// Whether new content keeps the view at the bottom.
    @State private var followsLatest = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Within this distance of the end counts as at the bottom.
    private static let bottomTolerance: CGFloat = 24

    private struct Metrics: Equatable {
        var visibleBottom: CGFloat
        var contentHeight: CGFloat
        var containerHeight: CGFloat
    }

    var body: some View {
        let rows = session.transcript.rows
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows.indices, id: \.self) { index in
                    let row = rows[index]
                    RowView(row: row, now: now)
                        .padding(.top, Self.spacing(TranscriptRow.gap(after: index > 0 ? rows[index - 1] : nil, before: row)))
                }
                StreamingReply(session: session, after: rows.last)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 14)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .onScrollGeometryChange(for: Metrics.self) { geometry in
            Metrics(
                visibleBottom: geometry.visibleRect.maxY,
                contentHeight: geometry.contentSize.height,
                containerHeight: geometry.containerSize.height)
        } action: { old, new in
            if old.contentHeight != new.contentHeight || old.containerHeight != new.containerHeight {
                // The content grew, a row opened, or the panel was resized.
                if followsLatest { position.scrollTo(edge: .bottom) }
            } else if old.visibleBottom != new.visibleBottom {
                // Only the owner moves the view without the content changing size.
                followsLatest = new.contentHeight - new.visibleBottom <= Self.bottomTolerance
            }
        }
        .onChange(of: session.focusRequest) { jumpToLatest(animated: false) }
        .onChange(of: rows.count) {
            if rows.last?.isUser == true { jumpToLatest(animated: false) }
        }
        .overlay(alignment: .bottomTrailing) {
            if !followsLatest {
                Button {
                    jumpToLatest(animated: true)
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("Jump to the latest")
                .padding(12)
            }
        }
        .overlay {
            if rows.isEmpty {
                Text("Everything you ask stays in this one thread.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func jumpToLatest(animated: Bool) {
        followsLatest = true
        if animated && !reduceMotion {
            withAnimation(.smooth(duration: 0.3)) { position.scrollTo(edge: .bottom) }
        } else {
            position.scrollTo(edge: .bottom)
        }
    }

    static func spacing(_ gap: TranscriptRow.Gap) -> CGFloat {
        switch gap {
        case .none: 0
        case .tight: 2
        case .regular: 10
        case .exchange: 22
        }
    }
}

/// The reply as it streams in. It is its own view so each new piece of text redraws only it,
/// not the whole history. It looks exactly like the finished reply that replaces it.
private struct StreamingReply: View {
    let session: AgentSession
    let after: TranscriptRow?

    var body: some View {
        if !session.streamingText.isEmpty {
            AgentMessage(text: session.streamingText)
                .padding(.top, HistoryView.spacing(TranscriptRow.gap(after: after, before: TranscriptRow(id: "streaming", kind: .assistant("")))))
        }
    }
}

private struct RowView: View {
    let row: TranscriptRow
    let now: Date

    var body: some View {
        switch row.kind {
        case .user(let text, let date, let showsTime):
            OwnerMessage(text: text, date: date, showsTime: showsTime, now: now)
        case .assistant(let text):
            AgentMessage(text: text)
        case .tool(let command, let status, let output):
            ToolLine(command: command, status: status, output: output)
        case .notice(let text):
            StatusLine(text: text, systemImage: "stop.circle", style: .secondary)
        case .error(let text):
            StatusLine(text: text, systemImage: "exclamationmark.triangle", style: .red)
        }
    }
}

/// Shared look of the two kinds of message box.
private enum MessageStyle {
    static let cornerRadius: CGFloat = 14
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 8
    /// The room a box leaves on its far side, so the two kinds sit on opposite sides.
    static let farSideInset: CGFloat = 56
}

/// What the owner typed: a box on the right with a faint accent tint. A time label sits above
/// the first message of each stretch, and every message shows its full time on hover.
private struct OwnerMessage: View {
    let text: String
    let date: Date
    let showsTime: Bool
    let now: Date

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
                Text(text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, MessageStyle.horizontalPadding)
                    .padding(.vertical, MessageStyle.verticalPadding)
                    // The system accent, which stays in color while the app is inactive. The
                    // panel never activates the app, so `Color.accentColor` would turn gray.
                    .background(Color(nsColor: .controlAccentColor).opacity(0.3), in: .rect(cornerRadius: MessageStyle.cornerRadius))
                    .help(TranscriptTimeLabel.fullText(for: date))
            }
        }
    }
}

/// What the agent said to the owner: a neutral box on the left.
private struct AgentMessage: View {
    let text: String

    var body: some View {
        HStack(spacing: 0) {
            Text(Self.rendered(text))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, MessageStyle.horizontalPadding)
                .padding(.vertical, MessageStyle.verticalPadding)
                .background(.primary.opacity(0.09), in: .rect(cornerRadius: MessageStyle.cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: MessageStyle.cornerRadius).strokeBorder(.primary.opacity(0.08), lineWidth: 1))
            Spacer(minLength: MessageStyle.farSideInset)
        }
    }

    /// Inline Markdown such as `code` and **bold**, keeping the model's line breaks. The same
    /// rendering is used while streaming, so the finished reply does not change shape.
    static func rendered(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// A command the agent ran: one small secondary line with a status mark, aligned with the text
/// inside the agent's boxes. The full command and its output open below it.
private struct ToolLine: View {
    let command: String
    let status: TranscriptRow.ToolStatus
    let output: String?
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let font = Font.system(size: 11, design: .monospaced)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                StatusMark(status: status, output: output)
                Text(command.isEmpty ? "Preparing a command…" : command)
                    .font(Self.font)
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: expanded)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if output != nil {
                    Button {
                        if reduceMotion { expanded.toggle() } else { withAnimation(.snappy(duration: 0.18)) { expanded.toggle() } }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 16, height: 14)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help(expanded ? "Hide output" : "Show output")
                    .accessibilityLabel(expanded ? "Hide output" : "Show output")
                }
            }
            if expanded, let output {
                Text(output)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.primary.opacity(0.04), in: .rect(cornerRadius: 8))
                    .padding(.leading, StatusMark.width + 6)
            }
        }
        .padding(.leading, MessageStyle.horizontalPadding)
    }
}

private struct StatusMark: View {
    let status: TranscriptRow.ToolStatus
    let output: String?
    static let width: CGFloat = 12

    var body: some View {
        Group {
            switch status {
            case .preparing, .running:
                ProgressView().controlSize(.mini).scaleEffect(0.7)
            case .waitingForConfirmation:
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            case .finished:
                switch TranscriptRow.outcome(ofOutput: output) {
                case .succeeded: Image(systemName: "checkmark").foregroundStyle(.green)
                case .failed: Image(systemName: "xmark").foregroundStyle(.red)
                case .unknown: Image(systemName: "minus").foregroundStyle(.tertiary)
                }
            }
        }
        .font(.system(size: 9, weight: .bold))
        .frame(width: Self.width, height: 12)
    }
}

/// A line the app adds itself, such as "Stopped." or an error.
private struct StatusLine: View {
    let text: String
    let systemImage: String
    let style: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(style)
            .textSelection(.enabled)
            .padding(.leading, MessageStyle.horizontalPadding)
    }
}

private struct ConfirmationCard: View {
    let request: ConfirmationRequest
    let session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Run this command? It \(request.reason).", systemImage: "hand.raised")
                .foregroundStyle(.orange)
            ScrollView {
                Text(request.command)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 120)
            .fixedSize(horizontal: false, vertical: true)
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
        .background(.orange.opacity(0.10), in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.orange.opacity(0.35), lineWidth: 1))
    }
}

/// The strip along the top edge that moves the panel. AppKit's own window drag, so it works
/// in a panel that never activates the app.
private struct DragHandle: NSViewRepresentable {
    final class HandleView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }
    }

    func makeNSView(context: Context) -> HandleView { HandleView() }
    func updateNSView(_ nsView: HandleView, context: Context) {}
}
