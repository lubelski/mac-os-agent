import Foundation

/// Reads a tool's output and lays it out for the inspector, with fixed rules and no model.
/// Each shape is tried in turn on a bounded prefix, and a shape is used only when the whole of
/// that prefix fits it. Anything that does not fit falls back to plain monospaced text, so a
/// wrong guess can only make output plainer, never change what it says.
///
/// All of this is pure and runs off the main thread.
public enum ToolOutputFormat {
    /// Detection looks at no more than this many characters.
    public static let detectionLimit = 64 * 1024
    /// Output longer than this, in UTF-8 bytes, is shown as plain text without trying any shape.
    public static let formattingLimit = 4 * 1024 * 1024
    /// A table shows at most this many rows. The raw view always has all of them.
    public static let tableRowLimit = 5_000
    /// A JSON document with more values than this opens folded below its first two levels.
    public static let foldedJSONSize = 2_000

    public enum Shape: String, Equatable, Sendable {
        case empty = "Empty"
        case json = "JSON"
        case jsonLines = "JSON Lines"
        case fieldTable = "Fields"
        case csv = "CSV"
        case tsv = "Tab separated"
        case columns = "Columns"
        case keyValue = "Keys and values"
        case diff = "Diff"
        case paths = "File paths"
        case markdown = "Markdown"
        case plain = "Plain text"
        case binary = "Binary"
    }

    public struct Table: Equatable, Sendable {
        /// Empty when the table has no header row.
        public var header: [String]
        public var rows: [[String]]
        /// How many rows there were before the row limit.
        public var totalRows: Int

        public init(header: [String], rows: [[String]], totalRows: Int? = nil) {
            self.header = header
            self.rows = rows
            self.totalRows = totalRows ?? rows.count
        }

        public var columnCount: Int { max(header.count, rows.map(\.count).max() ?? 0) }
    }

    public struct KeyValue: Equatable, Sendable {
        public var key: String
        public var value: String
        /// How far the line was indented, in levels, for nested blocks such as system_profiler's.
        public var depth: Int

        public init(key: String, value: String, depth: Int = 0) {
            self.key = key
            self.value = value
            self.depth = depth
        }
    }

    public struct DiffLine: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case file, hunk, added, removed, context, other
        }
        public var kind: Kind
        public var text: String

        public init(_ kind: Kind, _ text: String) {
            self.kind = kind
            self.text = text
        }
    }

    public enum Block: Equatable, Sendable {
        case text(String)
        case json(JSONNode)
        case table(Table)
        case keyValues([KeyValue])
        case diff([DiffLine])
        case paths([String])
        /// Markdown source, for the app's Markdown views. See `MarkdownDocument`.
        case markdown(String)
    }

    public struct Formatted: Equatable, Sendable {
        public var shape: Shape
        public var blocks: [Block]
        /// Why the output is shown plainer than it might be, such as a size limit.
        public var note: String?

        public init(shape: Shape, blocks: [Block], note: String? = nil) {
            self.shape = shape
            self.blocks = blocks
            self.note = note
        }
    }

    // MARK: - Entry point

    /// The output laid out by its shape. `text` should already be the body, without the shell
    /// tool's trailing notes. See `ToolOutputTrailer`.
    public static func format(_ text: String) -> Formatted {
        if text.utf8.count > formattingLimit {
            return Formatted(shape: .plain, blocks: [.text(TerminalText.clean(text).text)],
                             note: "Too large to lay out, so it is shown as plain text.")
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Formatted(shape: .empty, blocks: [])
        }
        // Binary is judged before terminal codes are read, since cleaning would hide its bytes.
        if isBinary(text) {
            return Formatted(shape: .binary, blocks: [.text(TerminalText.visibleControls(text))],
                             note: "This looks like binary data. Control characters are shown as symbols.")
        }
        let cleaned = TerminalText.clean(text)
        let body = cleaned.text
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Formatted(shape: .empty, blocks: [])
        }
        let note = cleaned.removedEscapes ? "Terminal color codes were removed." : nil
        if let formatted = detect(body) {
            return Formatted(shape: formatted.shape, blocks: formatted.blocks, note: formatted.note ?? note)
        }
        return Formatted(shape: .plain, blocks: [.text(body)], note: note)
    }

    static func detect(_ body: String) -> Formatted? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.first, first == "{" || first == "[" {
            if let node = JSONNode.parse(trimmed) { return Formatted(shape: .json, blocks: [.json(node)]) }
            if let lines = jsonLines(trimmed) { return Formatted(shape: .jsonLines, blocks: lines.map(Block.json)) }
        }
        let lines = prefixLines(body)
        if let diff = diff(lines, full: body) { return diff }
        if let fields = fieldTable(body) { return fields }
        if let table = delimited(body, separator: "\t") { return Formatted(shape: .tsv, blocks: [.table(table)]) }
        if let table = delimited(body, separator: ",") { return Formatted(shape: .csv, blocks: [.table(table)]) }
        if let table = columns(body) { return Formatted(shape: .columns, blocks: [.table(table)]) }
        if let pairs = keyValues(body) { return Formatted(shape: .keyValue, blocks: [.keyValues(pairs)]) }
        if let paths = paths(body) { return Formatted(shape: .paths, blocks: [.paths(paths)]) }
        if looksLikeMarkdown(body) { return Formatted(shape: .markdown, blocks: [.markdown(body)]) }
        return nil
    }

    // MARK: - Helpers

    /// The lines of the detection prefix. A line cut off by the limit is left out.
    static func prefixLines(_ text: String) -> [Substring] {
        if text.count <= detectionLimit {
            return text.split(separator: "\n", omittingEmptySubsequences: false).dropLastIfEmpty()
        }
        var lines = text.prefix(detectionLimit).split(separator: "\n", omittingEmptySubsequences: false)
        lines.removeLast()
        return lines
    }

    /// All lines, without the empty one after a final newline.
    static func allLines(_ text: String) -> [Substring] {
        text.split(separator: "\n", omittingEmptySubsequences: false).dropLastIfEmpty()
    }

    /// Binary when the prefix has a NUL, or more than one in a hundred characters are control
    /// characters other than tab and newline, or replacement characters from invalid UTF-8.
    static func isBinary(_ text: String) -> Bool {
        var total = 0
        var odd = 0
        for scalar in text.unicodeScalars.prefix(detectionLimit) {
            total += 1
            if scalar.value == 0 { return true }
            if scalar == "\u{FFFD}" || (scalar.value < 0x20 && !["\t", "\n", "\r", "\u{1B}", "\u{08}", "\u{07}"].contains(scalar)) || (0x7F...0x9F).contains(scalar.value) {
                odd += 1
            }
        }
        return total > 0 && odd * 100 > total
    }

    // MARK: - JSON Lines

    static func jsonLines(_ text: String) -> [JSONNode]? {
        let lines = allLines(text).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 2, lines.count <= tableRowLimit else { return nil }
        var nodes: [JSONNode] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.first == "{" || trimmed.first == "[", let node = JSONNode.parse(trimmed) else { return nil }
            nodes.append(node)
        }
        return nodes
    }

    // MARK: - Diff

    static func diff(_ lines: [Substring], full: String) -> Formatted? {
        var hasFile = false
        var hasHunk = false
        for line in lines.prefix(200) {
            if line.hasPrefix("diff --git ") || line.hasPrefix("+++ ") || line.hasPrefix("--- ") { hasFile = true }
            if line.hasPrefix("@@ ") && line.dropFirst(3).contains("@@") { hasHunk = true }
        }
        guard hasFile, hasHunk else { return nil }
        var inHunk = false
        let parsed = allLines(full).map { line -> DiffLine in
            let text = String(line)
            if line.hasPrefix("diff ") || line.hasPrefix("index ") || line.hasPrefix("--- ") || line.hasPrefix("+++ ")
                || line.hasPrefix("new file mode") || line.hasPrefix("deleted file mode")
            {
                inHunk = false
                return DiffLine(.file, text)
            }
            if line.hasPrefix("@@") { inHunk = true; return DiffLine(.hunk, text) }
            guard inHunk else { return DiffLine(.other, text) }
            if line.hasPrefix("+") { return DiffLine(.added, text) }
            if line.hasPrefix("-") { return DiffLine(.removed, text) }
            if line.hasPrefix(" ") || line.isEmpty { return DiffLine(.context, text) }
            return DiffLine(.other, text)
        }
        return Formatted(shape: .diff, blocks: [.diff(parsed)])
    }

    // MARK: - The native tools' field lines

    /// The native tools write a line that names their fields, such as
    /// `4 events, soonest first, as id | title | when | calendar | details:`, and then one line
    /// per item with the fields joined by ` | `. Lines before that heading and after the
    /// items stay text. Extra fields join the last column, and missing ones are left empty.
    static func fieldTable(_ text: String) -> Formatted? {
        let lines = allLines(text)
        guard let headingIndex = lines.prefix(50).firstIndex(where: { fieldNames(in: $0) != nil }),
              let names = fieldNames(in: lines[headingIndex])
        else { return nil }
        var rows: [[String]] = []
        var end = headingIndex + 1
        while end < lines.count, lines[end].contains(" | ") || (names.count == 1 && !lines[end].isEmpty) {
            rows.append(fields(lines[end], count: names.count))
            end += 1
        }
        guard !rows.isEmpty else { return nil }
        var blocks: [Block] = []
        let before = lines[..<headingIndex].joined(separator: "\n")
        let heading = lines[headingIndex]
        let lead = heading.range(of: ", as ").map { String(heading[..<$0.lowerBound]) + "." } ?? ""
        let intro = [before, lead].filter { !$0.isEmpty }.joined(separator: "\n")
        if !intro.isEmpty { blocks.append(.text(intro)) }
        let shown = Array(rows.prefix(tableRowLimit))
        blocks.append(.table(Table(header: names, rows: shown, totalRows: rows.count)))
        let after = lines[end...].joined(separator: "\n").trimmingCharacters(in: .newlines)
        if !after.isEmpty { blocks.append(.text(after)) }
        return Formatted(shape: .fieldTable, blocks: blocks)
    }

    /// The field names in a heading that ends `as a | b | c:`.
    static func fieldNames(in line: Substring) -> [String]? {
        guard line.hasSuffix(":"), let range = line.range(of: "as ", options: .backwards) else { return nil }
        let before = line[..<range.lowerBound]
        guard before.isEmpty || before.hasSuffix(" ") else { return nil }
        let list = line[range.upperBound...].dropLast()
        let names = list.components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespaces) }
        guard names.count >= 2, names.allSatisfy({ !$0.isEmpty && $0.count <= 40 && !$0.contains(":") }) else { return nil }
        return names
    }

    static func fields(_ line: Substring, count: Int) -> [String] {
        var parts = line.components(separatedBy: " | ")
        if parts.count > count {
            let rest = parts[(count - 1)...].joined(separator: " | ")
            parts = Array(parts[..<(count - 1)]) + [rest]
        }
        while parts.count < count { parts.append("") }
        return parts
    }

    // MARK: - CSV and TSV

    /// A table when every line of the prefix has the same number of fields, at least two, and
    /// there are at least two lines. A comma table also needs short fields, so prose with the
    /// same number of commas on each line stays text.
    static func delimited(_ text: String, separator: Character) -> Table? {
        let lines = prefixLines(text).filter { !$0.isEmpty }
        guard lines.count >= 2 else { return nil }
        guard lines.allSatisfy({ $0.contains(separator) }) else { return nil }
        func parse(_ line: Substring) -> [String]? {
            separator == "," ? csvFields(line) : tabFields(line)
        }
        var parsed: [[String]] = []
        for line in lines {
            guard let row = parse(line) else { return nil }
            parsed.append(row)
        }
        let count = parsed[0].count
        guard count >= 2, parsed.allSatisfy({ $0.count == count }) else { return nil }
        if separator == "," {
            let cells = parsed.flatMap { $0 }
            let average = cells.reduce(0) { $0 + $1.count } / max(cells.count, 1)
            guard average <= 40, !cells.contains(where: { $0.hasPrefix(" ") && $0.count > 1 && !$0.dropFirst().hasPrefix(" ") && $0.split(separator: " ").count > 3 }) else { return nil }
        }
        // Lines past the prefix are read the same way. A line that does not fit ends the table.
        let all = allLines(text).filter { !$0.isEmpty }
        var rows = parsed
        if all.count > lines.count {
            for line in all[lines.count...] {
                guard rows.count < tableRowLimit + 1, let row = parse(line), row.count == count else { break }
                rows.append(row)
            }
        }
        let header = looksLikeHeader(rows[0], below: Array(rows.dropFirst().prefix(20))) ? rows.removeFirst() : []
        let total = max(rows.count, all.count - (header.isEmpty ? 0 : 1))
        return Table(header: header, rows: Array(rows.prefix(tableRowLimit)), totalRows: total)
    }

    static func tabFields(_ line: Substring) -> [String]? {
        line.components(separatedBy: "\t")
    }

    /// RFC 4180 fields, with quotes. Nil for an unfinished quote.
    static func csvFields(_ line: Substring) -> [String]? {
        var fields: [String] = []
        var field = ""
        var quoted = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if quoted {
                if character == "\"" {
                    let next = line.index(after: index)
                    if next < line.endIndex, line[next] == "\"" {
                        field.append("\"")
                        index = next
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(character)
                }
            } else if character == "\"" && field.isEmpty {
                quoted = true
            } else if character == "," {
                fields.append(field)
                field = ""
            } else {
                field.append(character)
            }
            index = line.index(after: index)
        }
        guard !quoted else { return nil }
        fields.append(field.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
        return fields
    }

    /// A first row reads as a header when every cell is a short label with a letter and no
    /// number of its own, and some column below it holds numbers or paths.
    static func looksLikeHeader(_ row: [String], below: [[String]]) -> Bool {
        guard !below.isEmpty else { return false }
        let labels = row.allSatisfy { cell in
            let cell = cell.trimmingCharacters(in: .whitespaces)
            return !cell.isEmpty && cell.count <= 40 && cell.contains(where: \.isLetter) && !looksLikeData(cell)
        }
        guard labels else { return false }
        return below.contains { $0.contains(where: looksLikeData) }
            || Set(row.map { $0.lowercased() }).isDisjoint(with: below.flatMap { $0 }.map { $0.lowercased() }) && row.allSatisfy { $0.first?.isUppercase == true }
    }

    /// Numbers, sizes such as `4.1G`, percentages, dates, and paths.
    static func looksLikeData(_ cell: String) -> Bool {
        let cell = cell.trimmingCharacters(in: .whitespaces)
        guard let first = cell.first else { return false }
        if first == "/" || first == "~" { return true }
        return cell.range(of: #"^[-+]?[0-9][0-9.,:]* ?[A-Za-z%]{0,3}$"#, options: .regularExpression) != nil
    }

    // MARK: - Aligned columns

    /// Text laid out in columns under a header, such as `ps`, `df -h`, or `lsof`. Columns are
    /// the runs of positions that are not blank on every line, so both left and right aligned
    /// columns work. The header names them, and any extra runs join the last column, which is
    /// where a command line with spaces in it ends up.
    static func columns(_ text: String) -> Table? {
        let lines = prefixLines(text).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 3, !lines.contains(where: { $0.contains("\t") }) else { return nil }
        let header = lines[0]
        let names = header.split(separator: " ").map(String.init)
        guard names.count >= 2, names.allSatisfy({ name in
            name.contains(where: \.isLetter) && !looksLikeData(name) && !name.hasPrefix("/") && !name.contains(".")
        }) else { return nil }
        let grids = lines.map { Array($0) }
        let width = grids.map(\.count).max() ?? 0
        var blank = [Bool](repeating: true, count: width)
        for grid in grids {
            for (position, character) in grid.enumerated() where character != " " { blank[position] = false }
        }
        var runs: [Range<Int>] = []
        var start: Int?
        for position in 0...width {
            let isBlank = position == width || blank[position]
            if !isBlank, start == nil { start = position }
            if isBlank, let begin = start {
                runs.append(begin..<position)
                start = nil
            }
        }
        // Each run holds at most one header word, so the header lines up with the columns. Only
        // the last may hold more, as in `Mounted on`. A run with no header word belongs to the
        // column before it.
        let headerGrid = grids[0]
        let words = runs.map { run in
            String(headerGrid[min(run.lowerBound, headerGrid.count)..<min(run.upperBound, headerGrid.count)]).split(separator: " ").count
        }
        guard !words.dropLast().contains(where: { $0 > 1 }), words.first ?? 0 > 0 else { return nil }
        var columnsRanges: [Range<Int>] = []
        for (index, run) in runs.enumerated() {
            if words[index] == 0, let last = columnsRanges.popLast() {
                columnsRanges.append(last.lowerBound..<run.upperBound)
            } else {
                columnsRanges.append(run)
            }
        }
        guard columnsRanges.count >= 2 else { return nil }
        // The final column runs to the end of every line.
        columnsRanges[columnsRanges.count - 1] = columnsRanges[columnsRanges.count - 1].lowerBound..<Int.max

        func cells(_ line: Substring) -> [String] {
            let grid = Array(line)
            return columnsRanges.map { range in
                let low = min(range.lowerBound, grid.count)
                let high = min(range.upperBound, grid.count)
                return String(grid[low..<high]).trimmingCharacters(in: .whitespaces)
            }
        }
        // A data line with text in a blank gutter would have stopped this, so the whole output
        // is checked the same way: past the prefix, a line that crosses a gutter ends the table.
        let all = allLines(text).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let headerCells = cells(header)
        var rows: [[String]] = []
        for (index, line) in all.enumerated().dropFirst() {
            if index >= lines.count {
                let grid = Array(line)
                let crosses = columnsRanges.dropLast().indices.contains { column in
                    let gap = columnsRanges[column].upperBound
                    return gap < grid.count && gap < columnsRanges[column + 1].lowerBound && grid[gap] != " "
                }
                if crosses || rows.count >= tableRowLimit { break }
            }
            rows.append(cells(line))
        }
        // Some column must hold data, such as numbers, sizes, or paths, under a header that is a
        // label. Repeated lines of words share their gaps too, and are not a table.
        let hasDataColumn = headerCells.indices.contains { column in
            !looksLikeData(headerCells[column]) && rows.prefix(50).contains { $0.indices.contains(column) && looksLikeData($0[column]) }
        }
        guard hasDataColumn else { return nil }
        return Table(header: headerCells, rows: rows, totalRows: all.count - 1)
    }

    // MARK: - Keys and values

    private static let keyValuePattern = try! NSRegularExpression(
        pattern: #"^(\s*)([A-Za-z][A-Za-z0-9 _.\-/()#]{0,48}?)\s*(?::|=)(?:\s+(.*)|$)"#)
    private static let equalsPattern = try! NSRegularExpression(
        pattern: #"^(\s*)([A-Za-z_][A-Za-z0-9_.\-]{0,48})=(.*)$"#)

    /// `key: value` or `key = value` lines, at least two, with at most one line in ten that
    /// is neither. A line indented under a pair continues its value. A key with an empty value
    /// heads the pairs indented below it.
    static func keyValues(_ text: String) -> [KeyValue]? {
        let lines = prefixLines(text).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 2 else { return nil }
        var pairs: [KeyValue] = []
        var misses = 0
        var indents: [Int] = []
        for line in lines {
            let string = String(line)
            let range = NSRange(string.startIndex..., in: string)
            let match = keyValuePattern.firstMatch(in: string, range: range) ?? equalsPattern.firstMatch(in: string, range: range)
            guard let match, let keyRange = Range(match.range(at: 2), in: string) else {
                if let last = pairs.last, line.first?.isWhitespace == true {
                    pairs[pairs.count - 1].value += (last.value.isEmpty ? "" : "\n") + line.trimmingCharacters(in: .whitespaces)
                } else {
                    misses += 1
                }
                continue
            }
            let indent = Range(match.range(at: 1), in: string).map { string[$0].count } ?? 0
            let value = Range(match.range(at: 3), in: string).map { String(string[$0]) } ?? ""
            while let last = indents.last, last > indent { indents.removeLast() }
            if indents.last != indent { indents.append(indent) }
            let key = String(string[keyRange]).trimmingCharacters(in: .whitespaces)
            // A long sentence ending in a colon is prose, not a key.
            if key.split(separator: " ").count > 5 { misses += 1; continue }
            pairs.append(KeyValue(key: key, value: value.trimmingCharacters(in: .whitespaces), depth: indents.count - 1))
        }
        guard pairs.count >= 2, misses * 10 <= lines.count, pairs.contains(where: { !$0.value.isEmpty }) else { return nil }
        // Past the prefix, the rest is too long to check line by line, so a long block stays text.
        guard text.count <= detectionLimit else { return nil }
        return pairs
    }

    // MARK: - Paths

    /// Every line a path: absolute, under the home folder, or relative with a leading `./`.
    static func paths(_ text: String) -> [String]? {
        let lines = prefixLines(text).filter { !$0.isEmpty }
        guard lines.count >= 2 else { return nil }
        guard lines.allSatisfy({ line in
            (line.hasPrefix("/") || line.hasPrefix("~/") || line.hasPrefix("./") || line.hasPrefix("../"))
                && !line.contains("\t") && !line.contains(": ")
        }) else { return nil }
        let all = allLines(text).filter { !$0.isEmpty }
        return all.map(String.init)
    }

    // MARK: - Markdown

    /// Text with Markdown structure: headings, lists, fenced code, or rules, on at least two
    /// lines, and either a heading or fence or at least three list items. The app's own
    /// Markdown parser renders it.
    static func looksLikeMarkdown(_ text: String) -> Bool {
        guard text.count <= detectionLimit else { return false }
        var structural = 0
        var hasHeadingOrFence = false
        for line in allLines(text) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.range(of: #"^#{1,6} \S"#, options: .regularExpression) != nil || trimmed.hasPrefix("```") {
                structural += 1
                hasHeadingOrFence = true
            } else if trimmed.range(of: #"^([-*+]|\d{1,3}[.)]) \S"#, options: .regularExpression) != nil {
                structural += 1
            }
        }
        return structural >= 2 && (hasHeadingOrFence || structural >= 3)
    }
}

/// Terminal output made readable: color and cursor codes removed, carriage return progress
/// lines reduced to what a terminal would show last, and backspace overstrikes undone.
public enum TerminalText {
    public struct Cleaned: Equatable, Sendable {
        public var text: String
        public var removedEscapes: Bool
    }

    public static func clean(_ text: String) -> Cleaned {
        let hasEscape = text.utf8.contains(0x1B)
        let hasReturn = text.utf8.contains(0x0D)
        let hasBackspace = text.utf8.contains(0x08)
        guard hasEscape || hasReturn || hasBackspace else { return Cleaned(text: text, removedEscapes: false) }
        var out = String.UnicodeScalarView()
        var scalars = text.unicodeScalars[...]
        var removed = false
        while let scalar = scalars.popFirst() {
            if scalar == "\u{1B}" {
                removed = true
                guard let next = scalars.first else { break }
                if next == "[" {
                    // CSI: parameters and intermediates, then one final byte from @ to ~.
                    scalars.removeFirst()
                    while let byte = scalars.first, !(0x40...0x7E).contains(byte.value) { scalars.removeFirst() }
                    if !scalars.isEmpty { scalars.removeFirst() }
                } else if next == "]" || next == "P" || next == "_" || next == "^" {
                    // OSC and other strings, ended by BEL or ESC backslash.
                    scalars.removeFirst()
                    while let byte = scalars.popFirst() {
                        if byte == "\u{07}" { break }
                        if byte == "\u{1B}", scalars.first == "\\" { scalars.removeFirst(); break }
                    }
                } else {
                    scalars.removeFirst()
                }
                continue
            }
            if scalar == "\u{08}" {
                if !out.isEmpty, out.last != "\n" { out.removeLast() }
                continue
            }
            out.append(scalar)
        }
        var result = String(out)
        if hasReturn {
            result = result.replacingOccurrences(of: "\r\n", with: "\n")
            if result.contains("\r") {
                result = result.split(separator: "\n", omittingEmptySubsequences: false).map { line in
                    guard line.contains("\r") else { return String(line) }
                    let parts = line.split(separator: "\r", omittingEmptySubsequences: false)
                    return String(parts.last(where: { !$0.isEmpty }) ?? "")
                }.joined(separator: "\n")
            }
        }
        return Cleaned(text: result, removedEscapes: removed)
    }

    /// Control characters other than tab and newline as their visible symbols, such as ␀.
    public static func visibleControls(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.value < 0x20, scalar != "\n", scalar != "\t", let picture = Unicode.Scalar(0x2400 + scalar.value) {
                out.append(picture)
            } else if scalar.value == 0x7F {
                out.append("\u{2421}")
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }
}

extension Array where Element == Substring {
    func dropLastIfEmpty() -> [Substring] {
        if let last, last.isEmpty { return Array(dropLast()) }
        return self
    }
}
