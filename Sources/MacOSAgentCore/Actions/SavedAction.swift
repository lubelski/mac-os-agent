import Foundation

/// A saved action: a stored tool call, or a short run of them, with the arguments filled in.
/// The app runs it on its own when the owner picks it in the instant row, with no model
/// request. It is data the app runs, not prose the model reads. That is what tells it apart
/// from a skill, which is instructions the model follows with its own judgment.
///
/// An action is a JSON file in `actions/` in Application Support, one per action, named by its
/// id, such as `actions/start-screensaver.json`:
///
/// ```json
/// {
///   "format": 1,
///   "name": "Start Screensaver",
///   "description": "Starts the screen saver.",
///   "phrases": ["screensaver", "screen saver"],
///   "enabled": true,
///   "steps": [
///     {
///       "tool": "open_application",
///       "arguments": { "bundle_identifier_or_path": "/System/Library/CoreServices/ScreenSaverEngine.app" }
///     }
///   ]
/// }
/// ```
///
/// `phrases` and `enabled` may be left out: no extra phrases, and on. Unknown keys are ignored,
/// so a later version can add one. Parameters, such as the 40 in "volume 40", would come as a
/// top-level `parameters` list and an argument value of the form `{"$parameter": "level"}`,
/// in a file marked `"format": 2`, which this version lists with a problem instead of running
/// the placeholder as written.
public struct SavedAction: Sendable, Equatable, Identifiable {
    public struct Step: Sendable, Equatable {
        /// The tool's name, as the model sees it, such as `open_application`.
        public var tool: String
        /// The tool's arguments, a JSON object.
        public var arguments: JSONValue

        public init(tool: String, arguments: JSONValue) {
            self.tool = tool
            self.arguments = arguments
        }
    }

    /// The file's name without `.json`.
    public var id: String
    /// What the instant row shows, and the first thing typed text is matched against.
    public var name: String
    /// One line on what it does.
    public var description: String
    /// Other things the owner might type for it, such as "screen saver".
    public var phrases: [String]
    public var isEnabled: Bool
    public var steps: [Step]

    public static let format = 1
    public static let maximumNameLength = 48
    public static let maximumSteps = 10
    public static let maximumPhrases = 12

    public init(id: String, name: String, description: String, phrases: [String] = [], isEnabled: Bool = true, steps: [Step]) {
        self.id = id
        self.name = name
        self.description = description
        self.phrases = phrases
        self.isEnabled = isEnabled
        self.steps = steps
    }

    /// The names typed text is matched against: the name, then the phrases.
    public var matchNames: [String] { [name] + phrases }

    public func matches(_ filter: String) -> Bool {
        let wanted = filter.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return true }
        return ([id, description] + matchNames + steps.map(\.tool))
            .contains { $0.localizedCaseInsensitiveContains(wanted) }
    }

    // MARK: - The file

    /// Reads a file's text. The id comes from the file's name, so it is passed in.
    public static func parse(_ text: String, id: String) throws(SavedActionError) -> SavedAction {
        guard let value = JSONValue.parse(text) else { throw SavedActionError("The file is not valid JSON.") }
        guard case .object(let object) = value else { throw SavedActionError("The file should be a JSON object.") }
        guard let format = object["format"]?.numberValue else {
            throw SavedActionError("The file needs \"format\": \(Self.format).")
        }
        guard format == Double(Self.format) else {
            throw SavedActionError("The file is format \(Self.formatted(format)), and this version of the app reads format \(Self.format).")
        }
        guard let rawName = object["name"]?.stringValue else { throw SavedActionError("The file needs a \"name\".") }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SavedActionError("The name is empty.") }
        guard name.count <= maximumNameLength else {
            throw SavedActionError("The name is longer than \(maximumNameLength) characters.")
        }
        guard !name.contains(where: \.isNewline) else { throw SavedActionError("The name is more than one line.") }
        let description = object["description"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !description.isEmpty else { throw SavedActionError("The file needs a one-line \"description\".") }

        var phrases: [String] = []
        switch object["phrases"] {
        case nil, .null?: break
        case .array(let values)?:
            for value in values {
                guard let phrase = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !phrase.isEmpty else {
                    throw SavedActionError("Each phrase should be a string with some text.")
                }
                guard !phrase.contains(where: \.isNewline) else { throw SavedActionError("The phrase \"\(phrase)\" is more than one line.") }
                if !phrases.contains(where: { $0.caseInsensitiveCompare(phrase) == .orderedSame }) { phrases.append(phrase) }
            }
            guard phrases.count <= maximumPhrases else { throw SavedActionError("There are more than \(maximumPhrases) phrases.") }
        default:
            throw SavedActionError("\"phrases\" should be a list of strings.")
        }

        let enabled: Bool
        switch object["enabled"] {
        case nil, .null?: enabled = true
        case .bool(let value)?: enabled = value
        default: throw SavedActionError("\"enabled\" should be true or false.")
        }

        guard let stepValues = object["steps"]?.arrayValue else {
            throw SavedActionError("The file needs \"steps\", a list of tool calls.")
        }
        guard !stepValues.isEmpty else { throw SavedActionError("The action has no steps.") }
        guard stepValues.count <= maximumSteps else { throw SavedActionError("The action has more than \(maximumSteps) steps.") }
        var steps: [Step] = []
        for (index, value) in stepValues.enumerated() {
            let number = index + 1
            guard case .object(let step) = value else { throw SavedActionError("Step \(number) should be an object.") }
            guard let tool = step["tool"]?.stringValue?.trimmingCharacters(in: .whitespaces), !tool.isEmpty else {
                throw SavedActionError("Step \(number) needs a \"tool\".")
            }
            let arguments = step["arguments"] ?? .object([:])
            guard case .object = arguments else { throw SavedActionError("Step \(number)'s \"arguments\" should be an object.") }
            steps.append(Step(tool: tool, arguments: arguments))
        }
        return SavedAction(id: id, name: name, description: description, phrases: phrases, isEnabled: enabled, steps: steps)
    }

    /// The file as the app writes it, with its keys in reading order and two spaces of indent.
    public var fileText: String {
        func string(_ text: String) -> String { JSONValue.string(text).encodedString() }
        var lines = ["{", "  \"format\": \(Self.format),", "  \"name\": \(string(name)),", "  \"description\": \(string(description)),"]
        if !phrases.isEmpty {
            lines.append("  \"phrases\": [\(phrases.map(string).joined(separator: ", "))],")
        }
        lines.append("  \"enabled\": \(isEnabled),")
        lines.append("  \"steps\": [")
        for (index, step) in steps.enumerated() {
            let arguments = step.arguments.prettyEncodedString()
                .split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated().map { $0.offset == 0 ? String($0.element) : "      " + $0.element }
                .joined(separator: "\n")
            lines.append("    {")
            lines.append("      \"tool\": \(string(step.tool)),")
            lines.append("      \"arguments\": \(arguments)")
            lines.append("    }" + (index < steps.count - 1 ? "," : ""))
        }
        lines.append("  ]")
        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func formatted(_ number: Double) -> String {
        number.rounded() == number ? String(Int(number)) : String(number)
    }
}

/// Why an action file could not be read, saved, or deleted.
public struct SavedActionError: Error, Equatable, CustomStringConvertible, LocalizedError {
    public var description: String
    public init(_ description: String) { self.description = description }
    public var errorDescription: String? { description }
}

/// An action as Settings and the agent list it: a file in the actions folder, read or not.
public struct SavedActionEntry: Sendable, Equatable, Identifiable {
    public var id: String
    /// The name from the file, or the id when the file could not be read.
    public var name: String
    /// Nil when the file could not be read.
    public var action: SavedAction?
    /// Why the file could not be read. Nil when it is fine.
    public var problem: String?
    public var fileURL: URL

    /// True when the instant row may offer it: it reads, and it is on.
    public var isAvailable: Bool { action?.isEnabled == true && problem == nil }
}

/// The action files in `actions/` in Application Support. The folder is read each time, so a
/// file the owner or the agent writes is picked up without a relaunch.
public struct SavedActionLibrary: Sendable {
    public let folder: URL

    public static let fileExtension = "json"
    /// Posted after the app itself changes an action, so the panel and Settings read again.
    public static let didChangeNotification = Notification.Name("dev.lubelski.mac-os-agent.actionsDidChange")

    public init(folder: URL = AgentPaths.actionsFolder) {
        self.folder = folder
    }

    /// Every action file, by name. A file that cannot be read is listed with its problem.
    public func entries() -> [SavedActionEntry] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.plainPath) else { return [] }
        return names
            .filter { $0.hasSuffix("." + Self.fileExtension) && !$0.hasPrefix(".") }
            .map { fileName -> SavedActionEntry in
                let id = String(fileName.dropLast(Self.fileExtension.count + 1))
                let url = folder.appending(path: fileName)
                var entry = SavedActionEntry(id: id, name: id, action: nil, problem: nil, fileURL: url)
                if !ThemeLibrary.isValidIdentifier(id) {
                    entry.problem = "The file name should be lowercase letters, digits, and hyphens, then .json."
                } else if let text = try? String(contentsOf: url, encoding: .utf8) {
                    do {
                        let action = try SavedAction.parse(text, id: id)
                        entry.action = action
                        entry.name = action.name
                    } catch {
                        entry.problem = String(describing: error)
                    }
                } else {
                    entry.problem = "The file could not be read as text."
                }
                return entry
            }
            .sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
    }

    /// The actions the instant row may offer: those that read and are on.
    public func availableActions() -> [SavedAction] {
        entries().compactMap { $0.isAvailable ? $0.action : nil }
    }

    public func entry(id: String) -> SavedActionEntry? {
        entries().first { $0.id == id }
    }

    /// Finds an action by its id or, ignoring case, its name.
    public func find(_ idOrName: String) -> SavedActionEntry? {
        let wanted = idOrName.trimmingCharacters(in: .whitespaces)
        let all = entries()
        return all.first { $0.id == wanted } ?? all.first { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
    }

    /// Writes an action to its file, named by its id, and returns the id.
    @discardableResult
    public func save(_ action: SavedAction) throws(SavedActionError) -> String {
        guard ThemeLibrary.isValidIdentifier(action.id) else {
            throw SavedActionError("The id \"\(action.id)\" should be lowercase letters, digits, and hyphens.")
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(action.fileText.utf8).write(to: fileURL(id: action.id), options: .atomic)
        } catch {
            throw SavedActionError("Could not write the action file: \(error.localizedDescription)")
        }
        Self.postChange()
        return action.id
    }

    /// Turns an action on or off by rewriting its file with the flag changed.
    public func setEnabled(_ enabled: Bool, id: String) throws(SavedActionError) {
        guard var action = entry(id: id)?.action else {
            throw SavedActionError("The file for \(id) cannot be read, so it cannot be turned \(enabled ? "on" : "off").")
        }
        action.isEnabled = enabled
        try save(action)
    }

    public func delete(id: String) throws(SavedActionError) {
        let url = fileURL(id: id)
        guard FileManager.default.fileExists(atPath: url.plainPath) else {
            throw SavedActionError("There is no action file \(url.lastPathComponent).")
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw SavedActionError("Could not delete the action file: \(error.localizedDescription)")
        }
        Self.postChange()
    }

    public func fileURL(id: String) -> URL {
        folder.appending(path: "\(id).\(Self.fileExtension)")
    }

    /// The id for a name: lowercase letters and digits, with hyphens between the words.
    public static func identifier(for name: String) -> String {
        let id = SkillLibrary.suggestedName(from: name)
        return id.isEmpty ? "action" : String(id.prefix(64))
    }

    static func postChange() {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}

extension SavedActionLibrary {
    /// The one line shown by the text field after a task that added or changed actions the
    /// instant row offers, such as "The action Start Screensaver is ready to use. Type its name
    /// and press Return.", or nil when none did. Actions that are off or broken are not named.
    public static func changeNotice(from before: [SavedActionEntry], to after: [SavedActionEntry]) -> String? {
        let old = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var added: [String] = []
        var changed: [String] = []
        for entry in after where entry.isAvailable {
            guard let previous = old[entry.id], previous.isAvailable else {
                added.append(entry.name)
                continue
            }
            if previous.action != entry.action { changed.append(entry.name) }
        }
        var sentences: [String] = []
        if !added.isEmpty {
            sentences.append(added.count == 1
                ? "The action \(added[0]) is ready to use. Type its name and press Return."
                : "The actions \(list(added)) are ready to use.")
        }
        if !changed.isEmpty {
            sentences.append(changed.count == 1 ? "The action \(changed[0]) is updated." : "The actions \(list(changed)) are updated.")
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    private static func list(_ names: [String]) -> String {
        switch names.count {
        case 1: names[0]
        case 2: "\(names[0]) and \(names[1])"
        default: names.dropLast().joined(separator: ", ") + ", and " + names.last!
        }
    }
}
