import MacOSAgentCore
import SwiftUI

/// The quiet line above the text field that says what Return will do without the model, such
/// as "Safari  ↵ opens". It sits where the command hint does, and in its style. With several
/// close matches it lists the few best on the same line, the chosen one set on a faint
/// capsule, and the arrow keys or Tab choose. A saved action also says what it will do, in its
/// steps' own words, such as "Start Screensaver  Open ScreenSaverEngine  ↵ runs", since Return
/// runs it with no go-ahead. It shows nothing when the draft goes to the agent.
struct InstantActionRow: View {
    let actions: InstantActions
    @Environment(\.panelPalette) private var palette

    var body: some View {
        if let suggestion = actions.suggestion {
            let several = suggestion.choices.count > 1
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    ForEach(Array(suggestion.choices.enumerated()), id: \.element.id) { index, choice in
                        let chosen = index == actions.selection
                        Text(verbatim: choice.title)
                            .font(.system(size: 12))
                            // The weight stays the same whether chosen or not. Only the level and
                            // the capsule change.
                            .foregroundStyle(chosen ? .primary : .tertiary)
                            .lineLimit(1)
                            .padding(.horizontal, several ? 7 : 0)
                            .padding(.vertical, 2)
                            .background {
                                if several, chosen { Capsule().fill(palette.textTint(0.08)) }
                            }
                            .onTapGesture { actions.choose(index) }
                    }
                }
                .layoutPriority(2)
                let chosen = suggestion.choices[min(actions.selection, suggestion.choices.count - 1)]
                if let detail = chosen.detail {
                    Text(verbatim: detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                // The keys keep their room. The reading of the steps gives way first.
                Text(verbatim: hint(several: several, label: chosen.target.actionLabel))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, several ? 37 : 44)
            .padding(.trailing, 16)
            .padding(.vertical, 8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText(suggestion))
        }
    }

    private func hint(several: Bool, label: String) -> String {
        let keys = "\(Mark.returnKey) \(label)   \(Mark.commandReturn) sends to the agent   esc dismisses"
        return several ? "\(Mark.up)\(Mark.down) or tab chooses   " + keys : keys
    }

    private func accessibilityText(_ suggestion: InstantActionSuggestion) -> String {
        let chosen = suggestion.choices[min(actions.selection, suggestion.choices.count - 1)]
        var text = "Return \(chosen.target.actionLabel) \(chosen.title)."
        if let detail = chosen.detail { text += " It will \(detail.prefix(1).lowercased() + detail.dropFirst())." }
        if suggestion.choices.count > 1 {
            text += " Also matches \(suggestion.choices.filter { $0.id != chosen.id }.map(\.title).joined(separator: " and ")). Up and Down choose."
        }
        return text + " Command-Return sends the text to the agent instead. Escape dismisses."
    }
}
