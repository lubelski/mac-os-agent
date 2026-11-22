import Foundation

/// What the owner typed, read as a possible instant action: an optional verb such as "open",
/// and the subject after it, such as "safari". Only the shape is checked here. Whether the
/// subject names something is up to the providers and `InstantActionRule`.
///
/// A phrase has a shape only when the whole input could be a short command: a few words, no
/// line breaks, and no sentence punctuation. Anything longer or punctuated is a message for
/// the agent, and `parse` returns nil without asking any provider.
public struct InstantPhrase: Sendable, Equatable {
    /// The input with spaces around it removed and runs of spaces collapsed.
    public var text: String
    /// The verb it starts with, lowercased, such as "open" or "switch to". Nil for a bare subject.
    public var verb: String?
    /// The rest of the input, as typed.
    public var subject: String
    /// The subject's words, lowercased.
    public var words: [String]

    /// The longest subject that still reads as a name. App names run to three or four words,
    /// such as "Microsoft Remote Desktop".
    public static let maximumWords = 4
    /// Longer input is a message, whatever it says.
    public static let maximumLength = 48

    /// Characters that make the input a sentence, a path, a command, or code. A full stop is
    /// allowed inside a word, for names such as "zoom.us", but not at the end.
    static let sentenceCharacters = CharacterSet(charactersIn: "?!,;:\"“”‘’'`()[]{}<>/\\|@#$%^*=~…")

    public init(text: String, verb: String?, subject: String) {
        self.text = text
        self.verb = verb
        self.subject = subject
        words = subject.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// The phrase the input is, or nil when its shape is not a short command.
    /// - Parameter verbs: the verbs any provider accepts, lowercased, such as "open" and "switch to".
    public static func parse(_ input: String, verbs: Set<String>) -> InstantPhrase? {
        guard !input.contains(where: \.isNewline) else { return nil }
        let tokens = input.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return nil }
        let text = tokens.joined(separator: " ")
        guard text.count <= maximumLength,
              text.unicodeScalars.allSatisfy({ !sentenceCharacters.contains($0) }),
              !text.hasSuffix("."), !text.hasPrefix(".")
        else { return nil }
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }

        let lowered = tokens.map { $0.lowercased() }
        // The longest verb first, so "switch to" is not read as a verb "switch".
        for length in [2, 1] where tokens.count > length {
            let candidate = lowered.prefix(length).joined(separator: " ")
            if verbs.contains(candidate) {
                let subject = tokens.dropFirst(length).joined(separator: " ")
                guard tokens.count - length <= maximumWords else { return nil }
                return InstantPhrase(text: text, verb: candidate, subject: subject)
            }
        }
        guard tokens.count <= maximumWords else { return nil }
        return InstantPhrase(text: text, verb: nil, subject: text)
    }

    /// The subject as the learned-use history keys it: lowercased, single spaces.
    public var key: String { words.joined(separator: " ") }

    /// True when a subject word is one that never names anything by itself, such as "the",
    /// "is", or "it". "open the door" and "is xcode running" have one.
    public var hasFunctionWord: Bool { words.contains(where: InstantWords.function.contains) }

    /// True when the subject is a single everyday word, such as "find", "help", or "what".
    public var isEverydayWord: Bool {
        words.count == 1 && (InstantWords.everyday.contains(words[0]) || InstantWords.function.contains(words[0]))
    }

    /// The length of the subject in letters and digits.
    public var normalizedLength: Int { ApplicationMatcher.normalized(subject).count }
}

/// Word lists for the confidence rule. They are about what people type to an agent, not about
/// any one provider.
public enum InstantWords {
    /// Words that hold a sentence together and never name an app by themselves. A subject with
    /// one of these is a sentence fragment, unless the whole subject is exactly a name, such as
    /// "Find My".
    public static let function = Set<String>([
        "a", "an", "the", "my", "your", "our", "their", "his", "her", "its", "me", "you", "we", "us",
        "they", "them", "it", "this", "that", "these", "those", "there", "here",
        "i", "im", "is", "are", "was", "were", "be", "been", "am", "isnt", "dont", "cant",
        "and", "or", "but", "nor", "so", "if", "then", "than", "because",
        "to", "of", "for", "with", "without", "in", "on", "at", "by", "from", "into", "onto", "about",
        "up", "down", "out", "off", "over", "under", "again", "back",
        "what", "whats", "why", "how", "when", "where", "who", "which", "whose",
        "can", "could", "would", "should", "will", "shall", "may", "might", "must",
        "do", "does", "did", "done", "have", "has", "had",
        "please", "pls", "plz", "not", "no", "yes", "all", "some", "any", "every", "each",
        "new", "now", "just", "also", "too", "very", "more", "most", "much", "many", "other",
    ])

    /// Everyday words and replies that someone might send an agent on their own, and that are
    /// also the start of some app's name: "find" for Finder, "pass" for Passwords, "what" for
    /// WhatsApp. On their own they never open anything unless they are exactly an app's name.
    public static let everyday = Set<String>([
        // Replies.
        "ok", "okay", "k", "kk", "y", "n", "yep", "yeah", "yup", "nope", "nah", "sure", "fine", "cool",
        "great", "good", "nice", "thanks", "thank", "thx", "ty", "cheers", "hi", "hey", "hello", "bye",
        "sorry", "oops", "wait", "hold", "later", "never", "maybe", "right", "wrong", "correct",
        "agreed", "perfect", "lol", "hmm", "huh", "go", "stop", "cancel", "continue", "proceed",
        "retry", "again", "undo", "redo", "skip", "next", "previous", "prev", "more", "less", "same",
        "both", "neither", "either", "first", "second", "third", "last", "one", "two", "three",
        "four", "five", "ten", "all", "none", "nothing", "everything", "something", "anything",
        "help", "test", "testing", "status", "ping",
        // Everyday verbs.
        "find", "search", "look", "show", "see", "watch", "read", "write", "type", "make", "build",
        "get", "give", "take", "put", "set", "change", "fix", "check", "try", "use", "run", "start",
        "launch", "open", "close", "quit", "exit", "kill", "end", "finish", "save", "send", "share",
        "move", "copy", "paste", "cut", "delete", "remove", "clear", "clean", "empty", "add", "create",
        "rename", "sort", "list", "count", "turn", "switch", "toggle", "play", "pause", "resume",
        "record", "call", "text", "message", "email", "mail", "post", "print", "scan", "sync",
        "update", "upgrade", "install", "uninstall", "download", "upload", "back", "forward",
        "sleep", "wake", "lock", "unlock", "restart", "reboot", "shutdown", "log", "login", "logout",
        "remind", "schedule", "plan", "book", "order", "buy", "pay", "translate", "explain",
        "summarize", "tell", "ask", "answer", "think", "remember", "forget", "keep", "work", "focus",
        "pass", "press", "click", "tap", "drag", "drop", "speak", "say", "talk", "listen",
        "draw", "paint", "note", "track", "time", "wait", "hide", "unhide", "mute", "unmute",
        // Everyday nouns that start app names.
        "photo", "pic", "pics", "picture", "image", "screen", "screenshot", "window", "desktop", "file", "files",
        "folder", "document", "doc", "docs", "page", "app", "apps", "application", "system",
        "activity", "font", "voice", "audio", "sound", "video", "movie", "image", "camera", "home",
        "work", "school", "day", "week", "month", "year", "today", "tomorrow", "yesterday",
        "morning", "night", "tonight", "weekend", "monday", "tuesday", "wednesday", "thursday",
        "friday", "saturday", "sunday", "info", "information", "network", "wifi", "bluetooth",
        "battery", "disk", "storage", "memory", "space", "keyboard", "mouse", "display", "monitor",
        "brightness", "volume", "wallpaper", "background", "theme", "dark", "light", "color",
        "colour", "password", "key", "keys", "game", "games", "chat", "code",
        "word", "words", "link", "links", "web", "site", "website", "internet", "news", "weather",
        "stock", "stocks", "money", "price", "map", "direction", "directions", "meeting", "event",
        "events", "task", "tasks", "todo", "todos", "list", "lists", "idea", "ideas", "journal",
        "diary", "draft", "drafts", "short", "shortcut", "dictionary", "thesaurus",
        "clipboard", "trash", "bin", "update", "updates", "error", "errors", "issue", "problem",
        "question", "hello", "world", "yes", "no", "what", "who",
    ])
}
