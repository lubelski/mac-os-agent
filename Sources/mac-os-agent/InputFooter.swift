import AppKit
import MacOSAgentCore
import SwiftUI
import UniformTypeIdentifiers

// The suggestions-in-the-field experiment (`Experiment.suggestionsInFieldAndFooter`): a quiet
// footer under the text field that always says what the keys do now, a mark beside the field
// that shows what Return will act on, and a short list the footer grows into on Down Arrow.

/// One key and what it does, such as "↵ open". The keys are drawn as marks and spoken in words.
struct FooterHint: Equatable {
    var keys: String
    var words: String
    /// The keys as VoiceOver reads them, such as "Return".
    var spokenKeys: String

    var text: String { keys.isEmpty ? words : "\(keys) \(words)" }
    var spoken: String { spokenKeys.isEmpty ? words : "\(spokenKeys), \(words)" }
}

/// What the footer says, worked out from the state of the window and the settings.
struct InputFooterContent: Equatable {
    var leading: [FooterHint]
    var trailing: FooterHint?

    /// What the window is doing, from the footer's point of view.
    enum State: Equatable {
        /// An empty field and nothing running.
        case idle
        /// Text that Return sends to the agent.
        case typing
        /// A task is running.
        case running(queuedCount: Int)
        /// Return would take an app or a quick action. `others` is how many more matches the
        /// list would show.
        case suggestion(InstantActionTarget, others: Int)
        /// The instant action list is open. Nil target is the Ask row.
        case list(InstantActionTarget?)
        /// The slash command list. `completes` is true when Return completes a partly typed
        /// name rather than running the command.
        case commands(count: Int, completes: Bool)
    }

    /// - Parameter statusLine: true for the status line under the pill, with the panel with
    ///   bars experiment on. The model's name is in the title bar there, so it is left out,
    ///   and Return while typing a message reads "↵ send".
    static func make(
        _ state: State, agentName: String, modelName: String, recallsMessages: Bool, queuesWhileRunning: Bool,
        statusLine: Bool = false
    ) -> InputFooterContent {
        let model: FooterHint? = statusLine ? nil : FooterHint(keys: "", words: modelName, spokenKeys: "")
        let ask = FooterHint(keys: Mark.commandReturn, words: "ask \(agentName)", spokenKeys: "Command-Return")
        switch state {
        case .idle:
            var hints: [FooterHint] = []
            if recallsMessages { hints.append(FooterHint(keys: Mark.up, words: "earlier messages", spokenKeys: "Up Arrow")) }
            hints.append(FooterHint(keys: "/", words: "commands", spokenKeys: "Slash"))
            return InputFooterContent(leading: hints, trailing: model)
        case .typing:
            return InputFooterContent(leading: [
                FooterHint(keys: Mark.returnKey, words: statusLine ? "send" : "ask \(agentName)", spokenKeys: "Return"),
                FooterHint(keys: "⇧↵", words: "new line", spokenKeys: "Shift-Return"),
            ], trailing: model)
        case .running(let queued):
            var hints = [FooterHint(keys: "⌘.", words: "stop", spokenKeys: "Command-Period")]
            if queuesWhileRunning {
                hints.append(FooterHint(keys: Mark.returnKey, words: "queue", spokenKeys: "Return"))
                if queued > 0 { hints.append(FooterHint(keys: Mark.up, words: "edit queued", spokenKeys: "Up Arrow")) }
            }
            return InputFooterContent(leading: hints, trailing: model)
        case .suggestion(let target, let others):
            var hints = [FooterHint(keys: Mark.returnKey, words: verb(target), spokenKeys: "Return")]
            if others > 0 { hints.append(FooterHint(keys: Mark.down, words: "\(others) more", spokenKeys: "Down Arrow")) }
            return InputFooterContent(leading: hints, trailing: ask)
        case .list(let target):
            return InputFooterContent(leading: [
                FooterHint(keys: Mark.returnKey, words: target.map(verb) ?? "ask", spokenKeys: "Return"),
                FooterHint(keys: Mark.up + Mark.down, words: "choose", spokenKeys: "Up and Down Arrow"),
                FooterHint(keys: "esc", words: "close", spokenKeys: "Escape"),
            ], trailing: ask)
        case .commands(let count, let completes):
            var hints = [FooterHint(keys: Mark.returnKey, words: completes ? "complete" : "run", spokenKeys: "Return")]
            if count > 1 { hints.append(FooterHint(keys: Mark.up + Mark.down, words: "choose", spokenKeys: "Up and Down Arrow")) }
            hints.append(FooterHint(keys: "esc", words: "close", spokenKeys: "Escape"))
            return InputFooterContent(leading: hints, trailing: model)
        }
    }

    /// What Return does to a target, in the footer's words.
    static func verb(_ target: InstantActionTarget) -> String {
        switch target {
        case .application: "open"
        case .quickAction: "run"
        }
    }

    /// The model's name as the menu bar menu shows it, or its id for one the app does not list.
    static func modelName(id: String) -> String {
        OpenAIModel.all.first { $0.id == id }?.name ?? id
    }

    var spoken: String {
        (leading + [trailing].compactMap { $0 }).map(\.spoken).joined(separator: ". ")
    }
}

extension AgentSession {
    /// The footer's state for this window now.
    var footerState: InputFooterContent.State {
        let rows = suggestionRows
        if case .command = rows.first {
            let completes = slashMenu.parse(draft) == nil && !draft.contains(where: \.isWhitespace)
            return .commands(count: rows.count, completes: completes)
        }
        if isRunning { return .running(queuedCount: queue.items.count) }
        if suggestionList.isOpen, !rows.isEmpty { return .list(returnTarget?.target) }
        if let target = returnTarget {
            let matches = instantActions.suggestion?.matches.count ?? 1
            return .suggestion(target.target, others: max(0, matches - 1))
        }
        return draft.isEmpty ? .idle : .typing
    }
}

/// The one quiet line under the text field. It is always there with the experiment on, and
/// says what the keys do now: hints on the left, and the model or what Command-Return does on
/// the right. Its weight never changes.
struct InputFooter: View {
    let content: InputFooterContent
    /// False for the keys row of the match card, which is on the card's own fill.
    var drawsFill = true

    static let height: CGFloat = 26
    static let font = Font.system(size: 11)

    var body: some View {
        HStack(spacing: 14) {
            ForEach(Array(content.leading.enumerated()), id: \.offset) { _, hint in
                Text(verbatim: hint.text).lineLimit(1).fixedSize()
            }
            Spacer(minLength: 8)
            if let trailing = content.trailing {
                Text(verbatim: trailing.text).lineLimit(1).truncationMode(.tail)
            }
        }
        .font(Self.font)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 16)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background { if drawsFill { PanelBarFill() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.spoken)
    }
}

/// The one icon at the left of the text field. It is the sparkle whenever Return sends the
/// text as a message, and the icon of the app or quick action Return will act on otherwise, so
/// the owner can see at a glance whether Return runs something or sends it. Both take the same
/// square slot, centered on the first line, so the text never moves when one replaces the other.
struct InputMark: View {
    let target: InstantActionCandidate?

    static let size: CGFloat = 18

    var body: some View {
        Group {
            if let target {
                SuggestionIcon(target: target.target, size: Self.size)
                    .accessibilityLabel("Return \(target.target.actionLabel) \(target.title)")
            } else {
                PromptMark()
            }
        }
        .frame(width: Self.size, height: InputField.rowHeight)
    }
}

/// An app's own icon, or a symbol for a quick action.
struct SuggestionIcon: View {
    let target: InstantActionTarget
    let size: CGFloat

    var body: some View {
        switch target {
        case .application(let application):
            Image(nsImage: Self.icon(for: application.url))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        case .quickAction:
            Image(systemName: "bolt.fill")
                .font(.system(size: size * 0.72))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }

    /// Icons by path. Reading one asks Launch Services, which is fast but not free on every
    /// keystroke.
    @MainActor private static var icons: [String: NSImage] = [:]

    /// The app's icon, drawn once into a small sRGB bitmap: enough for the mark and the rows at
    /// any scale, and with none of the extended range some icons carry, which made an
    /// offscreen render of the panel read as dimmed.
    @MainActor static func icon(for url: URL) -> NSImage {
        let path = url.path(percentEncoded: false)
        if let icon = icons[path] { return icon }
        // An app that is gone since the list was read gets the generic app icon, not a
        // document's.
        let source = FileManager.default.fileExists(atPath: path)
            ? NSWorkspace.shared.icon(forFile: path) : NSWorkspace.shared.icon(for: .applicationBundle)
        let pixels = 64
        var icon = source
        if let space = CGColorSpace(name: CGColorSpace.sRGB),
           let context = CGContext(
               data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            source.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
            NSGraphicsContext.restoreGraphicsState()
            if let image = context.makeImage() { icon = NSImage(cgImage: image, size: NSSize(width: 32, height: 32)) }
        }
        if icons.count > 200 { icons.removeAll() }
        icons[path] = icon
        return icon
    }
}

/// The list the footer grows into: one line per row, the highlighted one on a faint fill. For
/// instant actions, the matches best first, then a row that sends the text to the agent. For
/// slash commands, each command and its description. At most `visibleLimit` rows show, moved
/// along so the highlighted one is in view.
struct SuggestionListView: View {
    let rows: [SuggestionRow]
    let highlight: Int
    let agentName: String
    let incognito: Bool
    /// The panel with bars: the Ask row shows the logo, as the field does.
    var usesLogo = false
    var activate: (Int) -> Void = { _ in }

    static let rowHeight: CGFloat = 24
    static let verticalPadding: CGFloat = 4
    static let visibleLimit = InstantActionRule.maximumMatches + 1

    static func visibleRows(_ count: Int) -> Int { min(count, visibleLimit) }

    /// The list's height for this many rows, with the hairline above it. Zero for none.
    static func height(rowCount: Int) -> CGFloat {
        rowCount == 0 ? 0 : 1 + verticalPadding * 2 + rowHeight * CGFloat(rowCount)
    }

    var body: some View {
        let window = CommandHint.window(count: rows.count, selection: highlight, limit: Self.visibleLimit)
        VStack(spacing: 0) {
            PanelDivider()
            VStack(spacing: 0) {
                ForEach(window, id: \.self) { index in
                    SuggestionRowView(
                        row: rows[index], highlighted: index == highlight, agentName: agentName, incognito: incognito,
                        usesLogo: usesLogo)
                        .contentShape(.rect)
                        .onTapGesture { activate(index) }
                }
            }
            .padding(.vertical, Self.verticalPadding)
        }
        .frame(height: Self.height(rowCount: window.count), alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(rows.first.map { if case .command = $0 { "Commands" } else { "Matches" } } ?? "")
    }
}

private struct SuggestionRowView: View {
    let row: SuggestionRow
    let highlighted: Bool
    let agentName: String
    let incognito: Bool
    var usesLogo = false
    @Environment(\.panelPalette) private var palette

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 18)
            name
            Spacer(minLength: 8)
            Text(verbatim: kind)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(height: SuggestionListView.rowHeight)
        // The weight stays the same whether highlighted or not. Only the fill changes.
        .background {
            if highlighted { PanelShape.control.fill(palette.textTint(0.08)) }
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(highlighted ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var icon: some View {
        switch row {
        case .candidate(let candidate):
            SuggestionIcon(target: candidate.target, size: 16)
        case .ask:
            // The field shows its own mark when the Ask row is highlighted, so the row does too.
            if usesLogo { LogoMark(size: 10) } else { PromptMark(size: 11) }
        case .command:
            Color.clear
        }
    }

    @ViewBuilder private var name: some View {
        switch row {
        case .candidate(let candidate):
            Text(verbatim: candidate.title)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        case .ask(let text):
            Text(verbatim: "Ask \(agentName): “\(text)”")
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        case .command(let item):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                // A column wide enough for most names keeps the descriptions in line.
                Text(verbatim: item.name)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: 120, alignment: .leading)
                Text(verbatim: item.summary(incognito: incognito))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var kind: String {
        switch row {
        case .candidate(let candidate):
            switch candidate.target {
            case .application: "app"
            case .quickAction: "quick action"
            }
        case .ask: Mark.commandReturn
        case .command(let item):
            if case .skill = item { "skill" } else { "command" }
        }
    }

    private var spoken: String {
        switch row {
        case .candidate(let candidate):
            switch candidate.target {
            case .application: "\(candidate.title), app"
            case .quickAction: "\(candidate.title), quick action"
            }
        case .ask(let text): "Ask \(agentName): \(text)"
        case .command(let item): "\(item.name), \(item.summary(incognito: incognito))"
        }
    }
}
