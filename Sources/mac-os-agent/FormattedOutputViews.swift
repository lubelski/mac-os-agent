import MacOSAgentCore
import SwiftUI

/// The output in its detected shape. A lone block of text goes in the standard text view, with
/// find and line numbers. Every other shape draws lazily, so only the rows in view are built.
struct FormattedOutputView: View {
    let formatted: ToolOutputFormat.Formatted
    let wraps: Bool
    let lineNumbers: Bool

    var body: some View {
        if formatted.blocks.isEmpty {
            Text(formatted.shape == .empty ? "No output" : "Nothing to show")
                .font(Mark.rowFont)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
            Spacer()
        } else if formatted.blocks.count == 1, case .text(let text) = formatted.blocks[0] {
            OutputTextView(text: text, wraps: wraps, showsLineNumbers: lineNumbers)
        } else if formatted.blocks.count == 1, case .table(let table) = formatted.blocks[0] {
            // A table scrolls both ways on its own, with its header kept in view.
            TableOutput(table: table)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(formatted.blocks.enumerated()), id: \.offset) { _, block in
                        BlockView(block: block)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct BlockView: View {
    let block: ToolOutputFormat.Block

    var body: some View {
        switch block {
        case .text(let text):
            Text(verbatim: text)
                .font(Mark.rowFont)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .json(let node):
            JSONOutput(node: node)
        case .table(let table):
            ScrollView(.horizontal) { TableRows(table: table, layout: TableLayout(table)) }
                .scrollIndicators(.automatic)
        case .keyValues(let pairs):
            KeyValueOutput(pairs: pairs)
        case .diff(let lines):
            DiffOutput(lines: lines)
        case .paths(let paths):
            PathOutput(paths: paths)
        case .markdown(let text):
            MarkdownView(document: MarkdownCache.document(for: text, streaming: false))
                .font(.system(size: 12))
        }
    }
}

// MARK: - JSON

/// JSON indented in its own key order. Objects and arrays fold with the mark before them, and a
/// large document opens folded below its second level.
private struct JSONOutput: View {
    let node: JSONNode
    @State private var folded: Set<String>

    init(node: JSONNode) {
        self.node = node
        _folded = State(initialValue: node.size > ToolOutputFormat.foldedJSONSize ? node.containerPaths(atDepth: 2) : [])
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(node.lines(folded: folded)) { line in
                row(line)
            }
        }
        .font(Mark.rowFont)
    }

    private func row(_ line: JSONNode.Line) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Color.clear.frame(width: CGFloat(line.depth) * 14, height: 1)
            if case .open(let path, let count, let isFolded) = line.kind {
                Button {
                    if isFolded { folded.remove(path) } else { folded.insert(path) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(verbatim: isFolded ? "▸" : "▾")
                            .foregroundStyle(.tertiary)
                            .frame(width: Mark.rowColumn, alignment: .leading)
                        content(line)
                        if isFolded {
                            Text(verbatim: "  \(count) \(count == 1 ? "item" : "items")").foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(isFolded ? "Unfold" : "Fold")
            } else {
                Color.clear.frame(width: Mark.rowColumn, height: 1)
                content(line)
            }
            Spacer(minLength: 0)
        }
    }

    private func content(_ line: JSONNode.Line) -> Text {
        let key = line.key.map { Text(verbatim: "\($0): ").foregroundStyle(.tertiary) } ?? Text(verbatim: "")
        return Text("\(key)\(Text(verbatim: line.text).foregroundStyle(.secondary))")
    }
}

// MARK: - Tables

/// Column widths from the longest cell in each column, in characters of the row font, capped
/// so one long cell does not push the rest out of view. A capped cell shows its full text on hover.
struct TableLayout {
    static let characterWidth: CGFloat = 6.7
    static let maximumCharacters = 48
    var widths: [CGFloat]

    init(_ table: ToolOutputFormat.Table) {
        let columns = table.columnCount
        var longest = [Int](repeating: 1, count: columns)
        for row in [table.header] + table.rows.prefix(500) {
            for (index, cell) in row.enumerated() where index < columns {
                longest[index] = max(longest[index], min(cell.count, Self.maximumCharacters))
            }
        }
        widths = longest.map { CGFloat($0) * Self.characterWidth + 4 }
    }
}

private struct TableOutput: View {
    let table: ToolOutputFormat.Table

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            TableRows(table: table, layout: TableLayout(table))
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
        }
    }
}

private struct TableRows: View {
    let table: ToolOutputFormat.Table
    let layout: TableLayout

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: table.header.isEmpty ? [] : [.sectionHeaders]) {
            Section {
                ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                    cells(row, style: .secondary)
                        .padding(.vertical, 1)
                        .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.03))
                }
                if table.totalRows > table.rows.count {
                    Text(verbatim: "Showing the first \(table.rows.count) of \(table.totalRows) rows. The raw view has all of them.")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 6)
                }
            } header: {
                if !table.header.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        cells(table.header, style: .tertiary)
                            .padding(.vertical, 3)
                        Rectangle().fill(.tertiary).frame(height: 1).opacity(0.5)
                    }
                }
            }
        }
        .font(Mark.rowFont)
        .textSelection(.enabled)
    }

    private func cells(_ row: [String], style: HierarchicalShapeStyle) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            ForEach(Array(layout.widths.enumerated()), id: \.offset) { column, width in
                let cell = column < row.count ? row[column] : ""
                Text(verbatim: cell)
                    .foregroundStyle(style)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: width, alignment: .leading)
                    .help(cell.count > TableLayout.maximumCharacters ? cell : "")
            }
        }
    }
}

// MARK: - Keys and values, diffs, paths

private struct KeyValueOutput: View {
    let pairs: [ToolOutputFormat.KeyValue]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: pair.key)
                        .foregroundStyle(.tertiary)
                    Text(verbatim: pair.value)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, CGFloat(pair.depth) * 14)
                .padding(.top, pair.value.isEmpty ? 4 : 0)
            }
        }
        .font(Mark.rowFont)
        .textSelection(.enabled)
    }
}

/// A unified diff in the text levels only: added lines on a faint fill, removed lines dimmer.
private struct DiffOutput: View {
    let lines: [ToolOutputFormat.DiffLine]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line.text.isEmpty ? " " : line.text)
                    .foregroundStyle(style(line.kind))
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(fill(line.kind))
                    .padding(.top, line.kind == .file && line.text.hasPrefix("diff ") ? 8 : 0)
            }
        }
        .font(Mark.rowFont)
        .textSelection(.enabled)
    }

    private func style(_ kind: ToolOutputFormat.DiffLine.Kind) -> HierarchicalShapeStyle {
        switch kind {
        case .added, .context: .secondary
        case .file: .primary
        case .removed, .hunk, .other: .tertiary
        }
    }

    private func fill(_ kind: ToolOutputFormat.DiffLine.Kind) -> Color {
        switch kind {
        case .added: Color.primary.opacity(0.08)
        case .removed: Color.primary.opacity(0.03)
        default: .clear
        }
    }
}

/// Paths with the folder dim and the name in the secondary level.
private struct PathOutput: View {
    let paths: [String]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 1) {
            ForEach(Array(paths.enumerated()), id: \.offset) { _, path in
                let slash = path.dropLast().lastIndex(of: "/").map { path.index(after: $0) } ?? path.startIndex
                Text("\(Text(verbatim: String(path[..<slash])).foregroundStyle(.tertiary))\(Text(verbatim: String(path[slash...])).foregroundStyle(.secondary))")
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(path)
            }
        }
        .font(Mark.rowFont)
        .textSelection(.enabled)
    }
}
