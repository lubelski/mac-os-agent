import Foundation

/// The gray text drawn after the insertion point to say what Return will act on, as in
/// Alfred: "chr" shows "ome" and then "Google Chrome". It is never part of the text. The
/// owner cannot select, copy, send, or recall it, and no key puts it in the field, because
/// Return runs the thing itself.
///
/// It has two parts:
/// - `rest`, the rest of the word being typed, when the last word typed starts a word of the
///   name: "ome" for "chr" and Google Chrome.
/// - `name`, the whole name, when the typed text and `rest` together do not already spell it:
///   "Google Chrome" after "chr", but nothing after "saf", whose rest "ari" makes "Safari".
public struct InlineCompletion: Sendable, Equatable {
    public var rest: String
    public var name: String?

    public init(rest: String, name: String? = nil) {
        self.rest = rest
        self.name = name
    }

    public var isEmpty: Bool { rest.isEmpty && name == nil }

    /// The completion for an instant action's name after the typed text. Nil when there is
    /// nothing to add.
    public static func forName(_ name: String, typed: String) -> InlineCompletion? {
        let lastWord = typed.last?.isWhitespace == true ? "" : typed.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
        var rest = ""
        if !lastWord.isEmpty,
           let word = name.split(whereSeparator: \.isWhitespace).first(where: { $0.lowercased().hasPrefix(lastWord.lowercased()) })
        {
            rest = String(word.dropFirst(lastWord.count))
        }
        let spelled = normalized(typed + rest)
        let shownName = spelled == normalized(name) ? nil : name
        let completion = InlineCompletion(rest: rest, name: shownName)
        return completion.isEmpty ? nil : completion
    }

    /// The completion for a slash command's name, such as "w" after "/ne" for `/new`. Nil
    /// once the name is typed in full, or when the typed text is not the start of it, as
    /// while a skill's text is typed after its name.
    public static func forCommand(_ command: String, typed: String) -> InlineCompletion? {
        guard !typed.contains(where: \.isWhitespace), typed.count < command.count,
              command.lowercased().hasPrefix(typed.lowercased())
        else { return nil }
        return InlineCompletion(rest: String(command.dropFirst(typed.count)))
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
