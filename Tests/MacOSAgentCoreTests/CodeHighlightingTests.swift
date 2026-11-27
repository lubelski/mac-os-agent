import Foundation
import Testing
@testable import MacOSAgentCore

/// Each span as its text and kind, for reading in a test.
private func marked(_ text: String, _ spans: [CodeHighlighting.Span]) -> [(String, CodeHighlighting.Kind)] {
    spans.map { (String(text[$0.range]), $0.kind) }
}

private func pairs(_ text: String, _ spans: [CodeHighlighting.Span], _ kind: CodeHighlighting.Kind) -> [String] {
    marked(text, spans).filter { $0.1 == kind }.map(\.0)
}

@Suite struct CodeHighlightingTests {
    /// A real MCP tool's description, with prose, shell, and PowerShell, as Settings shows it.
    private var attachmentDescription: String {
        get throws {
            let url = URL(filePath: #filePath).deletingLastPathComponent()
                .appending(path: "Fixtures/tool-description-create-attachment.txt")
            return try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .newlines)
        }
    }

    @Test func aLongDescriptionHasItsShellAndPowerShellFoundAndItsProseLeftAlone() throws {
        let text = try attachmentDescription
        let lines = text.components(separatedBy: "\n")
        let kinds = CodeHighlighting.lineKinds(lines)
        let byLine = Dictionary(uniqueKeysWithValues: zip(lines, kinds).filter { !$0.0.isEmpty })

        #expect(byLine["Unix-like shells:"] == .heading)
        #expect(byLine["PowerShell:"] == .heading)
        #expect(byLine[#"file="/path/to/file""#] == .shell)
        #expect(byLine["$decodedSize = $decoded.Length"] == .shell)
        #expect(byLine["$size = $bytes.Length # optional"] == .shell)
        // Every line under each heading is code, up to the blank line.
        let unix = try #require(lines.firstIndex(of: "Unix-like shells:"))
        #expect(kinds[(unix + 1)...(unix + 6)].allSatisfy { $0 == .shell })
        #expect(kinds[unix + 7] == .blank)
        let powerShell = try #require(lines.firstIndex(of: "PowerShell:"))
        #expect(kinds[(powerShell + 1)...(powerShell + 9)].allSatisfy { $0 == .shell })

        // Prose stays prose, including the lines that end in a colon or name variables.
        for line in lines where !line.isEmpty && line != "Unix-like shells:" && line != "PowerShell:" {
            if lines.firstIndex(of: line)! < unix || lines.firstIndex(of: line)! > powerShell + 9 {
                #expect(byLine[line] == .prose, "\(line)")
            }
        }
    }

    @Test func theDescriptionsSpansColorTheCodeAndOnlyBackticksInProse() throws {
        let text = try attachmentDescription
        let spans = CodeHighlighting.freeText(text)
        #expect(pairs(text, spans, .inlineCode) == [
            "prepare_attachment_upload", "create_attachment_from_upload", "sha256", "size",
        ])
        #expect(pairs(text, spans, .heading) == ["Unix-like shells:", "PowerShell:"])
        let commands = pairs(text, spans, .command)
        #expect(commands.contains("base64") && commands.contains("tr") && commands.contains("awk"))
        #expect(commands.contains("Get-FileHash"))
        #expect(!commands.contains("Deprecated") && !commands.contains("Pass"))
        #expect(pairs(text, spans, .comment) == ["# optional; stat can also get file byte size", "# optional"])
        #expect(pairs(text, spans, .type).contains("[IO.File]"))
        #expect(pairs(text, spans, .option).contains("-Algorithm"))
        // Nothing in the prose before the code is colored but the backticked names.
        let firstCode = try #require(text.range(of: "Unix-like shells:")).lowerBound
        let prose = spans.filter { $0.range.lowerBound < firstCode }
        #expect(prose.allSatisfy { $0.kind == .inlineCode || $0.kind == .punctuation })
        // Spans never overlap and stay inside the text, so the text itself is never changed.
        let sorted = spans.sorted { $0.range.lowerBound < $1.range.lowerBound }
        for (a, b) in zip(sorted, sorted.dropFirst()) { #expect(a.range.upperBound <= b.range.lowerBound) }
    }

    @Test func aShellLineIsReadPartByPart() {
        let line = #"sha256=$(shasum -a 256 "$file" | awk '{print $1}') # check"#
        #expect(marked(line, CodeHighlighting.shell(line)).map { "\($0.0)|\($0.1)" } == [
            "sha256|variable", "=|punctuation", "$(|punctuation", "shasum|command", "-a|option", "256|number",
            "\"|string", "$file|variable", "\"|string", "||punctuation", "awk|command", "'{print $1}'|string",
            ")|punctuation", "# check|comment",
        ])
    }

    @Test func aPowerShellLineIsReadPartByPart() {
        let line = "$sha256 = (Get-FileHash -Algorithm SHA256 -Path $file).Hash.ToLower()"
        let spans = marked(line, CodeHighlighting.shell(line))
        #expect(spans.first { $0.0 == "$sha256" }?.1 == .variable)
        #expect(spans.first { $0.0 == "Get-FileHash" }?.1 == .command)
        #expect(spans.filter { $0.1 == .option }.map(\.0) == ["-Algorithm", "-Path"])
        #expect(!spans.contains { $0.0 == "SHA256" })
    }

    @Test func proseThatOnlyMentionsCodeStaysProse() {
        let lines = [
            "Use this tool to list files: it takes a path.",
            "Returns the matching items, or an error when none match.",
            "Note:",
            "The result is cut at 16,000 characters.",
            "Set mode=fast for quick answers.",
        ]
        #expect(CodeHighlighting.lineKinds(lines).allSatisfy { $0 == .prose })
        // A short line ending in a colon is a heading only above code.
        #expect(CodeHighlighting.lineKinds(["Example:", "Call it with a city."]) == [.prose, .prose])
    }

    @Test func aLoneCommandLineInProseIsCodeOnlyWhenItStartsLikeOne() {
        let kinds = CodeHighlighting.lineKinds([
            "Read the file first.",
            "export TOKEN=abc",
            "Then the result $(is) here.",
        ])
        #expect(kinds == [.prose, .shell, .prose])
    }

    @Test func fencesFollowTheirLanguage() {
        let lines = ["Run:", "```bash", "echo hi", "```", "", "```json", #"{"a": 1}"#, "```", "", "```python", "print('x')", "```"]
        #expect(CodeHighlighting.lineKinds(lines) == [
            .prose, .plainCode, .shell, .plainCode, .blank, .plainCode, .json, .plainCode, .blank, .plainCode, .plainCode, .plainCode,
        ])
        let text = lines.joined(separator: "\n")
        let spans = CodeHighlighting.freeText(text)
        #expect(pairs(text, spans, .key) == [#""a""#])
        // Python is not highlighted: a wrong color reads worse than none.
        #expect(!marked(text, spans).contains { $0.0.contains("print") })
    }

    @Test func anUnpairedBacktickStaysPlain() {
        let text = "Pass `a` and ` alone."
        #expect(pairs(text, CodeHighlighting.freeText(text), .inlineCode) == ["a"])
    }

    @Test func jsonHasKeysStringsNumbersAndLiterals() {
        let text = JSONValue.object([
            "type": "object", "required": ["city"], "additionalProperties": false,
            "properties": ["days": ["type": "integer", "default": 3, "description": "Say \"hi\": 1"]],
        ]).prettyEncodedString()
        let spans = CodeHighlighting.json(text)
        #expect(pairs(text, spans, .key) == [
            #""additionalProperties""#, #""properties""#, #""days""#, #""default""#, #""description""#, #""type""#,
            #""required""#, #""type""#,
        ])
        #expect(pairs(text, spans, .string) == [#""Say \"hi\": 1""#, #""integer""#, #""city""#, #""object""#])
        #expect(pairs(text, spans, .number) == ["3"])
        #expect(pairs(text, spans, .literal) == ["false"])
        #expect(Set(pairs(text, spans, .punctuation)) == ["{", "}", "[", "]", ":", ","])
    }
}

@Suite struct ToolParameterDisplayTests {
    @Test func parametersReadDefaultsAndItemValuesAndListRequiredFirst() {
        let schema: JSONValue = [
            "type": "object",
            "properties": [
                "city": ["type": "string"],
                "days": ["type": "integer", "default": 3],
                "kinds": ["type": "array", "items": ["type": "string", "enum": ["storm", "heat"]]],
                "units": ["type": "string", "default": "metric"],
            ],
            "required": ["units", "city"],
        ]
        let parameters = ToolParameter.list(from: schema)
        #expect(parameters.first { $0.name == "days" }?.defaultValue == "3")
        #expect(parameters.first { $0.name == "units" }?.defaultValue == "metric")
        #expect(parameters.first { $0.name == "kinds" }?.allowedValues == ["storm", "heat"])
        #expect(parameters.first { $0.name == "city" }?.defaultValue == nil)
        #expect(ToolParameter.inCallOrder(parameters).map(\.name) == ["city", "units", "days", "kinds"])
    }

    @Test func aDescriptionGoesOnOnlyPastItsFirstSentence() {
        struct Stub: AgentTool {
            var text: String
            var definition: ToolDefinition { ToolDefinition(name: "stub", description: text, parameters: ["type": "object"]) }
            func summary(arguments: JSONValue) -> String { "" }
            func run(arguments: JSONValue, context: ToolRunContext) async -> String { "" }
        }
        #expect(!ToolSummary(Stub(text: "Lists the apps.")).descriptionGoesOn)
        #expect(ToolSummary(Stub(text: "Lists the apps. Then more.")).descriptionGoesOn)
    }
}
