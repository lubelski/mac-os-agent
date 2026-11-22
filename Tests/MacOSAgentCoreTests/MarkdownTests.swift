import Foundation
import Testing
@testable import MacOSAgentCore

@Suite struct MarkdownTests {
    private func plain(_ text: AttributedString) -> String { String(text.characters) }

    private func blocks(_ source: String, streaming: Bool = false) -> [MarkdownBlock] {
        MarkdownDocument.parse(source, streaming: streaming).blocks
    }

    /// A short description of each block, for comparing structure.
    private func shape(_ blocks: [MarkdownBlock]) -> [String] {
        blocks.map { block in
            switch block {
            case .paragraph(let text): "p:\(plain(text))"
            case .heading(let level, let text): "h\(level):\(plain(text))"
            case .codeBlock(let language, let code): "code(\(language ?? "")):\(code)"
            case .blockQuote(let inner): "quote[\(shape(inner).joined(separator: ","))]"
            case .list(let list):
                (list.isOrdered ? "ol" : "ul") + "[" + list.items.map { item in
                    let task = item.task.map { $0 == .done ? "x " : "o " } ?? ""
                    return "\(item.ordinal):\(task)\(shape(item.blocks).joined(separator: ","))"
                }.joined(separator: ";") + "]"
            case .table(let table): "table \(table.columnCount)x\(table.rows.count)"
            case .thematicBreak: "hr"
            }
        }
    }

    // MARK: Blocks

    @Test func paragraphsHeadingsAndRules() {
        #expect(shape(blocks("# Title\n\nFirst para.\n\n---\n\nSecond.")) == ["h1:Title", "p:First para.", "hr", "p:Second."])
    }

    @Test func singleLineBreaksAreKept() {
        #expect(shape(blocks("line one\nline two")) == ["p:line one\nline two"])
    }

    @Test func inlineStylesStayAsAttributes() throws {
        let paragraph = try #require(blocks("Some *em*, **strong**, `code`, ~~gone~~ and [a link](https://example.com).").first)
        guard case .paragraph(let text) = paragraph else { Issue.record("not a paragraph"); return }
        #expect(plain(text) == "Some em, strong, code, gone and a link.")
        let intents = text.runs.compactMap(\.inlinePresentationIntent)
        #expect(intents.contains(.emphasized))
        #expect(intents.contains(.stronglyEmphasized))
        #expect(intents.contains(.code))
        #expect(intents.contains(.strikethrough))
        #expect(text.runs.contains { $0.link == URL(string: "https://example.com") })
        #expect(text.runs.allSatisfy { $0.presentationIntent == nil })
    }

    @Test func bareAddressesBecomeLinks() throws {
        guard case .paragraph(let text) = try #require(blocks("See https://example.com/docs today").first) else { return }
        #expect(text.runs.contains { $0.link?.absoluteString == "https://example.com/docs" })
    }

    @Test func fencedCodeKeepsItsTextAndLanguage() {
        #expect(shape(blocks("```swift\nlet a = 1\n\n  let b = 2\n```")) == ["code(swift):let a = 1\n\n  let b = 2"])
        #expect(shape(blocks("~~~\nplain\n~~~")) == ["code():plain"])
    }

    @Test func codeKeepsItsLineBreaksUntouched() {
        // No hard-break spaces are added inside a fence.
        #expect(shape(blocks("```\na\nb\n```")) == ["code():a\nb"])
    }

    @Test func listsNestAndKeepTheirNumbers() {
        #expect(shape(blocks("- one\n- two\n  1. inner\n  2. more")) == ["ul[1:p:one;2:p:two,ol[1:p:inner;2:p:more]]"])
        #expect(shape(blocks("3. three\n4. four")) == ["ol[3:p:three;4:p:four]"])
    }

    @Test func taskListItemsAreRecognized() {
        #expect(shape(blocks("- [ ] open\n- [x] done\n- [X] also\n- plain")) == ["ul[1:o p:open;2:x p:done;3:x p:also;4:p:plain]"])
    }

    @Test func blockQuotesHoldBlocks() {
        #expect(shape(blocks("> quoted\n>\n> - item")) == ["quote[p:quoted,ul[1:p:item]]"])
    }

    @Test func tablesHaveAlignedColumnsAndEvenRows() throws {
        let source = "| Name | Size | Note |\n|:--|--:|:-:|\n| a | 1 |\n| b `c` | 22 | x |"
        guard case .table(let table) = try #require(blocks(source).first) else { Issue.record("not a table"); return }
        #expect(table.alignments == [.leading, .trailing, .center])
        #expect(table.header.map(plain) == ["Name", "Size", "Note"])
        #expect(table.rows.map { $0.map(plain) } == [["a", "1", ""], ["b c", "22", "x"]])
    }

    @Test func lineBreakTagsInCellsBecomeBreaks() throws {
        guard case .table(let table) = try #require(blocks("| a |\n|---|\n| one<br>two |").first) else { return }
        #expect(plain(table.rows[0][0]) == "one\ntwo")
    }

    @Test func longColumnsWrapAndShortOnesDoNot() {
        let long = AttributedString(String(repeating: "word ", count: 10))
        let table = MarkdownTable(alignments: [.leading, .leading], header: [AttributedString("A"), AttributedString("B")],
                                  rows: [[AttributedString("short"), long]])
        #expect(!table.wrapsColumn(0))
        #expect(table.wrapsColumn(1))
        #expect(!table.wrapsColumn(5))
    }

    @Test func tableRowsArePaddedToTheColumnCount() {
        let table = MarkdownTable(alignments: [.leading], header: [AttributedString("A")], rows: [[AttributedString("1"), AttributedString("2")]])
        #expect(table.columnCount == 2)
        #expect(table.header.count == 2)
        #expect(table.alignments == [.leading, .leading])
    }

    @Test func emptyInputHasNoBlocks() {
        #expect(blocks("").isEmpty)
        #expect(blocks("   \n\n").isEmpty)
    }

    // MARK: Plain text

    @Test func plainTextDropsMarkup() {
        let source = """
            # Title

            Some **bold** and a [link](https://example.com), and https://bare.example.com.

            - one
            - [x] two
              1. inner

            > quoted

            ```sh
            echo hi
            ```

            | A | B |
            |---|---|
            | 1 | 2 |

            ---
            """
        #expect(MarkdownDocument.parse(source).plainText == """
            Title

            Some bold and a link (https://example.com), and https://bare.example.com.

            - one
            - [x] two
                  1. inner

                quoted

            echo hi

            A\tB
            1\t2

            ---
            """)
    }

    // MARK: Streaming

    @Test func anOpenFenceStaysCodeAtEveryStep() {
        #expect(shape(blocks("Here:\n\n```py\nprint(1)", streaming: true)) == ["p:Here:", "code(py):print(1)"])
        #expect(shape(blocks("Here:\n\n```py\nprint(1)\n`", streaming: true)) == ["p:Here:", "code(py):print(1)"])
        #expect(shape(blocks("Here:\n\n```py\nprint(1)\n``", streaming: true)) == ["p:Here:", "code(py):print(1)"])
        #expect(shape(blocks("Here:\n\n```py\nprint(1)\n```", streaming: true)) == ["p:Here:", "code(py):print(1)"])
    }

    @Test func aFenceStartingToArriveIsHeldBack() {
        #expect(shape(blocks("Here:\n\n``", streaming: true)) == ["p:Here:"])
        #expect(shape(blocks("Here:\n\n```", streaming: true)) == ["p:Here:"])
    }

    @Test func aHalfArrivedTableIsATableAtEveryStep() {
        let steps = [
            "| Name | Size |",
            "| Name | Size |\n|--",
            "| Name | Size |\n|---|-",
            "| Name | Size |\n|---|---|",
            "| Name | Size |\n|---|---|\n| a",
            "| Name | Size |\n|---|---|\n| a | 1 |",
        ]
        for step in steps {
            guard case .table(let table) = blocks(step, streaming: true).first else {
                Issue.record("not a table: \(step)")
                continue
            }
            #expect(table.header.map(plain) == ["Name", "Size"])
        }
    }

    @Test func textThatStartsWithABarIsNotForcedIntoATable() {
        #expect(shape(blocks("| not a table\nreally not", streaming: true)) == ["p:| not a table\nreally not"])
    }

    @Test func openInlineMarkupIsClosed() {
        #expect(shape(blocks("This is **bol", streaming: true)) == ["p:This is bol"])
        #expect(shape(blocks("Run `ls -l", streaming: true)) == ["p:Run ls -l"])
        #expect(shape(blocks("Not ~~this", streaming: true)) == ["p:Not this"])
        #expect(shape(blocks("An *ital", streaming: true)) == ["p:An ital"])
        #expect(shape(blocks("Run `a ** b` then **x", streaming: true)) == ["p:Run a ** b then x"])
        #expect(shape(blocks("Start **", streaming: true)) == ["p:Start"])
    }

    @Test func streamingStepsKeepTheStyleTheyWillEndWith() throws {
        guard case .paragraph(let partial) = try #require(blocks("This is **bol", streaming: true).first) else { return }
        #expect(partial.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized })
    }

    @Test func unfinishedLinksShowTheirText() {
        #expect(shape(blocks("See [the docs](https://exa", streaming: true)) == ["p:See the docs"])
        #expect(shape(blocks("See [the do", streaming: true)) == ["p:See the do"])
        #expect(shape(blocks("- [ ] task", streaming: true)) == ["ul[1:o p:task]"])
    }

    @Test func listMarkersAreNotEmphasis() {
        #expect(shape(blocks("* one\n* two", streaming: true)) == ["ul[1:p:one;2:p:two]"])
    }

    @Test func aFinishedReplyParsesTheSameWhetherStreamingOrNot() {
        let source = "Done.\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n```sh\nls\n```\n\n- **bold** item"
        #expect(MarkdownDocument.parse(source, streaming: true) == MarkdownDocument.parse(source))
    }

    @Test func everyPrefixOfAReplyParses() {
        // No step of a streaming reply may fail or lose the text that has arrived.
        let source = "# Plan\n\nI'll **check** `disk` usage:\n\n| Folder | Size |\n|:--|--:|\n| Movies | 38 GB |\n\n```sh\ndu -sh ~/*\n```\n\n- [x] done\n- [ ] [link](https://example.com)"
        for end in source.indices {
            let document = MarkdownDocument.parse(String(source[..<end]), streaming: true)
            #expect(document.blocks.count <= 6)
        }
    }

    // MARK: Source preparation

    @Test func lineBreaksAreNotAddedToTablesOrCode() {
        #expect(MarkdownSource.preservingLineBreaks("a\nb") == "a  \nb")
        #expect(MarkdownSource.preservingLineBreaks("| a |\n|---|") == "| a |\n|---|")
        #expect(MarkdownSource.preservingLineBreaks("```\na\nb\n```") == "```\na\nb\n```")
        #expect(MarkdownSource.preservingLineBreaks("a\n\nb") == "a\n\nb")
    }
}
