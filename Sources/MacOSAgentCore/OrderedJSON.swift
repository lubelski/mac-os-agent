import Foundation

/// JSON parsed for reading, keeping the order of keys and the exact text of every number and
/// string, so pretty printing never changes a value. Strict: anything that is not valid JSON,
/// such as a trailing comma, single quotes, or a comment, fails to parse instead of guessing.
public indirect enum JSONNode: Equatable, Sendable {
    /// A string, number, true, false, or null, as its exact source text.
    case scalar(String)
    case object([(key: String, value: JSONNode)])
    case array([JSONNode])

    public static func == (lhs: JSONNode, rhs: JSONNode) -> Bool {
        switch (lhs, rhs) {
        case (.scalar(let a), .scalar(let b)): a == b
        case (.array(let a), .array(let b)): a == b
        case (.object(let a), .object(let b)): a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: false
        }
    }

    /// The deepest nesting accepted, so hostile input cannot exhaust the stack.
    public static let maximumDepth = 200

    /// Parses one JSON value that fills the whole text, apart from whitespace around it.
    public static func parse(_ text: String) -> JSONNode? {
        var parser = Parser(Array(text.utf8))
        guard let node = parser.value(depth: 0) else { return nil }
        parser.skipWhitespace()
        return parser.isAtEnd ? node : nil
    }

    /// Indented with two spaces, keys in their original order.
    public func prettyText() -> String {
        var out = ""
        write(to: &out, indent: 0)
        return out
    }

    private func write(to out: inout String, indent: Int) {
        switch self {
        case .scalar(let text):
            out += text
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "[\n"
            for (index, item) in items.enumerated() {
                out += String(repeating: "  ", count: indent + 1)
                item.write(to: &out, indent: indent + 1)
                out += index == items.count - 1 ? "\n" : ",\n"
            }
            out += String(repeating: "  ", count: indent) + "]"
        case .object(let members):
            if members.isEmpty { out += "{}"; return }
            out += "{\n"
            for (index, member) in members.enumerated() {
                out += String(repeating: "  ", count: indent + 1) + member.key + ": "
                member.value.write(to: &out, indent: indent + 1)
                out += index == members.count - 1 ? "\n" : ",\n"
            }
            out += String(repeating: "  ", count: indent) + "}"
        }
    }

    /// The text of a string scalar without its quotes and escapes, or nil for anything else.
    public var stringValue: String? {
        guard case .scalar(let text) = self, text.hasPrefix("\"") else { return nil }
        return (try? JSONDecoder().decode(String.self, from: Data(text.utf8))) ?? String(text.dropFirst().dropLast())
    }

    /// How many values are inside, counting this one, for keeping very large documents in check.
    public var size: Int {
        switch self {
        case .scalar: 1
        case .array(let items): 1 + items.reduce(0) { $0 + $1.size }
        case .object(let members): 1 + members.reduce(0) { $0 + $1.value.size }
        }
    }

    // MARK: - Lines for a collapsible view

    /// One line of the pretty printed document, for a view that can fold objects and arrays.
    public struct Line: Equatable, Sendable, Identifiable {
        public enum Kind: Equatable, Sendable {
            /// A scalar, or an empty object or array.
            case value
            /// The opening line of an object or array that can fold.
            case open(path: String, count: Int, folded: Bool)
            /// The closing bracket.
            case close
        }

        public var id: Int
        public var depth: Int
        /// The quoted key, for a member of an object.
        public var key: String?
        /// The value's text, an opening bracket, or the closing one, with a comma when one follows.
        public var text: String
        public var kind: Kind
    }

    /// The lines with every object and array whose path is in `folded` shown as one line.
    /// Paths are `$` for the root and `$.3.1` and so on by position.
    public func lines(folded: Set<String>) -> [Line] {
        var lines: [Line] = []
        appendLines(to: &lines, key: nil, path: "$", depth: 0, trailingComma: false, folded: folded)
        return lines
    }

    private func appendLines(to lines: inout [Line], key: String?, path: String, depth: Int, trailingComma: Bool, folded: Set<String>) {
        let comma = trailingComma ? "," : ""
        switch self {
        case .scalar(let text):
            lines.append(Line(id: lines.count, depth: depth, key: key, text: text + comma, kind: .value))
        case .array(let items):
            if items.isEmpty {
                lines.append(Line(id: lines.count, depth: depth, key: key, text: "[]" + comma, kind: .value))
            } else if folded.contains(path) {
                lines.append(Line(id: lines.count, depth: depth, key: key, text: "[ … ]" + comma, kind: .open(path: path, count: items.count, folded: true)))
            } else {
                lines.append(Line(id: lines.count, depth: depth, key: key, text: "[", kind: .open(path: path, count: items.count, folded: false)))
                for (index, item) in items.enumerated() {
                    item.appendLines(to: &lines, key: nil, path: "\(path).\(index)", depth: depth + 1, trailingComma: index < items.count - 1, folded: folded)
                }
                lines.append(Line(id: lines.count, depth: depth, key: nil, text: "]" + comma, kind: .close))
            }
        case .object(let members):
            if members.isEmpty {
                lines.append(Line(id: lines.count, depth: depth, key: key, text: "{}" + comma, kind: .value))
            } else if folded.contains(path) {
                lines.append(Line(id: lines.count, depth: depth, key: key, text: "{ … }" + comma, kind: .open(path: path, count: members.count, folded: true)))
            } else {
                lines.append(Line(id: lines.count, depth: depth, key: key, text: "{", kind: .open(path: path, count: members.count, folded: false)))
                for (index, member) in members.enumerated() {
                    member.value.appendLines(to: &lines, key: member.key, path: "\(path).\(index)", depth: depth + 1, trailingComma: index < members.count - 1, folded: folded)
                }
                lines.append(Line(id: lines.count, depth: depth, key: nil, text: "}" + comma, kind: .close))
            }
        }
    }

    /// The paths of every object and array below the root at `depth` or deeper, for folding a
    /// large document down to its outline when it opens.
    public func containerPaths(atDepth depth: Int) -> Set<String> {
        var paths = Set<String>()
        collectPaths(path: "$", current: 0, depth: depth, into: &paths)
        return paths
    }

    private func collectPaths(path: String, current: Int, depth: Int, into paths: inout Set<String>) {
        switch self {
        case .scalar: return
        case .array(let items):
            if current >= depth, !items.isEmpty { paths.insert(path) }
            for (index, item) in items.enumerated() { item.collectPaths(path: "\(path).\(index)", current: current + 1, depth: depth, into: &paths) }
        case .object(let members):
            if current >= depth, !members.isEmpty { paths.insert(path) }
            for (index, member) in members.enumerated() { member.value.collectPaths(path: "\(path).\(index)", current: current + 1, depth: depth, into: &paths) }
        }
    }

    // MARK: - Parser

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var isAtEnd: Bool { index >= bytes.count }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func value(depth: Int) -> JSONNode? {
            guard depth <= JSONNode.maximumDepth else { return nil }
            skipWhitespace()
            guard index < bytes.count else { return nil }
            switch bytes[index] {
            case UInt8(ascii: "{"): return object(depth: depth)
            case UInt8(ascii: "["): return array(depth: depth)
            case UInt8(ascii: "\""): return string().map(JSONNode.scalar)
            case UInt8(ascii: "t"): return literal("true")
            case UInt8(ascii: "f"): return literal("false")
            case UInt8(ascii: "n"): return literal("null")
            default: return number()
            }
        }

        mutating func literal(_ word: String) -> JSONNode? {
            let expected = Array(word.utf8)
            guard index + expected.count <= bytes.count, Array(bytes[index..<index + expected.count]) == expected else { return nil }
            index += expected.count
            return .scalar(word)
        }

        mutating func number() -> JSONNode? {
            let start = index
            func digits() -> Int {
                let from = index
                while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
                return index - from
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard index < bytes.count else { return nil }
            if bytes[index] == UInt8(ascii: "0") {
                index += 1
            } else if digits() == 0 {
                return nil
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                guard digits() > 0 else { return nil }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                guard digits() > 0 else { return nil }
            }
            return .scalar(String(decoding: bytes[start..<index], as: UTF8.self))
        }

        /// A string with its quotes, exactly as written, after checking its escapes.
        mutating func string() -> String? {
            let start = index
            index += 1
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    index += 1
                    return String(decoding: bytes[start..<index], as: UTF8.self)
                }
                if byte < 0x20 { return nil }
                if byte == UInt8(ascii: "\\") {
                    index += 1
                    guard index < bytes.count else { return nil }
                    switch bytes[index] {
                    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"), UInt8(ascii: "b"),
                         UInt8(ascii: "f"), UInt8(ascii: "n"), UInt8(ascii: "r"), UInt8(ascii: "t"):
                        index += 1
                    case UInt8(ascii: "u"):
                        guard index + 4 < bytes.count,
                              bytes[(index + 1)...(index + 4)].allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 | 0x20 >= 0x61 && $0 | 0x20 <= 0x66) })
                        else { return nil }
                        index += 5
                    default:
                        return nil
                    }
                    continue
                }
                index += 1
            }
            return nil
        }

        mutating func array(depth: Int) -> JSONNode? {
            index += 1
            var items: [JSONNode] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(items)
            }
            while true {
                guard let item = value(depth: depth + 1) else { return nil }
                items.append(item)
                skipWhitespace()
                guard index < bytes.count else { return nil }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                return nil
            }
        }

        mutating func object(depth: Int) -> JSONNode? {
            index += 1
            var members: [(key: String, value: JSONNode)] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(members)
            }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\""), let key = string() else { return nil }
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
                index += 1
                guard let value = value(depth: depth + 1) else { return nil }
                members.append((key, value))
                skipWhitespace()
                guard index < bytes.count else { return nil }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
                return nil
            }
        }
    }
}
