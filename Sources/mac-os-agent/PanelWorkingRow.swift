import MacOSAgentCore
import SwiftUI

// The panel with bars and an input pill (`Experiment.panelWithBarsAndInputPill`), the working
// row slice. See "While a task runs" in `planning/panel-with-input-pill.md`.
//
// - While a task runs, the conversation's last row is `PanelWorkingRow`: three small copies of
//   the logo, the bright one stepping left to right, then "Working…". Stop is a link that shows
//   while the pointer is over the row.
// - With the queue experiment on too, queued messages are drawn at the end of the conversation
//   as pending messages on the owner's side, `QueuedMessagesInConversation`, not as rows above
//   the field.
//
// With the switch off, the history draws `WorkingRow` and the queue's rows above the field, as
// before.

/// The three marks of the working row, and which one is bright.
enum WorkingMarks {
    static let count = 3
    /// Steps a second. The bright mark moves one place per step and wraps around.
    static let stepsPerSecond: Double = 3
    /// The strength of a mark that is not the bright one.
    static let dimStrength: Double = 0.3
    /// Each mark's side.
    static let size: CGFloat = 7
    static let spacing: CGFloat = 2

    /// The step at a moment, counted from the reference date, so every redraw agrees.
    static func step(at date: Date) -> Int {
        Int((date.timeIntervalSinceReferenceDate * stepsPerSecond).rounded(.down))
    }

    /// Which mark is bright at a step: the first, then the second, then the third, then the
    /// first again.
    static func brightIndex(step: Int) -> Int {
        ((step % count) + count) % count
    }

    /// Each mark's strength at a step, left to right. With Reduce Motion on nothing steps: the
    /// three are still, all at full strength.
    static func strengths(step: Int, reduceMotion: Bool) -> [Double] {
        if reduceMotion { return Array(repeating: 1, count: count) }
        let bright = brightIndex(step: step)
        return (0..<count).map { $0 == bright ? 1 : dimStrength }
    }
}

/// The three marks, drawn in the accent. They step about three times a second, or stand still
/// with Reduce Motion on.
struct WorkingMarksView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.panelPalette) private var palette

    var body: some View {
        if reduceMotion {
            marks(step: 0)
        } else {
            TimelineView(.periodic(from: .now, by: 1 / WorkingMarks.stepsPerSecond)) { context in
                marks(step: WorkingMarks.step(at: context.date))
            }
        }
    }

    private func marks(step: Int) -> some View {
        HStack(spacing: WorkingMarks.spacing) {
            ForEach(Array(WorkingMarks.strengths(step: step, reduceMotion: reduceMotion).enumerated()), id: \.offset) { _, strength in
                LogoTriangle()
                    .fill(palette.color(palette.appearance.accent))
                    .opacity(strength)
                    .frame(width: WorkingMarks.size, height: WorkingMarks.size)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A link in the conversation: plain text in the accent, at one weight whatever the pointer or
/// a press does. A disabled link is in the tertiary level.
struct PanelLinkStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.panelPalette) private var palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? AnyShapeStyle(palette.color(palette.appearance.accent)) : AnyShapeStyle(.tertiary))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(.rect)
    }
}

/// The last row of the conversation while a task runs, with the panel with bars on: the three
/// marks, "Working…", and the row's links, which show while the pointer is over the row or one
/// of them has keyboard focus. Stop is the only link for now. The others the spec leaves room for
/// go in `links`, beside it. It is the conversation's only working indicator.
struct PanelWorkingRow: View {
    let stop: () -> Void
    /// For a preview: draws the row as if the pointer were over it.
    var forcesHover = false
    @State private var hovering = false

    static let title = "Working…"
    static let spokenTitle = "Working"
    static let stopTitle = "Stop"
    static let font = Font.system(size: 12)

    var body: some View {
        HStack(spacing: 8) {
            WorkingMarksView()
            Text(verbatim: Self.title)
                .foregroundStyle(.secondary)
            links
                .revealed(when: hovering || forcesHover)
        }
        .font(Self.font)
        .frame(height: WorkingRow.height)
        // The marks start at the left edge of the agent's message boxes, as in the mockup.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenTitle)
        .accessibilityAction(named: Self.stopTitle, stop)
    }

    /// The row's links, in a row of their own so more can join Stop later.
    private var links: some View {
        HStack(spacing: 10) {
            Button(Self.stopTitle, action: stop)
                .buttonStyle(PanelLinkStyle())
                .help(WorkingRow.help)
        }
    }
}

/// Where the queued messages are drawn.
enum QueuedMessagePlacement: Equatable {
    /// Nothing is queued, so nothing is drawn.
    case none
    /// As rows above the field, as before the panel with bars.
    case aboveField
    /// At the end of the conversation, as pending messages on the owner's side.
    case inConversation

    /// With the panel with bars on, queued messages are in the conversation. With it off they
    /// are rows above the field, as before. Only the queue experiment queues messages, so with
    /// it off the queue is empty and nothing is drawn either way.
    static func of(panelWithBars: Bool, queueIsEmpty: Bool) -> QueuedMessagePlacement {
        if queueIsEmpty { return .none }
        return panelWithBars ? .inConversation : .aboveField
    }
}

extension AgentSession {
    var queuedMessagePlacement: QueuedMessagePlacement {
        .of(panelWithBars: panelWithBars, queueIsEmpty: queue.isEmpty)
    }
}

/// The queued messages at the end of the conversation, with the panel with bars on: each one a
/// message box on the owner's side at reduced strength, so it reads as not sent yet, with
/// "queued" under it and the links Edit and Remove under the pointer. A paused queue has a line
/// above them that says why, with Send Next and Clear.
struct QueuedMessagesInConversation: View {
    let session: AgentSession

    /// The strength of a message that has not been sent.
    static let pendingStrength: Double = 0.5

    var body: some View {
        let queue = session.queue
        VStack(alignment: .trailing, spacing: HistoryView.spacing(.regular)) {
            if let reason = queue.pauseReason {
                HStack(spacing: 10) {
                    Text(verbatim: reason == .stopped
                         ? "Queue paused because the task was stopped."
                         : "Queue paused because the task ended with an error.")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button("Send Next", action: session.resumeQueue)
                        .disabled(session.isRunning)
                    Button("Clear", action: session.clearQueue)
                }
                .font(.system(size: 12))
                .buttonStyle(PanelLinkStyle())
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            ForEach(Array(queue.items.enumerated()), id: \.element.id) { index, item in
                QueuedMessage(
                    text: item.shownText, position: index + 1, canEdit: session.draft.isEmpty && session.attachments.isEmpty,
                    forcesHover: session.previewHoversQueuedMessage,
                    edit: { session.editQueued(item.id) }, remove: { session.removeQueued(item.id) })
            }
        }
    }
}

/// One queued message: the owner's message box at reduced strength, then "queued" and its links.
private struct QueuedMessage: View {
    let text: String
    let position: Int
    let canEdit: Bool
    var forcesHover = false
    let edit: () -> Void
    let remove: () -> Void
    @Environment(\.panelPalette) private var palette
    @Environment(\.messageLayout) private var layout
    @State private var hovering = false

    var body: some View {
        // On the owner's side, or across the full width with the full width layout.
        VStack(alignment: layout.boxesFillWidth ? .leading : .trailing, spacing: 4) {
            HStack(spacing: 0) {
                if !layout.boxesFillWidth { Spacer(minLength: MessageStyle.farSideInset) }
                Text(verbatim: text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: layout.boxesFillWidth ? .infinity : nil, alignment: .leading)
                    .padding(.horizontal, MessageStyle.horizontalPadding)
                    .padding(.vertical, MessageStyle.verticalPadding)
                    .background(palette.ownerFill, in: PanelShape.message)
                    .overlay { PanelShape.message.strokeBorder(palette.ownerEdge(layout), lineWidth: 1) }
                    .opacity(QueuedMessagesInConversation.pendingStrength)
            }
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Button("Edit", action: edit)
                        .disabled(!canEdit)
                        .help(canEdit
                              ? "Take this message back into the field to edit it"
                              : "Empty the field first to edit this message")
                    Button("Remove", action: remove)
                }
                .buttonStyle(PanelLinkStyle())
                .revealed(when: hovering || forcesHover)
                Text(verbatim: "queued")
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 11))
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Queued message \(position), not sent yet: \(text)")
        .accessibilityAction(named: "Edit") { if canEdit { edit() } }
        .accessibilityAction(named: "Remove", remove)
    }
}
