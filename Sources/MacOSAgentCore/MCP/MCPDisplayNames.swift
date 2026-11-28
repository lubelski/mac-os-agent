import Foundation

/// A machine name made readable for a person, such as `github-pr-explorer` to
/// "Github PR Explorer" and `get_attachment` to "Get Attachment".
///
/// The name is split into words at hyphens, underscores, dots, slashes, colons, and spaces, and
/// where camel case changes from lower case or a digit to a capital (`getAttachment`), or a run
/// of capitals ends before a lower-case letter (`HTTPServer`). Digits stay in the word they are
/// in (`s3`, `v2`). A name with no lower-case letters is read as lower case, so `SEND_EMAIL` is
/// "Send Email". Each word then starts with a capital, except:
///
/// - a word that is already all capitals and at least two letters long stays as it is (`HTTP`),
/// - a few very common short forms are written in capitals (`acronyms`),
/// - a few short joining words are lower case after the first word (`minorWords`), so
///   `add_to_list` is "Add to List".
///
/// It is for Settings only. The model is always sent the literal name.
public enum HumanizedName {
    /// Short forms written in capitals wherever they are a word of their own. Kept to a few on
    /// purpose: a longer list guesses wrong more often than it helps.
    public static let acronyms: Set<String> = ["api", "id", "mcp", "pr", "ui", "url"]
    /// Words that stay lower case unless they come first.
    public static let minorWords: Set<String> = ["a", "an", "and", "as", "at", "by", "for", "from", "in", "of", "on", "or", "the", "to", "with"]

    public static func from(_ name: String) -> String {
        let source = name.contains(where: \.isLowercase) ? name : name.lowercased()
        let words = split(source)
        guard !words.isEmpty else { return name }
        return words.enumerated().map { index, word in style(word, isFirst: index == 0) }.joined(separator: " ")
    }

    static func split(_ name: String) -> [String] {
        let separators: Set<Character> = ["-", "_", ".", "/", ":"]
        let characters = Array(name)
        var words: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { words.append(current) }
            current = ""
        }
        for (index, character) in characters.enumerated() {
            if separators.contains(character) || character.isWhitespace {
                flush()
                continue
            }
            if let last = current.last, character.isUppercase {
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                if last.isLowercase || last.isNumber {
                    flush()
                } else if last.isUppercase, let next, next.isLowercase {
                    flush()
                }
            }
            current.append(character)
        }
        flush()
        return words
    }

    static func style(_ word: String, isFirst: Bool) -> String {
        let letters = word.filter(\.isLetter)
        if letters.count >= 2, letters.allSatisfy(\.isUppercase) { return word }
        let lower = word.lowercased()
        if acronyms.contains(lower) { return word.uppercased() }
        if !isFirst, minorWords.contains(lower) { return lower }
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst()
    }
}

/// What a server says about itself when it connects: the `serverInfo` and `instructions` of its
/// answer to `initialize`. Kept with its cached tools, so Settings can show it before the
/// server connects again. None of it reaches the model.
public struct MCPServerInfo: Sendable, Equatable, Codable {
    public var name: String
    public var title: String?
    public var version: String
    public var description: String?
    /// What the server suggests a model be told about it. The app does not send it.
    public var instructions: String?

    public init(name: String, title: String? = nil, version: String, description: String? = nil, instructions: String? = nil) {
        self.name = name
        self.title = title
        self.version = version
        self.description = description
        self.instructions = instructions
    }
}

/// A server's description in Settings, and where it came from.
public struct MCPServerSummary: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// `description` in the server's entry in `mcp-servers.json`, which the owner writes.
        case file
        /// `serverInfo.description` from the server.
        case server
        /// The first sentence of the server's `instructions`.
        case instructions
    }

    public var text: String
    public var source: Source

    public init(text: String, source: Source) {
        self.text = text
        self.source = source
    }

    /// The owner's description, else the server's own, else the first sentence of its
    /// instructions. Nil when there is none.
    public static func resolve(entry: MCPServerEntry, info: MCPServerInfo?) -> MCPServerSummary? {
        func clean(_ text: String?) -> String? {
            guard let text else { return nil }
            let line = AgentInstructions.singleLine(text)
            return line.isEmpty ? nil : line
        }
        if let text = clean(entry.description) { return MCPServerSummary(text: text, source: .file) }
        if let text = clean(info?.description) { return MCPServerSummary(text: text, source: .server) }
        if let text = clean(info?.instructions) {
            let sentence = text.range(of: ". ").map { String(text[..<$0.lowerBound]) + "." } ?? text
            return MCPServerSummary(text: sentence, source: .instructions)
        }
        return nil
    }
}
