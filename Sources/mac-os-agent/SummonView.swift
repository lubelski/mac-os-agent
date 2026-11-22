import MacOSAgentCore
import SwiftUI

/// The panel's content: the current exchange above a text field, on Liquid Glass.
struct SummonView: View {
    @Bindable var session: AgentSession
    var onDismiss: () -> Void = {}
    @FocusState private var fieldFocused: Bool

    static let width: CGFloat = 640

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !session.rows.isEmpty || !session.streamingText.isEmpty {
                transcript
                Divider().opacity(0.5)
            }
            if let request = session.pendingConfirmation {
                ConfirmationCard(request: request, session: session)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }
            inputRow
        }
        .frame(width: Self.width)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .onChange(of: session.focusRequest, initial: true) { fieldFocused = true }
        .onExitCommand(perform: onDismiss)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(session.rows) { row in
                        RowView(row: row).id(row.id)
                    }
                    if !session.streamingText.isEmpty {
                        Text(session.streamingText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("streaming")
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .textSelection(.enabled)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: session.rows) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: session.streamingText) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    private var inputRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkle")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
            TextField("Tell your Mac what to do", text: $session.draft)
                .textFieldStyle(.plain)
                .font(.system(size: 20))
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
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }
}

private struct RowView: View {
    let row: ExchangeRow

    var body: some View {
        switch row.kind {
        case .user(let text):
            Text(text)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .assistant(let text):
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool(let command, let status, let output):
            ToolRow(command: command, status: status, output: output)
        case .notice(let text):
            Label(text, systemImage: "stop.circle")
                .foregroundStyle(.secondary)
        case .error(let text):
            Label(text, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }
}

private struct ToolRow: View {
    let command: String
    let status: ExchangeRow.ToolStatus
    let output: String?
    @State private var showsOutput = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                statusIcon.frame(width: 16)
                Text(command.isEmpty ? "Preparing a command…" : command)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(showsOutput ? nil : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if output != nil {
                    Button(showsOutput ? "Hide output" : "Output") { showsOutput.toggle() }
                        .buttonStyle(.borderless)
                        .font(.callout)
                }
            }
            if showsOutput, let output {
                Text(output)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
    }

    @ViewBuilder private var statusIcon: some View {
        switch status {
        case .preparing, .running:
            ProgressView().controlSize(.mini)
        case .waitingForConfirmation:
            Image(systemName: "hand.raised").foregroundStyle(.orange)
        case .finished:
            if output?.hasSuffix("[exit status 0]") == true {
                Image(systemName: "checkmark").foregroundStyle(.green)
            } else if output?.contains("[exit status") == true {
                Image(systemName: "xmark").foregroundStyle(.red)
            } else {
                Image(systemName: "minus").foregroundStyle(.secondary)
            }
        }
    }
}

private struct ConfirmationCard: View {
    let request: ConfirmationRequest
    let session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Run this command? It \(request.reason).", systemImage: "hand.raised")
                .foregroundStyle(.orange)
            Text(request.command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
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
        .background(.orange.opacity(0.08), in: .rect(cornerRadius: 16))
    }
}
