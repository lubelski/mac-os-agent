import Foundation

/// Best-effort syntax highlighting, as pure functions from text to spans. A view colors the
/// spans and leaves the rest of the text plain, so the text itself, and what is copied, never
/// changes. Settings, Tools uses it for a tool's description and its JSON Schema. It is meant
/// for other places too, such as a shell command on a go-ahead card.
///
/// It is never sure of anything. Text that may not be code stays plain, since a wrong color
/// reads worse than none.
public enum CodeHighlighting {
    /// What a span of text is, which picks its color.
    public enum Kind: Sendable, Equatable {
        /// A command, cmdlet, or other word in a command's place, such as `tr` or `Get-FileHash`.
        case command
        /// A variable, read (`$file`) or assigned (`file=`).
        case variable
        case string
        case comment
        /// A command's option, such as `-d` or `-Algorithm`.
        case option
        case number
        /// Operators, brackets, and separators, drawn quieter than the rest.
        case punctuation
        /// A type name, such as `[IO.File]` in PowerShell.
        case type
        /// A key in a JSON object.
        case key
        /// `true`, `false`, or `null` in JSON.
        case literal
        /// A backticked name or snippet in prose.
        case inlineCode
        /// A short line ending in a colon that introduces code, such as "PowerShell:".
        case heading
    }

    public struct Span: Sendable, Equatable {
        public var range: Range<String.Index>
        public var kind: Kind

        public init(_ range: Range<String.Index>, _ kind: Kind) {
            self.range = range
            self.kind = kind
        }
    }

    /// What one line of free text was taken to be.
    public enum LineKind: Sendable, Equatable {
        case prose
        case blank
        /// A short line introducing the code under it.
        case heading
        /// A line of shell or PowerShell.
        case shell
        /// A line inside a Markdown fence whose language is not highlighted, or a fence itself.
        case plainCode
        /// A line inside a JSON fence.
        case json
    }

    // MARK: - Free text

    /// Spans for free text, such as a tool's description from an MCP server: backticked spans
    /// in prose, and lines that look like shell or PowerShell. See `lineKinds(of:)`.
    public static func freeText(_ text: String) -> [Span] {
        let lines = Self.lines(of: text)
        let kinds = lineKinds(lines.map { String(text[$0]) })
        var spans: [Span] = []
        var jsonRun: Range<String.Index>?
        func flushJSON() {
            if let run = jsonRun { spans += json(text, in: run) }
            jsonRun = nil
        }
        for (range, kind) in zip(lines, kinds) {
            if kind == .json {
                jsonRun = jsonRun.map { $0.lowerBound..<range.upperBound } ?? range
                continue
            }
            flushJSON()
            switch kind {
            case .prose: spans += inlineCode(text, in: range)
            case .heading: spans.append(Span(range, .heading))
            case .shell: spans += shell(text, in: range)
            case .plainCode:
                let line = text[range].trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("```") || line.hasPrefix("~~~") { spans.append(Span(range, .punctuation)) }
            case .blank, .json: break
            }
        }
        flushJSON()
        return spans
    }

    /// What each line of free text is taken to be, given the text's lines.
    ///
    /// - Lines between Markdown fences are code: shell for a shell language or none, JSON for
    ///   json, and plain for any other language.
    /// - Elsewhere the text is read in blocks, runs of lines without a blank one. A block whose
    ///   first line is short and ends in a colon ("Unix-like shells:") is code under a heading
    ///   when at least half of the lines under it look like code. A block of two or more lines
    ///   is code when two thirds of them look like code. Otherwise a line is code on its own
    ///   only when it starts the way code does, such as `name=value` or `$name = value`, and
    ///   everything else is prose.
    public static func lineKinds(_ lines: [String]) -> [LineKind] {
        var kinds = [LineKind](repeating: .prose, count: lines.count)
        var index = 0
        var block: [Int] = []
        func closeBlock() {
            classify(block: block, lines: lines, into: &kinds)
            block = []
        }
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if let fence = fenceMarker(trimmed) {
                closeBlock()
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
                let inner: LineKind = shellLanguages.contains(language) ? .shell : language == "json" ? .json : .plainCode
                kinds[index] = .plainCode
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    kinds[index] = lines[index].trimmingCharacters(in: .whitespaces).isEmpty ? .blank : inner
                    index += 1
                }
                if index < lines.count { kinds[index] = .plainCode }
                index += 1
                continue
            }
            if trimmed.isEmpty {
                closeBlock()
                kinds[index] = .blank
            } else {
                block.append(index)
            }
            index += 1
        }
        closeBlock()
        return kinds
    }

    private static let shellLanguages: Set = ["", "sh", "bash", "zsh", "shell", "console", "powershell", "ps1", "pwsh"]

    private static func fenceMarker(_ trimmed: String) -> String? {
        if trimmed.hasPrefix("```") { return "```" }
        if trimmed.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func classify(block: [Int], lines: [String], into kinds: inout [LineKind]) {
        guard !block.isEmpty else { return }
        let evidence = block.map { codeEvidence(lines[$0]) }
        // A sentence among the lines means the block is prose that mentions code.
        let hasSentence = block.dropFirst().contains { looksLikeSentence(lines[$0]) }
        let first = lines[block[0]].trimmingCharacters(in: .whitespaces)
        if block.count >= 2, !hasSentence, evidence[0] == .none, first.hasSuffix(":"), first.count <= 48 {
            let body = evidence.dropFirst()
            if body.filter({ $0 != .none }).count * 2 >= body.count {
                kinds[block[0]] = .heading
                for index in block.dropFirst() { kinds[index] = .shell }
                return
            }
        }
        if block.count >= 2, !hasSentence, !looksLikeSentence(lines[block[0]]),
           evidence.filter({ $0 != .none }).count * 3 >= block.count * 2 {
            for index in block { kinds[index] = .shell }
            return
        }
        for (index, strength) in zip(block, evidence) where strength == .strong {
            kinds[index] = .shell
        }
    }

    enum Evidence { case none, weak, strong }

    /// A line that reads as a sentence: it starts with a capital, has a few words, and ends
    /// with a period.
    static func looksLikeSentence(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.first?.isUppercase == true, trimmed.hasSuffix(".") else { return false }
        return trimmed.split(separator: " ").count >= 4
    }

    /// How sure a line is to be shell or PowerShell. Strong evidence is how a line of code
    /// starts. Weak evidence is something code has in it, which prose seldom does.
    static func codeEvidence(_ line: String) -> Evidence {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for pattern in strongPatterns where trimmed.firstMatch(of: pattern) != nil { return .strong }
        for pattern in weakPatterns where trimmed.firstMatch(of: pattern) != nil { return .weak }
        return .none
    }

    nonisolated(unsafe) private static let strongPatterns: [Regex<Substring>] = [
        // name=value in a shell, with nothing between the name and the value.
        /^[A-Za-z_][A-Za-z0-9_]*=[^\s=]/,
        // $name = value in PowerShell.
        /^\$[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_]\w*)*\s*=\s*\S/,
        // A prompt, a shebang, or export.
        /^\$ \S/, /^#!\//, /^export [A-Za-z_]/,
        // A PowerShell cmdlet, Verb-Noun.
        /^(?:Get|Set|New|Remove|Invoke|Add|Start|Stop|Test|Write|Read|Import|Export|Out|Select|Where|ForEach|Convert(?:To|From)?)-[A-Z][A-Za-z]+/,
        // A common command, lowercase, with an option, a path, or a quote after it.
        /^(?:sudo|curl|wget|git|npm|npx|pnpm|yarn|brew|cd|ls|cat|echo|printf|grep|sed|awk|python3?|pip3?|uvx?|docker|kubectl|swift|xcrun|defaults|open|mkdir|rm|cp|mv|chmod|tar|unzip|shasum|base64|jq|ssh|scp|osascript|plutil|launchctl|codesign) +[-\/~."'$]/,
    ]

    nonisolated(unsafe) private static let weakPatterns: [Regex<Substring>] = [
        /\$\(/, /\$\{[A-Za-z_]/, /\[[A-Za-z][\w.]*\]::/, /\ \| [a-z]/, /^[a-z][\w-]* +-{1,2}[A-Za-z]/,
    ]

    // MARK: - Prose

    /// Backticked spans within one line of prose: the backticks quiet, the text between them
    /// as code. A backtick without its pair stays plain.
    static func inlineCode(_ text: String, in range: Range<String.Index>) -> [Span] {
        var spans: [Span] = []
        var index = range.lowerBound
        while index < range.upperBound {
            guard text[index] == "`",
                  let close = text[text.index(after: index)..<range.upperBound].firstIndex(of: "`")
            else {
                index = text.index(after: index)
                continue
            }
            let inner = text.index(after: index)..<close
            if !inner.isEmpty {
                spans.append(Span(index..<inner.lowerBound, .punctuation))
                spans.append(Span(inner, .inlineCode))
                spans.append(Span(close..<text.index(after: close), .punctuation))
            }
            index = text.index(after: close)
        }
        return spans
    }

    // MARK: - Shell

    /// Spans for text that is all shell or PowerShell, line by line.
    public static func shell(_ text: String) -> [Span] {
        lines(of: text).flatMap { shell(text, in: $0) }
    }

    /// Spans for one line of shell or PowerShell. Both are read with one set of rules, since a
    /// description often shows the two side by side: quotes, `$` variables, `#` comments,
    /// options, numbers, `[Type]` names, and the command at the start of each pipeline part.
    static func shell(_ text: String, in range: Range<String.Index>) -> [Span] {
        var spans: [Span] = []
        var index = range.lowerBound
        var commandPlace = true
        let end = range.upperBound

        func next(_ i: String.Index) -> Character? {
            let after = text.index(after: i)
            return after < end ? text[after] : nil
        }
        func atWordStart(_ i: String.Index) -> Bool {
            i == range.lowerBound || text[text.index(before: i)].isWhitespace || "(=|;".contains(text[text.index(before: i)])
        }

        while index < end {
            let character = text[index]
            if character.isWhitespace {
                index = text.index(after: index)
                continue
            }
            if character == "#", index == range.lowerBound || text[text.index(before: index)].isWhitespace {
                spans.append(Span(index..<end, .comment))
                break
            }
            if character == "'" {
                let close = text[text.index(after: index)..<end].firstIndex(of: "'").map { text.index(after: $0) } ?? end
                spans.append(Span(index..<close, .string))
                index = close
                commandPlace = false
                continue
            }
            if character == "\"" {
                index = doubleQuoted(text, from: index, end: end, into: &spans)
                commandPlace = false
                continue
            }
            if character == "$" {
                if next(index) == "(" {
                    let after = text.index(index, offsetBy: 2)
                    spans.append(Span(index..<after, .punctuation))
                    index = after
                    commandPlace = true
                    continue
                }
                if let variable = variable(text, at: index, end: end) {
                    spans.append(Span(variable, .variable))
                    index = variable.upperBound
                    commandPlace = false
                    continue
                }
            }
            if character == "[", let type = typeName(text, at: index, end: end) {
                spans.append(Span(type, .type))
                index = type.upperBound
                commandPlace = false
                continue
            }
            if "|;&".contains(character) {
                var after = text.index(after: index)
                if after < end, text[after] == character { after = text.index(after: after) }
                spans.append(Span(index..<after, .punctuation))
                index = after
                commandPlace = true
                continue
            }
            if "(){}<>=,".contains(character) {
                spans.append(Span(index..<text.index(after: index), .punctuation))
                index = text.index(after: index)
                commandPlace = character == "("
                continue
            }
            // A word: everything up to a space or a character with a meaning of its own.
            var wordEnd = index
            while wordEnd < end, !text[wordEnd].isWhitespace, !"|;&(){}<>=,'\"$".contains(text[wordEnd]) {
                wordEnd = text.index(after: wordEnd)
            }
            if wordEnd == index { wordEnd = text.index(after: index) }
            let word = text[index..<wordEnd]
            let assigns = wordEnd < end && text[wordEnd] == "=" && index == lineStart(text, range)
            if assigns, word.first.map({ $0.isLetter || $0 == "_" }) == true {
                spans.append(Span(index..<wordEnd, .variable))
            } else if word.first == "-", word.count > 1, atWordStart(index), word.dropFirst().first.map({ $0.isLetter || $0 == "-" }) == true {
                spans.append(Span(index..<wordEnd, .option))
            } else if word.allSatisfy(\.isNumber), atWordStart(index) {
                spans.append(Span(index..<wordEnd, .number))
            } else if word.firstMatch(of: /^[A-Z][a-z]+-[A-Z][A-Za-z]+$/) != nil {
                spans.append(Span(index..<wordEnd, .command))
            } else if commandPlace, word.first.map({ $0.isLetter }) == true, !word.contains("::") {
                spans.append(Span(index..<wordEnd, .command))
            }
            commandPlace = false
            index = wordEnd
        }
        return spans
    }

    private static func lineStart(_ text: String, _ range: Range<String.Index>) -> String.Index {
        text[range].firstIndex { !$0.isWhitespace } ?? range.lowerBound
    }

    /// `$name`, `${name}`, `$1`, or `$_` at `index`, or nil when the `$` starts none of them.
    private static func variable(_ text: String, at index: String.Index, end: String.Index) -> Range<String.Index>? {
        var cursor = text.index(after: index)
        guard cursor < end else { return nil }
        if text[cursor] == "{" {
            guard let close = text[cursor..<end].firstIndex(of: "}") else { return nil }
            return index..<text.index(after: close)
        }
        guard text[cursor].isLetter || text[cursor].isNumber || text[cursor] == "_" else { return nil }
        while cursor < end, text[cursor].isLetter || text[cursor].isNumber || text[cursor] == "_" {
            cursor = text.index(after: cursor)
        }
        return index..<cursor
    }

    /// `[IO.File]` at `index`: a bracketed dotted name, as PowerShell writes a type.
    private static func typeName(_ text: String, at index: String.Index, end: String.Index) -> Range<String.Index>? {
        guard let close = text[index..<end].firstIndex(of: "]") else { return nil }
        let inner = text[text.index(after: index)..<close]
        guard inner.firstMatch(of: /^[A-Za-z][\w.]*$/) != nil else { return nil }
        return index..<text.index(after: close)
    }

    /// A double-quoted string from its opening quote, with the variables inside it marked as
    /// variables, since the shell expands them. Returns where the string ends.
    private static func doubleQuoted(_ text: String, from start: String.Index, end: String.Index, into spans: inout [Span]) -> String.Index {
        var segmentStart = start
        var index = text.index(after: start)
        while index < end {
            let character = text[index]
            if character == "\\" {
                index = text.index(after: index)
                if index < end { index = text.index(after: index) }
                continue
            }
            if character == "\"" {
                let after = text.index(after: index)
                spans.append(Span(segmentStart..<after, .string))
                return after
            }
            if character == "$", let variable = variable(text, at: index, end: end) {
                if segmentStart < index { spans.append(Span(segmentStart..<index, .string)) }
                spans.append(Span(variable, .variable))
                index = variable.upperBound
                segmentStart = index
                continue
            }
            index = text.index(after: index)
        }
        if segmentStart < end { spans.append(Span(segmentStart..<end, .string)) }
        return end
    }

    // MARK: - JSON

    /// Spans for JSON text: keys, strings, numbers, `true`, `false`, and `null`, with the
    /// punctuation quieter. Text that is not JSON gets whatever spans it seems to have.
    public static func json(_ text: String) -> [Span] {
        json(text, in: text.startIndex..<text.endIndex)
    }

    static func json(_ text: String, in range: Range<String.Index>) -> [Span] {
        var spans: [Span] = []
        var index = range.lowerBound
        let end = range.upperBound
        while index < end {
            let character = text[index]
            if character == "\"" {
                var cursor = text.index(after: index)
                while cursor < end, text[cursor] != "\"" {
                    if text[cursor] == "\\" { cursor = text.index(after: cursor) }
                    if cursor < end { cursor = text.index(after: cursor) }
                }
                let close = cursor < end ? text.index(after: cursor) : end
                // A string followed by a colon is a key.
                let rest = text[close..<end].drop { $0 == " " || $0 == "\t" }
                spans.append(Span(index..<close, rest.first == ":" ? .key : .string))
                index = close
            } else if "{}[]:,".contains(character) {
                spans.append(Span(index..<text.index(after: index), .punctuation))
                index = text.index(after: index)
            } else if character == "-" || character.isNumber {
                var cursor = text.index(after: index)
                while cursor < end, text[cursor].isNumber || ".eE+-".contains(text[cursor]) {
                    cursor = text.index(after: cursor)
                }
                spans.append(Span(index..<cursor, .number))
                index = cursor
            } else if character.isLetter {
                var cursor = index
                while cursor < end, text[cursor].isLetter { cursor = text.index(after: cursor) }
                if ["true", "false", "null"].contains(text[index..<cursor]) {
                    spans.append(Span(index..<cursor, .literal))
                }
                index = cursor
            } else {
                index = text.index(after: index)
            }
        }
        return spans
    }

    // MARK: - Lines

    /// Each line's range, without its line break.
    static func lines(of text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start = text.startIndex
        while start <= text.endIndex {
            let end = text[start...].firstIndex(where: \.isNewline) ?? text.endIndex
            ranges.append(start..<end)
            guard end < text.endIndex else { break }
            start = text.index(after: end)
        }
        return ranges
    }
}
