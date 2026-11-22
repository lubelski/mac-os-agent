import Foundation

/// A command the owner types into the panel, such as `/new`. The app handles it itself: it is
/// never sent to the model or written to the thread.
///
/// A message counts as a command only when it is exactly a known command's name, apart from
/// spaces around it and letter case. Anything else that starts with a slash, such as
/// `/usr/bin is slow`, goes to the model as a normal message.
///
/// To add a command, add a case with its name and summary here, and handle it in the app.
public enum SlashCommand: String, CaseIterable, Sendable, Equatable {
    case new
    case incognito

    /// What the owner types, with its slash.
    public var name: String { "/" + rawValue }

    /// A few words for the hint shown as the owner types.
    public var summary: String {
        switch self {
        case .new: "Start a new episode"
        case .incognito: "Start or end an incognito episode. Nothing from it is kept."
        }
    }

    /// The command a message is, or nil when it should go to the model.
    public static func parse(_ text: String) -> SlashCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        return SlashCommand(rawValue: String(trimmed.dropFirst()).lowercased())
    }

    /// The commands that start with what the owner has typed so far, for the hint under the
    /// text field. Empty unless the text is a slash followed by letters only.
    public static func suggestions(for text: String) -> [SlashCommand] {
        guard text.hasPrefix("/"), !text.contains(where: { $0.isWhitespace }) else { return [] }
        let typed = text.dropFirst().lowercased()
        guard typed.allSatisfy(\.isLetter) else { return [] }
        return allCases.filter { $0.rawValue.hasPrefix(typed) }
    }
}
