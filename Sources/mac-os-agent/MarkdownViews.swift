import MacOSAgentCore
import SwiftUI

/// A reply's Markdown, drawn with native text: each block is a selectable `Text`, inline
/// styles and links come from the attributed text, and links open in the default browser.
struct MarkdownView: View {
    let document: MarkdownDocument

    var body: some View {
        MarkdownBlocks(blocks: document.blocks, depth: 0)
    }
}

/// Parsed replies, so a finished reply is parsed once and not again each time its row is built.
@MainActor
enum MarkdownCache {
    private final class Entry {
        let document: MarkdownDocument
        init(_ document: MarkdownDocument) { self.document = document }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 300
        return cache
    }()

    /// The document for a reply. A reply still streaming is parsed fresh each time, since its
    /// text changes with every piece that arrives.
    static func document(for text: String, streaming: Bool) -> MarkdownDocument {
        if streaming { return MarkdownDocument.parse(text, streaming: true) }
        let key = text as NSString
        if let entry = cache.object(forKey: key) { return entry.document }
        let document = MarkdownDocument.parse(text)
        cache.setObject(Entry(document), forKey: key)
        return document
    }
}

private struct MarkdownBlocks: View {
    let blocks: [MarkdownBlock]
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, depth: depth)
            }
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let depth: Int

    var body: some View {
        switch block {
        case .paragraph(let text):
            InlineText(text: text)
        case .heading(let level, let text):
            InlineText(text: text)
                .font(Self.headingFont(level))
                .padding(.top, level <= 2 ? 2 : 0)
                .accessibilityAddTraits(.isHeader)
        case .codeBlock(let language, let code):
            CodeBlockView(language: language, code: code)
        case .blockQuote(let inner):
            // An open bracket's rule down the left, as in Pi's quotes, with the text a level down.
            MarkdownBlocks(blocks: inner, depth: depth)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(.tertiary).frame(width: 1).padding(.leading, 3)
                }
        case .list(let list):
            ListView(list: list, depth: depth)
        case .table(let table):
            TableView(table: table)
        case .thematicBreak:
            Rectangle()
                .fill(.tertiary)
                .frame(height: 1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .accessibilityHidden(true)
        }
    }

    /// Headings stay close to the text size, since the panel is small.
    static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .system(size: 16, weight: .bold)
        case 2: .system(size: 15, weight: .semibold)
        default: .body.weight(.semibold)
        }
    }
}

private struct InlineText: View {
    let text: AttributedString

    var body: some View {
        Text(text)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ListView: View {
    let list: MarkdownList
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    marker(for: item)
                    MarkdownBlocks(blocks: item.blocks, depth: depth + 1)
                }
            }
        }
    }

    /// A bullet, a number, or a task's box, in the secondary level. Task boxes are the text
    /// marks `[ ]` and `[x]`, in the scheme of the tool rows.
    @ViewBuilder private func marker(for item: MarkdownListItem) -> some View {
        Group {
            if let task = item.task {
                Text(verbatim: task == .done ? "[x]" : "[ ]")
                    .font(Mark.rowFont)
                    .foregroundStyle(task == .done ? HierarchicalShapeStyle.secondary : .tertiary)
                    .accessibilityLabel(task == .done ? "Done" : "Not done")
            } else if list.isOrdered {
                Text(verbatim: "\(item.ordinal).")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Text(verbatim: depth.isMultiple(of: 2) ? "•" : "◦")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .frame(minWidth: list.isOrdered ? 18 : 10, alignment: .trailing)
    }
}

/// A fenced code block in an open bracket, its language as the label, with a copy control
/// after the label that shows under the pointer. The code keeps its lines and scrolls
/// sideways when it is wider than the message.
private struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var hovering = false

    var body: some View {
        CodeBracket(label: language, font: .system(size: 11.5, design: .monospaced), fillsWidth: false) {
            ViewThatFits(in: .horizontal) {
                codeText
                ScrollView(.horizontal) { codeText.padding(.bottom, 4) }
                    .scrollIndicators(.automatic)
            }
        } accessory: {
            CopyControl(help: "Copy the code") { code }
                .revealed(when: hovering)
        }
        .onHover { hovering = $0 }
    }

    private var codeText: some View {
        Text(verbatim: code)
            .textSelection(.enabled)
            .fixedSize()
    }
}

/// A table with its columns aligned as the source says, its header in the semibold weight it
/// always has, and a rule under the header. Short columns keep each cell on one line, long
/// ones wrap at a fixed width, and a table wider than the message scrolls sideways.
private struct TableView: View {
    let table: MarkdownTable
    static let wrappingWidth: CGFloat = 240

    var body: some View {
        ViewThatFits(in: .horizontal) {
            grid
            ScrollView(.horizontal) { grid.padding(.bottom, 6) }
                .scrollIndicators(.automatic)
        }
    }

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
            GridRow {
                ForEach(0..<table.columnCount, id: \.self) { column in
                    cell(table.header[column], column: column)
                        .fontWeight(.semibold)
                        .gridColumnAlignment(Self.alignment(table.alignments[column]))
                }
            }
            Rectangle()
                .fill(.tertiary)
                .frame(height: 1)
                .gridCellUnsizedAxes(.horizontal)
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(0..<table.columnCount, id: \.self) { column in
                        cell(row[column], column: column)
                    }
                }
            }
        }
        .fixedSize()
    }

    @ViewBuilder private func cell(_ text: AttributedString, column: Int) -> some View {
        if table.wrapsColumn(column) {
            // A fixed width, so the cell wraps there even when the grid takes its ideal size.
            Text(text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: Self.wrappingWidth, alignment: Self.frameAlignment(table.alignments[column]))
        } else {
            Text(text)
                .textSelection(.enabled)
                .fixedSize()
        }
    }

    static func alignment(_ alignment: MarkdownTable.Alignment) -> HorizontalAlignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    static func frameAlignment(_ alignment: MarkdownTable.Alignment) -> Alignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}
