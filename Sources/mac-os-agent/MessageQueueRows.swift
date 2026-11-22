import MacOSAgentCore
import SwiftUI

/// The messages queued while a task runs, above the text field, oldest first, the order they
/// will be sent in. Each row has Edit, which takes it back into an empty field, and Remove.
/// When a stopped task or an error paused the queue, a line says so, with Send to send the
/// next one and resume, and Clear to drop them all. An experiment: see `MessageQueue`.
struct MessageQueueRows: View {
    let session: AgentSession

    var body: some View {
        let queue = session.queue
        if !queue.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                if let reason = queue.pauseReason {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(verbatim: reason == .stopped
                             ? "Queue paused because the task was stopped."
                             : "Queue paused because the task ended with an error.")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button("Send Next", action: session.resumeQueue)
                            .disabled(session.isRunning)
                        Button("Clear", action: session.clearQueue)
                    }
                    .font(.system(size: 12))
                    .buttonStyle(QueueControlStyle())
                }
                ForEach(Array(queue.items.enumerated()), id: \.element.id) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(verbatim: "queued \(index + 1)")
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                        Text(verbatim: item.text.replacingOccurrences(of: "\n", with: " "))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Edit") { session.editQueued(item.id) }
                            .disabled(!session.draft.isEmpty)
                            .help(session.draft.isEmpty
                                  ? "Take this message back into the field to edit it"
                                  : "Empty the field first to edit this message")
                        Button("Remove") { session.removeQueued(item.id) }
                    }
                    .font(.system(size: 12))
                    .buttonStyle(QueueControlStyle())
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.leading, 37)
            .padding(.trailing, 16)
            .padding(.vertical, 8)
        }
    }
}

/// A quiet text control in the text color, in the scheme of the history's `copy` control: no
/// icon, no accent, and the same weight when pressed or disabled.
private struct QueueControlStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? (configuration.isPressed ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)) : AnyShapeStyle(.quaternary))
            .contentShape(.rect)
    }
}
