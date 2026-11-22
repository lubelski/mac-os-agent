import Foundation

/// A reply's Markdown as a tree of blocks for the panel to draw.
///
/// Parsing is Foundation's own: `AttributedString(markdown:)` with full syntax, which follows
/// GitHub Flavored Markdown, including tables, strikethrough, and autolinks. It marks each run
/// of text with the blocks it sits in, and `parse` turns those marks into this tree. Inline
/// styling (emphasis, strong, code, strikethrough, links) stays on the text as attributes that
/// SwiftUI's `Text` draws as they are. Task list items, which Foundation leaves as text, are
/// recognized here.
public struct MarkdownDocument: Equatable, Sendable {
    public var blocks: [MarkdownBlock]

    public init(blocks: [MarkdownBlock]) {
        self.blocks = blocks
    }

    /// Parses a reply.
    /// - Parameter streaming: True while the reply is still arriving. Its unfinished end is
    ///   completed first, so each step renders the way the finished reply will (see
    ///   `MarkdownSource.completingPartial`).
    public static func parse(_ text: String, streaming: Bool = false) -> MarkdownDocument {
        var source = MarkdownSource.preservingLineBreaks(text)
        if streaming { source = MarkdownSource.completingPartial(source) }
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard let attributed = try? AttributedString(markdown: source, options: options) else {
            return MarkdownDocument(blocks: [.paragraph(AttributedString(text))])
        }
        return MarkdownDocument(blocks: TreeBuilder(attributed).blocks())
    }

    /// The text with the Markdown taken out, for "Copy as plain text": paragraphs apart by a
    /// blank line, list items with `-` or their number, tables as tab-separated rows, which
    /// paste into a spreadsheet as cells, and links as their text followed by the address.
    public var plainText: String {
        MarkdownPlainText.blocks(blocks, indent: "")
    }
}

public indirect enum MarkdownBlock: Equatable, Sendable {
    case paragraph(AttributedString)
    case heading(level: Int, AttributedString)
    /// The code exactly as written, without its fences or its last line break.
    case codeBlock(language: String?, code: String)
    case blockQuote([MarkdownBlock])
    case list(MarkdownList)
    case table(MarkdownTable)
    case thematicBreak
}

public struct MarkdownList: Equatable, Sendable {
    public var isOrdered: Bool
    public var items: [MarkdownListItem]

    public init(isOrdered: Bool, items: [MarkdownListItem]) {
        self.isOrdered = isOrdered
        self.items = items
    }
}

public struct MarkdownListItem: Equatable, Sendable {
    public enum Task: Equatable, Sendable {
        case open
        case done
    }

    /// The item's number in an ordered list, as written in the source for the first one.
    public var ordinal: Int
    /// Set for a task list item, `- [ ]` or `- [x]`.
    public var task: Task?
    public var blocks: [MarkdownBlock]

    public init(ordinal: Int, task: Task? = nil, blocks: [MarkdownBlock]) {
        self.ordinal = ordinal
        self.task = task
        self.blocks = blocks
    }
}

public struct MarkdownTable: Equatable, Sendable {
    public enum Alignment: Equatable, Sendable {
        case leading
        case center
        case trailing
    }

    public var alignments: [Alignment]
    public var header: [AttributedString]
    /// Each row has exactly as many cells as there are columns. Missing cells are empty.
    public var rows: [[AttributedString]]

    public init(alignments: [Alignment], header: [AttributedString], rows: [[AttributedString]]) {
        let columns = max(alignments.count, header.count, rows.map(\.count).max() ?? 0)
        self.alignments = alignments + Array(repeating: .leading, count: columns - alignments.count)
        self.header = Self.padded(header, to: columns)
        self.rows = rows.map { Self.padded($0, to: columns) }
    }

    public var columnCount: Int { alignments.count }

    /// A column this long, in characters, wraps inside a width limit instead of growing to fit
    /// its longest cell. Shorter columns keep each cell on one line.
    public static let wrappingThreshold = 32

    /// Whether a column's cells wrap. A table of short columns lays out at its natural width
    /// and scrolls sideways in a narrow panel. A long column wraps, so prose in a cell stays
    /// readable without a long sideways scroll.
    public func wrapsColumn(_ column: Int) -> Bool {
        ([header] + rows).contains { row in
            column < row.count && row[column].characters.count > Self.wrappingThreshold
        }
    }

    private static func padded(_ cells: [AttributedString], to count: Int) -> [AttributedString] {
        cells + Array(repeating: AttributedString(), count: max(0, count - cells.count))
    }
}

// MARK: - Building the tree

/// Turns Foundation's runs, each marked with the stack of blocks it sits in, into blocks.
private struct TreeBuilder {
    /// One block while it is being built: its kind, and its children in order.
    final class Node {
        let kind: PresentationIntent.Kind
        let identity: Int
        var children: [Child] = []

        init(kind: PresentationIntent.Kind, identity: Int) {
            self.kind = kind
            self.identity = identity
        }
    }

    enum Child {
        case node(Node)
        case text(AttributedString)
    }

    let attributed: AttributedString
    private let root = Node(kind: .paragraph, identity: -1)

    init(_ attributed: AttributedString) {
        self.attributed = attributed
    }

    func blocks() -> [MarkdownBlock] {
        for run in attributed.runs {
            var text = AttributedString(attributed[run.range])
            text.presentationIntent = nil
            text = Self.replacingLineBreakTags(text)
            // Outermost block first.
            let path = (run.presentationIntent?.components ?? []).reversed()
            var parent = root
            for component in path {
                if case .node(let last) = parent.children.last, last.identity == component.identity {
                    parent = last
                } else {
                    let node = Node(kind: component.kind, identity: component.identity)
                    parent.children.append(.node(node))
                    parent = node
                }
            }
            if case .text(let existing) = parent.children.last {
                parent.children[parent.children.count - 1] = .text(existing + text)
            } else {
                parent.children.append(.text(text))
            }
        }
        return Self.blocks(of: root)
    }

    /// Inline `<br>` tags, which models often put in table cells, become line breaks.
    static func replacingLineBreakTags(_ text: AttributedString) -> AttributedString {
        let plain = String(text.characters).lowercased().replacingOccurrences(of: " ", with: "")
        guard plain == "<br>" || plain == "<br/>" else { return text }
        return AttributedString("\n")
    }

    static func blocks(of node: Node) -> [MarkdownBlock] {
        node.children.compactMap { child in
            switch child {
            case .text(let text):
                // Loose text directly in a container reads as a paragraph.
                return text.characters.isEmpty ? nil : .paragraph(text)
            case .node(let node):
                return block(from: node)
            }
        }
    }

    static func text(of node: Node) -> AttributedString {
        node.children.reduce(into: AttributedString()) { result, child in
            switch child {
            case .text(let text): result += text
            case .node(let inner): result += text(of: inner)
            }
        }
    }

    static func block(from node: Node) -> MarkdownBlock? {
        switch node.kind {
        case .paragraph:
            return .paragraph(text(of: node))
        case .header(let level):
            return .heading(level: level, text(of: node))
        case .codeBlock(let language):
            var code = String(text(of: node).characters)
            if code.hasSuffix("\n") { code.removeLast() }
            let language = language?.trimmingCharacters(in: .whitespaces)
            return .codeBlock(language: language?.isEmpty == false ? language : nil, code: code)
        case .blockQuote:
            return .blockQuote(blocks(of: node))
        case .orderedList, .unorderedList:
            let items = node.children.compactMap { child -> MarkdownListItem? in
                guard case .node(let item) = child, case .listItem(let ordinal) = item.kind else { return nil }
                return listItem(blocks(of: item), ordinal: ordinal)
            }
            if case .orderedList = node.kind {
                return .list(MarkdownList(isOrdered: true, items: items))
            }
            return .list(MarkdownList(isOrdered: false, items: items))
        case .listItem(let ordinal):
            return .list(MarkdownList(isOrdered: false, items: [listItem(blocks(of: node), ordinal: ordinal)]))
        case .table(let columns):
            var header: [AttributedString] = []
            var rows: [[AttributedString]] = []
            for child in node.children {
                guard case .node(let row) = child else { continue }
                let cells = row.children.compactMap { cell -> AttributedString? in
                    guard case .node(let cell) = cell else { return nil }
                    return text(of: cell)
                }
                if case .tableHeaderRow = row.kind { header = cells } else { rows.append(cells) }
            }
            let alignments = columns.map { column -> MarkdownTable.Alignment in
                switch column.alignment {
                case .center: .center
                case .right: .trailing
                default: .leading
                }
            }
            return .table(MarkdownTable(alignments: alignments, header: header, rows: rows))
        case .thematicBreak:
            return .thematicBreak
        default:
            // A table row or cell outside a table, or a kind added to Foundation later.
            let inner = text(of: node)
            return inner.characters.isEmpty ? nil : .paragraph(inner)
        }
    }

    /// A list item whose first paragraph starts with `[ ]` or `[x]` is a task.
    static func listItem(_ blocks: [MarkdownBlock], ordinal: Int) -> MarkdownListItem {
        var blocks = blocks
        guard case .paragraph(var text) = blocks.first else {
            return MarkdownListItem(ordinal: ordinal, blocks: blocks)
        }
        let characters = String(text.characters.prefix(4))
        let task: MarkdownListItem.Task?
        switch characters {
        case "[ ] ": task = .open
        case "[x] ", "[X] ": task = .done
        default:
            let whole = String(text.characters)
            if whole == "[ ]" { task = .open } else if whole == "[x]" || whole == "[X]" { task = .done } else { task = nil }
        }
        guard let task else { return MarkdownListItem(ordinal: ordinal, blocks: blocks) }
        let cut = text.characters.index(text.startIndex, offsetBy: min(4, text.characters.count))
        text.removeSubrange(text.startIndex..<cut)
        blocks[0] = .paragraph(text)
        if text.characters.isEmpty { blocks.removeFirst() }
        return MarkdownListItem(ordinal: ordinal, task: task, blocks: blocks)
    }
}

// MARK: - Source preparation

/// Changes made to a reply's source before it is parsed.
public enum MarkdownSource {
    /// Keeps the model's single line breaks as line breaks, as the panel always has, instead of
    /// joining the lines of a paragraph with spaces. Code blocks are left exactly as written.
    public static func preservingLineBreaks(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var fence: Fence?
        for index in lines.indices {
            let line = lines[index]
            if let open = fence {
                if open.isClosed(by: line) { fence = nil }
                continue
            }
            if let opening = Fence(opening: line) {
                fence = opening
                continue
            }
            let next = index + 1 < lines.count ? lines[index + 1] : ""
            let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
            let nextIsBlank = next.trimmingCharacters(in: .whitespaces).isEmpty
            // A line ending in two spaces breaks before the next one. Table rows and indented
            // code are left alone.
            if !isBlank, !nextIsBlank, !line.hasSuffix("  "), !line.hasSuffix("\\"),
               !isTableLine(line), !isTableLine(next), !line.hasPrefix("    "), !line.hasPrefix("\t")
            {
                lines[index] = line + "  "
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Completes the unfinished end of a reply that is still arriving, so the panel shows each
    /// step the way the finished reply will look and the text does not change shape when the
    /// rest arrives.
    ///
    /// - An open code fence stays open, and its text shows as code. A line that may become the
    ///   closing fence is held back until it is one.
    /// - A line of one or two backticks or tildes that may become an opening fence is held back.
    /// - A table's header row is a table at once: the delimiter row under it is filled in or
    ///   completed until the real one arrives.
    /// - An open code span, `**`, `~~`, or `*` in the last block is closed.
    /// - A link whose address is still arriving shows as its text, and an open `[` is held back.
    public static func completingPartial(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var fence: Fence?
        var blockStart = 0
        for (index, line) in lines.enumerated() {
            if let open = fence {
                if open.isClosed(by: line) { fence = nil; blockStart = index + 1 }
            } else if let opening = Fence(opening: line) {
                fence = opening
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                blockStart = index + 1
            }
        }

        if let open = fence {
            // The last line may be the start of the closing fence.
            if let last = lines.last, lines.count > 1, open.mayBecomeClosing(last) { lines.removeLast() }
            return lines.joined(separator: "\n")
        }
        guard let last = lines.last else { return text }
        if last.trimmingCharacters(in: .whitespaces).range(of: #"^(`{1,2}|~{1,2})$"#, options: .regularExpression) != nil {
            lines.removeLast()
            return lines.joined(separator: "\n")
        }

        let block = Array(lines[min(blockStart, lines.count)...])
        if let first = block.first, isTableLine(first) {
            lines = Array(lines[..<blockStart]) + completingTable(block)
            return lines.joined(separator: "\n")
        }
        guard blockStart < lines.count else { return text }
        let head = lines[..<blockStart].joined(separator: "\n")
        var tail = lines[blockStart...].joined(separator: "\n")
        tail = completingInline(tail)
        return blockStart == 0 ? tail : head + "\n" + tail
    }

    /// A line that starts with a bar and has another one after it.
    static func isTableLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("|") && trimmed.dropFirst().contains("|")
    }

    private static let delimiterCharacters = CharacterSet(charactersIn: "|:- ")

    static func cells(of line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|")
    }

    /// A table block with a complete delimiter row under its header.
    static func completingTable(_ block: [String]) -> [String] {
        guard let header = block.first else { return block }
        let columns = cells(of: header).count
        guard columns > 0 else { return block }
        var block = block
        if block.count == 1 {
            block.append("|" + Array(repeating: "---", count: columns).joined(separator: "|") + "|")
            return block
        }
        let second = block[1]
        guard second.unicodeScalars.allSatisfy(delimiterCharacters.contains) else {
            // Not a table after all: it is text that starts with a bar.
            return block
        }
        var delimiters = cells(of: second).map { $0.trimmingCharacters(in: .whitespaces) }
        delimiters = delimiters.map { $0.contains("-") ? $0 : "---" }
        if delimiters.count < columns {
            delimiters += Array(repeating: "---", count: columns - delimiters.count)
        }
        block[1] = "|" + delimiters.joined(separator: "|") + "|"
        return block
    }

    /// Closes what is open in the last block of text.
    static func completingInline(_ text: String) -> String {
        var text = text
        // An unfinished link shows as its text: `[label](partial` becomes `label`.
        if let range = text.range(of: #"\[([^\[\]]*)\]\([^()\s]*$"#, options: .regularExpression) {
            let match = String(text[range])
            let label = match.dropFirst().prefix { $0 != "]" }
            text.replaceSubrange(range, with: label)
        } else if let range = text.range(of: #"\[[^\[\]]*$"#, options: .regularExpression),
                  !String(text[range]).hasPrefix("[ ]"), !String(text[range]).lowercased().hasPrefix("[x]")
        {
            // An open `[` that may become a link: hold the bracket back.
            text.remove(at: range.lowerBound)
        }

        // Code spans first, since nothing inside one is markup.
        let backticks = text.filter { $0 == "`" }.count
        if backticks % 2 == 1 {
            return text + "`"
        }
        let outsideCode = text.replacingOccurrences(of: #"`[^`]*`"#, with: "", options: .regularExpression)
        var closers = ""
        if outsideCode.components(separatedBy: "~~").count % 2 == 0 { closers = "~~" + closers }
        let strong = outsideCode.components(separatedBy: "**").count - 1
        if strong % 2 == 1 { closers = "**" + closers }
        // Single asterisks, leaving out `**` and list markers at the start of a line.
        let single = outsideCode
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: #"(?m)^\s*\*\s"#, with: "", options: .regularExpression)
            .filter { $0 == "*" }.count
        if single % 2 == 1 { closers = "*" + closers }
        guard !closers.isEmpty else { return text }
        // A closer after trailing spaces would not close, so it goes against the last word.
        var trimmed = text
        while trimmed.last == " " { trimmed.removeLast() }
        // An opener with nothing after it yet is held back instead of closed.
        for opener in ["**", "~~", "*"] where trimmed.hasSuffix(opener) {
            if closers.hasPrefix(opener) {
                trimmed.removeLast(opener.count)
                closers.removeFirst(opener.count)
            }
        }
        return trimmed + closers
    }
}

/// An open code fence: three or more backticks or tildes.
struct Fence {
    let character: Character
    let length: Int

    init?(opening line: String) {
        let trimmed = line.drop { $0 == " " }
        guard line.count - trimmed.count <= 3, let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let run = trimmed.prefix { $0 == first }
        guard run.count >= 3 else { return nil }
        // A backtick fence's info string cannot hold a backtick.
        if first == "`", trimmed.dropFirst(run.count).contains("`") { return nil }
        character = first
        length = run.count
    }

    func isClosed(by line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= length && trimmed.allSatisfy { $0 == character }
    }

    /// A line of the fence character too short to close it yet.
    func mayBecomeClosing(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.count < length && trimmed.allSatisfy { $0 == character }
    }
}

// MARK: - Plain text

enum MarkdownPlainText {
    static func blocks(_ blocks: [MarkdownBlock], indent: String, separator: String = "\n\n") -> String {
        blocks.map { block(for: $0, indent: indent) }.joined(separator: separator)
    }

    static func block(for block: MarkdownBlock, indent: String) -> String {
        switch block {
        case .paragraph(let text), .heading(_, let text):
            return indented(inline(text), indent)
        case .codeBlock(_, let code):
            return indented(code, indent)
        case .blockQuote(let inner):
            return blocks(inner, indent: indent + "    ")
        case .list(let list):
            return list.items.enumerated().map { index, item in
                var marker = list.isOrdered ? "\(item.ordinal)." : "-"
                if let task = item.task { marker += task == .done ? " [x]" : " [ ]" }
                // A list item's blocks sit on consecutive lines, so the list stays compact.
                let body = blocks(item.blocks, indent: "", separator: "\n")
                let lines = body.components(separatedBy: "\n")
                let rest = lines.dropFirst().map { $0.isEmpty ? $0 : indent + String(repeating: " ", count: marker.count + 1) + $0 }
                return ([indent + marker + (lines.first.map { $0.isEmpty ? "" : " " + $0 } ?? "")] + rest).joined(separator: "\n")
            }.joined(separator: "\n")
        case .table(let table):
            return ([table.header] + table.rows)
                .map { row in indent + row.map { inline($0).replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t") }
                .joined(separator: "\n")
        case .thematicBreak:
            return indent + "---"
        }
    }

    /// Inline text with its styling dropped and each link's address after its text.
    static func inline(_ text: AttributedString) -> String {
        var result = ""
        for run in text.runs {
            let piece = String(text[run.range].characters)
            result += piece
            if let link = run.link, link.absoluteString != piece, link.absoluteString != "mailto:" + piece {
                result += " (\(link.absoluteString))"
            }
        }
        return result
    }

    static func indented(_ text: String, _ indent: String) -> String {
        guard !indent.isEmpty else { return text }
        return text.components(separatedBy: "\n").map { $0.isEmpty ? $0 : indent + $0 }.joined(separator: "\n")
    }
}
