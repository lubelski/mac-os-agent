import MacOSAgentCore
import SwiftUI

/// What the inspector shows for the selected call: a bar with the tool's name and the controls
/// to move between calls and close, the call's facts, its input laid out for reading, and its
/// output in the shape it was detected to have. Everything draws in the text levels the
/// conversation rows use, on the same glass as the panel.
struct ToolInspectorView: View {
    let session: AgentSession
    @Environment(ToolInspector.self) private var inspector

    var body: some View {
        VStack(spacing: 0) {
            if let id = inspector.selectedCallID, let call = session.transcript.toolCall(id) {
                // The bar reads as the call's row does, and the facts below name the tool.
                InspectorBar(title: call.summary.isEmpty ? (call.name ?? "Tool call") : ToolSignal.cleanSummary(call.summary), callID: id)
                GeometryReader { geometry in
                    VStack(alignment: .leading, spacing: 0) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                InspectorMetadata(call: call, sourceLookup: { session.toolSources[$0] })
                                InspectorInput(call: call)
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(maxHeight: geometry.size.height * 0.45)
                        .fixedSize(horizontal: false, vertical: true)
                        PanelDivider()
                        InspectorOutput(call: call)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                // A new call starts at the top with its own state.
                .id(id)
            } else {
                InspectorBar(title: "Tool call", callID: nil)
                Text("This call is not in the conversation that is showing.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themedPanel()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tool call inspector")
    }
}

/// The bar across the top: the tool's name on the left, and previous, next, and close on the
/// right, in the scheme of the panel's top bar.
private struct InspectorBar: View {
    let title: String
    let callID: String?
    @Environment(ToolInspector.self) private var inspector

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: title)
                .font(Mark.rowFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                TopBarButton(symbol: "chevron.up", label: "Previous Tool Call", help: "Show the previous tool call (Up Arrow)") {
                    inspector.move(by: -1)
                }
                TopBarButton(symbol: "chevron.down", label: "Next Tool Call", help: "Show the next tool call (Down Arrow)") {
                    inspector.move(by: 1)
                }
                TopBarButton(symbol: "xmark", label: "Close Inspector", help: "Close the inspector (Escape)") {
                    inspector.close()
                }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(height: PanelTopBar.height)
    }
}

// MARK: - Metadata

private struct InspectorMetadata: View {
    let call: InspectedToolCall
    let sourceLookup: (String) -> String?

    var body: some View {
        // A running call counts its time each second. A finished one never redraws for it.
        TimelineView(.periodic(from: .now, by: call.status.isFinished ? 3600 : 1)) { context in
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 3) {
                ForEach(call.metadata(now: context.date, sourceLookup: sourceLookup, timeText: Self.time)) { item in
                    GridRow {
                        Text(verbatim: item.label)
                            .foregroundStyle(.tertiary)
                            .gridColumnAlignment(.trailing)
                        Text(verbatim: item.value)
                            .foregroundStyle(item.label == "Status" ? HierarchicalShapeStyle.primary : .secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.system(size: 11))
        }
        .padding(.top, 2)
    }

    static func time(_ date: Date) -> String {
        // To the second, with the day when it was not today: "10:24:34 PM", "Nov 3, 10:24:34 PM".
        let time = date.formatted(.dateTime.hour().minute().second())
        if Calendar.current.isDateInToday(date) { return time }
        return "\(date.formatted(.dateTime.month(.abbreviated).day().year())), \(time)"
    }
}

// MARK: - Input

private struct InspectorInput: View {
    let call: InspectedToolCall
    @State private var raw = false

    var body: some View {
        CodeBracket(label: "input") {
            Group {
                if raw {
                    selectable(call.arguments ?? "")
                } else if let command = call.command {
                    selectable((ToolCallInput.commandLines(command) ?? [command]).joined(separator: "\n"))
                } else if let arguments = call.arguments, let fields = ToolCallInput.fields(arguments) {
                    if fields.isEmpty {
                        Text("No arguments").foregroundStyle(.tertiary)
                    } else {
                        ArgumentFields(fields: fields)
                    }
                } else if let arguments = call.arguments {
                    selectable(arguments)
                } else {
                    Text(verbatim: call.summary.isEmpty ? "The model is still writing the call." : call.summary)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 2)
        } accessory: {
            HStack(spacing: 10) {
                TextToggle(label: "raw", isOn: $raw, help: "Show the arguments exactly as the model wrote them")
                CopyControl(help: "Copy the input") { call.command ?? call.arguments ?? call.summary }
            }
        }
    }

    private func selectable(_ text: String) -> some View {
        Text(verbatim: text)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Each argument as its name above its value. Strings read as text, and objects and arrays
/// as indented JSON.
private struct ArgumentFields: View {
    let fields: [ToolCallInput.Field]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(fields) { field in
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: field.name).foregroundStyle(.tertiary)
                    if case .records(let records) = field.value {
                        RecordList(records: records)
                    } else {
                        value(field.value)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func value(_ value: ToolCallInput.Field.Value) -> Text {
        switch value {
        case .text(let text): Text(verbatim: text.isEmpty ? "(empty)" : text)
        case .literal(let text): Text(verbatim: text)
        case .structured(let node): Text(verbatim: node.prettyText())
        case .records: Text(verbatim: "")
        }
    }
}

/// An array of flat objects, such as a change tool's changes: each one numbered, with its
/// fields that are set. Fields left null are left out here, and the raw view has them.
private struct RecordList: View {
    let records: [[ToolCallInput.Pair]]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(records.enumerated()), id: \.offset) { index, record in
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(verbatim: "\(index + 1)")
                        .foregroundStyle(.tertiary)
                        .frame(width: 22, alignment: .leading)
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 1) {
                        ForEach(Array(record.enumerated()), id: \.offset) { _, pair in
                            GridRow {
                                Text(verbatim: pair.key).foregroundStyle(.tertiary)
                                Text(verbatim: pair.value)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Output

private struct InspectorOutput: View {
    let call: InspectedToolCall
    @State private var raw = false
    @State private var wraps = true
    @State private var lineNumbers = true
    @State private var formatted: ToolOutputFormat.Formatted?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            controls
                .padding(.horizontal, 16)
                .padding(.top, 10)
            if let note = !raw ? formatted?.note : nil {
                Text(verbatim: note)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
            }
            content
        }
        .task(id: FormatKey(callID: call.callID, output: call.output)) {
            formatted = nil
            guard let output = call.output else { return }
            // Detection reads a bounded prefix, and the layout runs off the main thread, so a
            // large output never holds up the conversation.
            let result = await Task.detached(priority: .userInitiated) {
                ToolOutputFormat.format(ToolOutputTrailer(output).body)
            }.value
            if !Task.isCancelled { formatted = result }
        }
    }

    /// Changes when the call or its output does. Counting the output's bytes is enough to tell
    /// a result from none, and a result never changes once it is in.
    private struct FormatKey: Hashable {
        var callID: String
        var length: Int?
        init(callID: String, output: String?) {
            self.callID = callID
            length = output?.utf8.count
        }
    }

    private var showsText: Bool {
        raw || formatted.map { $0.blocks.count == 1 && Self.isText($0.blocks[0]) } ?? false
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Text(verbatim: call.output == nil ? "output" : "output · \(raw ? "raw" : formatted?.shape.rawValue.lowercased() ?? "reading")")
                .foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            if call.output != nil {
                TextToggle(label: "raw", isOn: $raw, help: "Show the output exactly as it was stored")
                if showsText {
                    TextToggle(label: "wrap", isOn: $wraps, help: "Wrap long lines")
                    TextToggle(label: "numbers", isOn: $lineNumbers, help: "Show line numbers")
                }
                CopyControl(help: "Copy the output exactly as it was stored") { call.output ?? "" }
                CopyControl(label: "copy all", help: "Copy the whole call: its tool, input, and output") { Self.wholeCall(call) }
            }
        }
        .font(Mark.rowFont)
    }

    @ViewBuilder private var content: some View {
        if let output = call.output {
            if raw {
                OutputTextView(text: output, wraps: wraps, showsLineNumbers: lineNumbers)
            } else if let formatted {
                FormattedOutputView(formatted: formatted, wraps: wraps, lineNumbers: lineNumbers)
            } else {
                Text("Reading the output…")
                    .font(Mark.rowFont)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                Spacer()
            }
        } else {
            BranchLine(text: Self.waitingText(call.status))
                .padding(.horizontal, 16)
                .padding(.leading, -Mark.rowColumn)
            Spacer()
        }
    }

    static func isText(_ block: ToolOutputFormat.Block) -> Bool {
        if case .text = block { true } else { false }
    }

    static func waitingText(_ status: InspectedToolCall.Status) -> String {
        switch status {
        case .preparing: "the model is still writing the call"
        case .running: "running, the output shows here when it finishes"
        case .waitingForGoAhead: "waiting for your go-ahead"
        default: "no output was kept"
        }
    }

    static func wholeCall(_ call: InspectedToolCall) -> String {
        var parts = ["Tool: \(call.name ?? call.summary)", "Call ID: \(call.callID)"]
        if let command = call.command {
            parts.append("Command:\n\(command)")
        } else if let arguments = call.arguments {
            parts.append("Arguments:\n\(arguments)")
        }
        if let output = call.output { parts.append("Output:\n\(output)") }
        return parts.joined(separator: "\n\n")
    }
}

/// A quiet word that turns something on and off, in the scheme of `CopyControl`: tertiary
/// when off, secondary when on or under the pointer, never a change of weight.
struct TextToggle: View {
    let label: String
    @Binding var isOn: Bool
    let help: String
    @State private var hovering = false

    var body: some View {
        Button { isOn.toggle() } label: {
            Text(verbatim: label)
                .font(Mark.rowFont)
                .underline(isOn, color: .secondary)
                .foregroundStyle(isOn || hovering ? HierarchicalShapeStyle.secondary : .tertiary)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
