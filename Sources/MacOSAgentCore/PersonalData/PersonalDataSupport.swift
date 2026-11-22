import CryptoKit
import Foundation

/// Short identifiers for items the model reads and then acts on, such as `3f9a2c1b`.
///
/// EventKit's own identifiers are long. A short one is the start of a hash of the long one, so
/// it is the same every time the item is read. The table remembers which long identifier each
/// short one stands for, for this run of the app. A short one it has not seen, such as one from
/// an earlier episode, is found again by reading the items and hashing theirs.
public actor ShortIdentifierTable {
    private var longIdentifiers: [String: String] = [:]

    public init() {}

    public static func short(_ identifier: String) -> String {
        SHA256.hash(data: Data(identifier.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// Records a long identifier and returns its short one.
    @discardableResult
    public func remember(_ identifier: String) -> String {
        let short = Self.short(identifier)
        longIdentifiers[short] = identifier
        return short
    }

    public func rememberAll(_ identifiers: [String]) {
        for identifier in identifiers { longIdentifiers[Self.short(identifier)] = identifier }
    }

    public func long(for short: String) -> String? {
        longIdentifiers[short.lowercased()]
    }
}

/// A list of reminders or a calendar, as the tools resolve it from a name.
struct NamedCollection: Sendable, Equatable {
    var id: String
    var title: String
    var account: String?
    var isDefault: Bool
    var allowsChanges: Bool
}

enum PersonalDataText {
    /// True when every word of the query is in one of the fields, ignoring case and accents.
    static func matches(_ query: String, fields: [String?]) -> Bool {
        let haystack = fields.compactMap { $0 }.joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let words = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
        return words.allSatisfy { haystack.contains($0) }
    }

    /// One line, cut to a length, for notes inside a result line.
    static func clipped(_ text: String, to limit: Int = 160) -> String {
        let line = AgentInstructions.singleLine(text)
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }

    /// The names the tools show for collections. A name used by two accounts gets the account
    /// after it, such as `Reminders (iCloud)`, so the model can tell them apart.
    static func displayNames(_ collections: [NamedCollection]) -> [String: String] {
        let counts = Dictionary(grouping: collections, by: { $0.title.lowercased() }).mapValues(\.count)
        var names: [String: String] = [:]
        for collection in collections {
            if counts[collection.title.lowercased(), default: 0] > 1, let account = collection.account, !account.isEmpty {
                names[collection.id] = "\(collection.title) (\(account))"
            } else {
                names[collection.id] = collection.title
            }
        }
        return names
    }

    /// `Home (default), Work, US Holidays (read only)`.
    static func summary(_ collections: [NamedCollection]) -> String {
        let names = displayNames(collections)
        return collections.map { collection in
            var notes: [String] = []
            if collection.isDefault { notes.append("default") }
            if !collection.allowsChanges { notes.append("read only") }
            let name = names[collection.id] ?? collection.title
            return notes.isEmpty ? name : "\(name) (\(notes.joined(separator: ", ")))"
        }.joined(separator: ", ")
    }

    /// Finds a collection by its name as the tools show it, ignoring case. `noun` is "list"
    /// or "calendar", for the error.
    static func resolve(_ name: String, in collections: [NamedCollection], noun: String) -> Result<NamedCollection, ToolInputError> {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = displayNames(collections)
        if let exact = collections.first(where: { names[$0.id]?.caseInsensitiveCompare(wanted) == .orderedSame || $0.id == wanted }) {
            return .success(exact)
        }
        let byTitle = collections.filter { $0.title.caseInsensitiveCompare(wanted) == .orderedSame }
        if byTitle.count == 1 { return .success(byTitle[0]) }
        if byTitle.count > 1 {
            let options = byTitle.compactMap { names[$0.id] }.map { "\"\($0)\"" }.joined(separator: " or ")
            return .failure(ToolInputError("there is more than one \(noun) named \"\(wanted)\". Pass \(options)."))
        }
        let all = collections.compactMap { names[$0.id] }.joined(separator: ", ")
        return .failure(ToolInputError("there is no \(noun) named \"\(wanted)\". The \(noun)s are: \(all)."))
    }
}

/// A problem with what the model passed, worded to follow "Error: ".
struct ToolInputError: Error, Equatable {
    var message: String
    init(_ message: String) { self.message = message }
}

/// Small helpers for strict schemas, where every property is required and optional ones take null.
enum Schema {
    static func string(_ description: String) -> JSONValue {
        ["type": "string", "description": .string(description)]
    }

    static func nullableString(_ description: String) -> JSONValue {
        ["type": ["string", "null"], "description": .string(description)]
    }

    static func nullableBoolean(_ description: String) -> JSONValue {
        ["type": ["boolean", "null"], "description": .string(description)]
    }

    static func nullableInteger(_ description: String) -> JSONValue {
        ["type": ["integer", "null"], "description": .string(description)]
    }

    static func nullableChoice(_ values: [String], _ description: String) -> JSONValue {
        ["type": ["string", "null"], "enum": .array(values.map { .string($0) } + [.null]), "description": .string(description)]
    }

    static func object(_ properties: [String: JSONValue]) -> JSONValue {
        [
            "type": "object",
            "properties": .object(properties),
            "required": .array(properties.keys.sorted().map { .string($0) }),
            "additionalProperties": false,
        ]
    }
}

extension JSONValue {
    /// The string, trimmed, or nil for null, a missing value, or anything that is not a string.
    var trimmedString: String? {
        stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
