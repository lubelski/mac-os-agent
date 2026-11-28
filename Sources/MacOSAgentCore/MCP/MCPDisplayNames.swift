import Foundation

/// A machine name made readable for a person, such as `github-pr-explorer` to
/// "Github PR Explorer" and `get_attachment` to "Get Attachment".
///
/// The name is split into words at hyphens, underscores, dots, slashes, colons, and spaces, and
/// where camel case changes from lower case or a digit to a capital (`getAttachment`), or a run
/// of capitals ends before a lower-case letter (`HTTPServer`). Digits stay in the word they are
/// in (`s3`, `v2`). A name with no lower-case letters is read as lower case, so `SEND_EMAIL` is
/// "Send Email".
///
/// The words then take the repo's title style, Apple's: every word starts with a capital, except
/// the articles, the coordinating conjunctions, and the prepositions of four letters or fewer
/// (`minorWords`), which are lower case unless they are the first or the last word. So
/// `add_to_list` is "Add to List" and `log_in` is "Log In". A minor word that is part of the verb
/// before it is capitalized wherever it falls, so `set_up_account` is "Set Up Account". The name
/// cannot be parsed for that, so it takes a short table of verbs and their particles
/// (`phrasalVerbs`), used only when the particle directly follows the verb: `log_in_to_account` is
/// "Log In to Account", while `search_in_files` keeps "Search in Files". Two more exceptions
/// come first:
///
/// - a word that is already all capitals and at least two letters long stays as it is (`HTTP`),
/// - a few very common short forms are written in capitals (`acronyms`).
///
/// It is for people only. The model is always sent the literal name.
public enum HumanizedName {
    /// Short forms written in capitals wherever they are a word of their own. Kept to a few on
    /// purpose: a longer list guesses wrong more often than it helps.
    public static let acronyms: Set<String> = ["api", "id", "mcp", "pr", "ui", "url"]
    /// Words that stay lower case unless they come first or last: the articles, the coordinating
    /// conjunctions, and the prepositions of four letters or fewer, as Apple's title style has them.
    public static let minorWords: Set<String> = articles.union(conjunctions).union(shortPrepositions)
    static let articles: Set<String> = ["a", "an", "the"]
    static let conjunctions: Set<String> = ["and", "but", "for", "nor", "or", "so", "yet"]
    static let shortPrepositions: Set<String> = [
        "at", "by", "for", "from", "in", "into", "of", "off", "on", "onto", "out", "over", "to", "up", "with",
    ]

    /// Verbs and the particle that is part of them, capitalized when it directly follows the verb.
    /// Only particles that are minor words are listed, since the others are capitalized anyway.
    /// Kept to common pairs whose verb rarely comes before the same word as a plain preposition:
    /// "check in" is left out because `check_in_cache` asks whether something is in the cache.
    public static let phrasalVerbs: [String: Set<String>] = [
        "back": ["up"],
        "check": ["out"],
        "clean": ["up"],
        "lock": ["out"],
        "log": ["in", "out"],
        "look": ["up"],
        "opt": ["in", "out"],
        "pick": ["up"],
        "hand": ["off", "over"],
        "power": ["on", "off"],
        "scale": ["up"],
        "set": ["up"],
        "sign": ["in", "out", "up"],
        "start": ["up"],
        "switch": ["on", "off"],
        "turn": ["on", "off"],
        "zoom": ["in", "out"],
    ]

    public static func from(_ name: String) -> String {
        let source = name.contains(where: \.isLowercase) ? name : name.lowercased()
        let words = split(source)
        guard !words.isEmpty else { return name }
        return words.enumerated().map { index, word in
            let isParticle = index > 0 && phrasalVerbs[words[index - 1].lowercased()]?.contains(word.lowercased()) == true
            return style(word, capitalizesMinorWord: index == 0 || index == words.count - 1 || isParticle)
        }.joined(separator: " ")
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

    /// - Parameter capitalizesMinorWord: True for the first and last word, and a particle that is part of the verb before it.
    static func style(_ word: String, capitalizesMinorWord: Bool) -> String {
        let letters = word.filter(\.isLetter)
        if letters.count >= 2, letters.allSatisfy(\.isUppercase) { return word }
        let lower = word.lowercased()
        if acronyms.contains(lower) { return word.uppercased() }
        if !capitalizesMinorWord, minorWords.contains(lower) { return lower }
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

/// The third line of a server's row in Settings: its description, or a placeholder when it has
/// none. The line is always there, so every row has the same three lines and the same height.
public enum MCPServerRowDescription: Sendable, Equatable {
    case description(String)
    case placeholder

    public static let placeholderText = "No description"

    public init(_ summary: MCPServerSummary?) {
        self = summary.map { .description($0.text) } ?? .placeholder
    }

    public var text: String {
        switch self {
        case .description(let text): text
        case .placeholder: Self.placeholderText
        }
    }

    public var isPlaceholder: Bool { self == .placeholder }
}
