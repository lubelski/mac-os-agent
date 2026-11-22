import AppKit
import AVFoundation
import SwiftUI

/// What a message, a code block, or a command can do besides being read: copy, share, speak.
@MainActor
enum MessageActions {
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static let synthesizer = AVSpeechSynthesizer()

    /// Reads the text aloud in the system voice, or stops if it is already reading.
    static func speak(_ text: String) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
            return
        }
        synthesizer.speak(AVSpeechUtterance(string: text))
    }
}

/// A quiet text control in the scheme of the marks: a lowercase word in the tertiary level,
/// the secondary level under the pointer, never a change of weight. After a click it says
/// "copied" for a moment, as Pi's copy targets do.
struct CopyControl: View {
    var label = "copy"
    let help: String
    let text: () -> String
    @State private var copied = false
    @State private var hovering = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            MessageActions.copy(text())
            copied = true
            resetTask?.cancel()
            resetTask = Task {
                try? await Task.sleep(for: .seconds(1.5))
                if !Task.isCancelled { copied = false }
            }
        } label: {
            // Both words take the same room, so the control never shifts.
            ZStack(alignment: .leading) {
                Text(verbatim: "copied").hidden()
                Text(verbatim: copied ? "copied" : label)
            }
            .font(Mark.rowFont)
            .foregroundStyle(hovering || copied ? HierarchicalShapeStyle.secondary : .tertiary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Shows its content when the pointer is over the area it is attached to, or when the content
/// has keyboard focus, and keeps it in the layout either way, so nothing moves.
struct RevealOnHover: ViewModifier {
    let isHovering: Bool
    @FocusState private var focused: Bool
    @Environment(\.revealsAllControls) private var revealsAll

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .opacity(isHovering || focused || revealsAll ? 1 : 0)
    }
}

extension EnvironmentValues {
    /// Shows every hover control at once, for a preview capture, which has no pointer.
    @Entry var revealsAllControls = false
}

extension View {
    func revealed(when hovering: Bool) -> some View {
        modifier(RevealOnHover(isHovering: hovering))
    }
}

/// The context menu items for a message.
struct MessageMenu: View {
    /// What Copy puts on the clipboard: the Markdown source of a reply, the text of the owner's message.
    let source: String
    /// For a reply, the text without its Markdown. Nil for the owner's messages, which are plain.
    let plainText: String?

    var body: some View {
        Button("Copy") { MessageActions.copy(source) }
        if let plainText {
            Button("Copy as Plain Text") { MessageActions.copy(plainText) }
        }
        Divider()
        ShareLink(item: plainText ?? source)
        Button("Speak") { MessageActions.speak(plainText ?? source) }
    }
}
