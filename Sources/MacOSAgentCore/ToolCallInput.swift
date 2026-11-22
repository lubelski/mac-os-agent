import Foundation

/// A tool call's input laid out for reading, with fixed rules and no model.
public enum ToolCallInput {
    /// A command this long or longer, with more than one part, is broken into lines.
    public static let commandBreakLength = 72

    /// A shell command broken before each `|`, `||`, `&&`, and `;` that is outside quotes,
    /// escapes, `$(…)`, backticks, parentheses, and braces. Nil when breaking it would not be
    /// safe or would not help: a short command, one part only, a line break or a here
    /// document already in it, a comment, or quotes that do not close. The view then shows
    /// the command as written.
    public static func commandLines(_ command: String) -> [String]? {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard command.count >= commandBreakLength, !command.contains("\n"), !command.contains("<<") else { return nil }
        let characters = Array(command)
        var parts: [String] = []
        var current = ""
        var single = false
        var double = false
        var backtick = false
        var depth = 0
        var index = 0
        var previous: Character = " "
        var afterOperator = false
        while index < characters.count {
            let character = characters[index]
            let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil
            if single {
                current.append(character)
                if character == "'" { single = false }
            } else if character == "\\" {
                current.append(character)
                if let next { current.append(next); index += 1 }
            } else if double {
                current.append(character)
                if character == "\"" { double = false }
            } else if backtick {
                current.append(character)
                if character == "`" { backtick = false }
            } else {
                switch character {
                case "'": single = true; current.append(character)
                case "\"": double = true; current.append(character)
                case "`": backtick = true; current.append(character)
                case "(", "{": depth += 1; current.append(character)
                case ")", "}": depth -= 1; current.append(character)
                case "#" where previous == " ":
                    return nil
                case "|", "&", ";":
                    if depth > 0 {
                        current.append(character)
                        break
                    }
                    var op = String(character)
                    if let next, (character == "|" && next == "|") || (character == "&" && next == "&") {
                        op.append(next)
                        index += 1
                    } else if character == "&" || (character == "|" && next == "&") || (character == ";" && next == ";") {
                        // A background `&`, `|&`, or a case `;;` stays where it is.
                        current.append(character)
                        break
                    }
                    parts.append(current.trimmingCharacters(in: .whitespaces))
                    current = op + " "
                    afterOperator = true
                    previous = character
                    index += 1
                    continue
                case " " where afterOperator:
                    break
                default:
                    current.append(character)
                }
            }
            if character != " " { afterOperator = false }
            previous = character
            index += 1
        }
        guard !single, !double, !backtick, depth == 0 else { return nil }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        guard parts.count >= 2, !parts.contains(where: { $0.isEmpty || $0 == "|" || $0 == "&&" || $0 == "||" || $0 == ";" }) else { return nil }
        return parts.enumerated().map { index, part in index == 0 ? part : "  " + part }
    }

    /// One labeled argument of a call.
    public struct Field: Equatable, Sendable, Identifiable {
        public enum Value: Equatable, Sendable {
            /// A string, unquoted and unescaped.
            case text(String)
            /// A number, true, false, or null, as written.
            case literal(String)
            /// An object or array, pretty printed.
            case structured(JSONNode)
            /// An array of objects whose values are all plain, such as the change tools'
            /// `changes`: each object as its fields that are not null, in the model's order.
            case records([[Pair]])
        }

        public var id: String { name }
        public var name: String
        public var value: Value
    }

    /// One field of a record, with a string shown without quotes.
    public struct Pair: Equatable, Sendable {
        public var key: String
        public var value: String
    }

    /// The records in an array of flat objects, or nil when any item is not a flat object.
    static func records(_ node: JSONNode) -> [[Pair]]? {
        guard case .array(let items) = node, !items.isEmpty else { return nil }
        var records: [[Pair]] = []
        for item in items {
            guard case .object(let members) = item else { return nil }
            var pairs: [Pair] = []
            for member in members {
                guard case .scalar(let text) = member.value else { return nil }
                if text == "null" { continue }
                pairs.append(Pair(key: JSONNode.scalar(member.key).stringValue ?? member.key, value: member.value.stringValue ?? text))
            }
            records.append(pairs)
        }
        return records
    }

    /// The arguments as labeled fields, in the order the model wrote them. Nil when they are not
    /// a JSON object, and the view shows the raw text.
    public static func fields(_ arguments: String) -> [Field]? {
        guard case .object(let members)? = JSONNode.parse(arguments) else { return nil }
        return members.map { member in
            let name = JSONNode.scalar(member.key).stringValue ?? member.key
            switch member.value {
            case .scalar(let text):
                if let string = member.value.stringValue, text.hasPrefix("\"") {
                    return Field(name: name, value: .text(string))
                }
                return Field(name: name, value: .literal(text))
            case .array, .object:
                if let records = records(member.value) { return Field(name: name, value: .records(records)) }
                return Field(name: name, value: .structured(member.value))
            }
        }
    }
}
