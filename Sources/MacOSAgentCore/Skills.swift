import CryptoKit
import Foundation

/// A skill: a folder with a `SKILL.md` that has `name` and `description` front matter and
/// then instructions, plus any scripts beside it. This is the Agent Skills format.
public struct Skill: Sendable, Equatable, Identifiable {
    public var id: String { folderName }
    public var folderName: String
    public var folderURL: URL
    /// The name from the front matter, or the folder's name when the file could not be read.
    public var name: String
    public var description: String
    public var isEnabled: Bool
    /// Why the skill cannot be used, such as a missing description. Nil when it is fine.
    public var problem: String?
    /// Whether the owner can invoke it with a slash in the panel, from the `user-invocable`
    /// front matter key. True unless the key says false.
    public var isUserInvocable: Bool = true
    /// A fingerprint of the `SKILL.md` text, which changes whenever the file does. Nil when
    /// there is no readable file.
    public var revision: String?

    public var fileURL: URL { folderURL.appending(path: SkillLibrary.fileName) }
    /// Listed in the instructions and loadable by the agent.
    public var isAvailable: Bool { isEnabled && problem == nil }
}

extension Skill {
    /// True when the name, folder, or description contains the text, ignoring case. Empty text matches.
    public func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return [name, folderName, description].contains { $0.localizedStandardContains(query) }
    }
}

/// A skill's `SKILL.md` and folder, read for showing in Settings.
public struct SkillContents: Sendable, Equatable {
    /// False when the folder has no readable `SKILL.md`.
    public var hasFile: Bool
    /// The instructions after the front matter, or the whole file when it has no valid front matter.
    public var instructions: String
    /// The other files in the folder, relative to it.
    public var files: [String]
}

/// The parts of a `SKILL.md`.
public struct SkillDocument: Sendable, Equatable {
    public var name: String
    public var description: String
    /// Everything after the front matter.
    public var body: String
    /// False when the front matter has `user-invocable: false`, for a skill meant only for the
    /// agent. This is the key Claude Code uses for the same thing. The Agent Skills format
    /// itself has no key for it.
    public var isUserInvocable: Bool = true

    /// The front matter key that turns off invoking a skill with a slash.
    public static let userInvocableKey = "user-invocable"

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case noFrontMatter
        case unclosedFrontMatter
        case missingField(String)
        case invalidName(String)
        case descriptionTooLong(Int)
        case invalidUserInvocable(String)

        public var description: String {
            switch self {
            case .noFrontMatter: "SKILL.md does not start with front matter between two lines of three dashes."
            case .unclosedFrontMatter: "The front matter in SKILL.md has no closing line of three dashes."
            case .missingField(let field): "The front matter has no \(field)."
            case .invalidName(let name):
                "The name \"\(name)\" should be up to 64 lowercase letters, digits, and hyphens."
            case .descriptionTooLong(let count): "The description is \(count) characters. The limit is 1024."
            case .invalidUserInvocable(let value):
                "user-invocable is \"\(value)\". It should be true or false."
            }
        }
    }

    /// The longest description the format allows.
    public static let descriptionLimit = 1024

    /// Parses the text of a `SKILL.md`. Front matter is a small subset of YAML: `key: value`
    /// lines, with optional quotes, and `>` or `|` blocks of indented lines. Other keys, such
    /// as `license` or a nested `metadata` map, are allowed and ignored.
    public static func parse(_ text: String) throws(ParseError) -> SkillDocument {
        var text = text
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        // "\r\n" is one Character in Swift, so turn it into "\n" before splitting.
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            throw .noFrontMatter
        }
        guard let end = lines.dropFirst().firstIndex(where: {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return trimmed == "---" || trimmed == "..."
        }) else {
            throw .unclosedFrontMatter
        }
        let fields = frontMatterFields(Array(lines[1..<end]))
        let name = fields["name"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let description = fields["description"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { throw .missingField("name") }
        guard !description.isEmpty else { throw .missingField("description") }
        guard isValidName(name) else { throw .invalidName(name) }
        guard description.count <= descriptionLimit else { throw .descriptionTooLong(description.count) }
        var userInvocable = true
        if let value = fields[userInvocableKey]?.trimmingCharacters(in: .whitespacesAndNewlines) {
            switch value.lowercased() {
            case "true": userInvocable = true
            case "false": userInvocable = false
            default: throw .invalidUserInvocable(value)
            }
        }
        let body = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return SkillDocument(name: name, description: description, body: body, isUserInvocable: userInvocable)
    }

    /// Lowercase letters, digits, and single hyphens between them, up to 64 characters.
    public static func isValidName(_ name: String) -> Bool {
        guard (1...64).contains(name.count), !name.hasPrefix("-"), !name.hasSuffix("-"), !name.contains("--")
        else { return false }
        return name.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    static func frontMatterFields(_ lines: [String]) -> [String: String] {
        var fields: [String: String] = [:]
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            guard let first = line.first, !first.isWhitespace, first != "#",
                  let colon = line.firstIndex(of: ":")
            else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // Indented lines that follow belong to this key: a block, a nested map, or a value
            // that runs onto the next line.
            var continuation: [String] = []
            while index < lines.count, lines[index].isEmpty || lines[index].first!.isWhitespace {
                continuation.append(lines[index].trimmingCharacters(in: .whitespaces))
                index += 1
            }
            while continuation.last?.isEmpty == true { continuation.removeLast() }
            if value.hasPrefix("|") {
                value = continuation.joined(separator: "\n")
            } else if value.hasPrefix(">") || value.isEmpty {
                value = continuation.filter { !$0.isEmpty }.joined(separator: " ")
            } else {
                value = unquoted(([value] + continuation.filter { !$0.isEmpty }).joined(separator: " "))
            }
            fields[key] = value
        }
        return fields
    }

    static func unquoted(_ value: String) -> String {
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            return String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        // A comment after a plain value.
        if let comment = value.range(of: " #") { return String(value[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces) }
        return value
    }
}

/// The skills folder in Application Support, and which skills are turned off.
///
/// The folder is plain files on purpose. The agent can reach it with the shell tool and write
/// new skills itself, which is how it extends what it can do.
public struct SkillLibrary: Sendable {
    public static let fileName = "SKILL.md"
    /// Posted when the app itself changes the skills, such as turning one on or off in
    /// Settings, so the panel's slash commands follow at once.
    public static let didChangeNotification = Notification.Name("dev.lubelski.mac-os-agent.skillsDidChange")

    public let folder: URL
    public let settingsFile: URL

    public init(folder: URL = AgentPaths.skillsFolder, settingsFile: URL = AgentPaths.skillSettingsFile) {
        self.folder = folder
        self.settingsFile = settingsFile
    }

    public enum LibraryError: Error, Equatable, LocalizedError {
        case invalidName(String)
        case alreadyExists(String)

        public var errorDescription: String? {
            switch self {
            case .invalidName(let name):
                "\"\(name)\" is not a skill name. Use lowercase letters, digits, and hyphens, up to 64 characters."
            case .alreadyExists(let name): "There is already a skill folder named \(name)."
            }
        }
    }

    /// Every skill folder, sorted by folder name, with any problem found in its `SKILL.md`.
    public func skills() -> [Skill] {
        let disabled = disabledFolders()
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        var skills: [Skill] = []
        var names = Set<String>()
        for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let folderName = url.lastPathComponent
            var skill = Skill(
                folderName: folderName, folderURL: url, name: folderName, description: "",
                isEnabled: !disabled.contains(folderName), problem: nil)
            let text = try? String(contentsOf: url.appending(path: Self.fileName), encoding: .utf8)
            skill.revision = text.map(Self.revision(of:))
            do {
                guard let text else { throw CocoaError(.fileReadNoSuchFile) }
                let document = try SkillDocument.parse(text)
                skill.name = document.name
                skill.description = document.description
                skill.isUserInvocable = document.isUserInvocable
                if !names.insert(document.name).inserted {
                    skill.problem = "Another skill already has the name \(document.name)."
                }
            } catch let error as SkillDocument.ParseError {
                skill.problem = error.description
            } catch {
                skill.problem = "There is no SKILL.md in this folder."
            }
            skills.append(skill)
        }
        return skills
    }

    static func revision(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    func document(in folderURL: URL) throws -> SkillDocument {
        let text = try String(contentsOf: folderURL.appending(path: Self.fileName), encoding: .utf8)
        return try SkillDocument.parse(text)
    }

    /// The skill's full instructions, for the agent.
    public func load(named name: String) -> Result<(Skill, SkillDocument), LoadError> {
        let all = skills()
        guard let skill = all.first(where: { $0.name == name && $0.problem == nil })
            ?? all.first(where: { $0.folderName == name })
        else {
            return .failure(.notFound(available: all.filter(\.isAvailable).map(\.name)))
        }
        if let problem = skill.problem { return .failure(.broken(problem)) }
        if !skill.isEnabled { return .failure(.turnedOff) }
        do {
            return .success((skill, try document(in: skill.folderURL)))
        } catch {
            return .failure(.broken("\(error)"))
        }
    }

    public enum LoadError: Error, Equatable {
        case notFound(available: [String])
        case turnedOff
        case broken(String)
    }

    /// The files in a skill's folder other than `SKILL.md`, as paths relative to the folder,
    /// sorted. Hidden files are left out.
    public static func files(in folder: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        else { return [] }
        let base = folder.plainPath.hasSuffix("/") ? folder.plainPath : folder.plainPath + "/"
        var files: [String] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = url.plainPath
            let relative = path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent
            if relative != fileName { files.append(relative) }
        }
        return files.sorted()
    }

    /// What Settings shows for one skill: its instructions and the files beside them.
    public func contents(of skill: Skill) -> SkillContents {
        let text = try? String(contentsOf: skill.fileURL, encoding: .utf8)
        let instructions: String
        if let text, let document = try? SkillDocument.parse(text) {
            instructions = document.body
        } else {
            instructions = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return SkillContents(hasFile: text != nil, instructions: instructions, files: Self.files(in: skill.folderURL))
    }

    // MARK: - Turning skills on and off

    private struct Settings: Codable {
        var disabled: [String]
    }

    public func disabledFolders() -> Set<String> {
        guard let data = try? Data(contentsOf: settingsFile),
              let settings = try? JSONDecoder().decode(Settings.self, from: data)
        else { return [] }
        return Set(settings.disabled)
    }

    public func setEnabled(_ enabled: Bool, folderName: String) throws {
        var disabled = disabledFolders()
        if enabled { disabled.remove(folderName) } else { disabled.insert(folderName) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: settingsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(Settings(disabled: disabled.sorted())).write(to: settingsFile, options: .atomic)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    // MARK: - Creating skills

    /// Makes a folder with a `SKILL.md` to fill in, and returns the new skill.
    @discardableResult
    public func create(name: String, description: String) throws -> Skill {
        guard SkillDocument.isValidName(name) else { throw LibraryError.invalidName(name) }
        let skillFolder = folder.appending(path: name, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: skillFolder.plainPath) { throw LibraryError.alreadyExists(name) }
        try FileManager.default.createDirectory(at: skillFolder, withIntermediateDirectories: true)
        let description = AgentInstructions.singleLine(description).isEmpty
            ? "Say what this skill does and when to use it."
            : AgentInstructions.singleLine(description)
        let text = """
            ---
            name: \(name)
            description: \(Self.quotedIfNeeded(description))
            ---

            Write the steps for this skill here. Scripts and other files can go in this folder beside \
            SKILL.md.

            """
        try Data(text.utf8).write(to: skillFolder.appending(path: Self.fileName), options: .atomic)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        return skills().first { $0.folderName == name }!
    }

    /// Turns a folder name typed in Settings into a skill name: "Rename Photos" gives rename-photos.
    public static func suggestedName(from text: String) -> String {
        let words = text.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .split(whereSeparator: { !(("a"..."z").contains($0) || ("0"..."9").contains($0)) })
        return String(words.joined(separator: "-").prefix(64)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func quotedIfNeeded(_ value: String) -> String {
        let needsQuotes = value.contains(": ") || value.contains(" #") || value.first.map { "\"'>|[{&*!%@`-".contains($0) } == true
        guard needsQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Gives the agent a skill's full instructions. The instructions list only each skill's name
/// and description, so the rest costs nothing until a task needs it.
public struct LoadSkillTool: AgentTool {
    public static let name = "load_skill"

    public var library: SkillLibrary
    /// The most files beside SKILL.md to list.
    public var fileListLimit: Int

    public init(library: SkillLibrary = SkillLibrary(), fileListLimit: Int = 50) {
        self.library = library
        self.fileListLimit = fileListLimit
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: Self.name,
            description: """
                Load a skill's full instructions by its name, from the skills listed in your instructions. \
                Returns the instructions, the skill's folder, and the files beside SKILL.md, such as scripts \
                to run with run_shell_command.
                """,
            parameters: [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "The skill's name, such as rename-photos."],
                ],
                "required": ["name"],
                "additionalProperties": false,
            ])
    }

    public func summary(arguments: JSONValue) -> String {
        guard let name = arguments["name"]?.trimmedString, !name.isEmpty else { return "Load a skill" }
        return "Load the \(name) skill"
    }

    public func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        guard let name = arguments["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return "Error: the call did not include a skill name."
        }
        switch library.load(named: name) {
        case .failure(.notFound(let available)):
            let list = available.isEmpty ? "There are no skills." : "The skills are: \(available.joined(separator: ", "))."
            return "Error: there is no skill named \"\(name)\". \(list)"
        case .failure(.turnedOff):
            return "Error: the \(name) skill is turned off in Settings. Do not use it."
        case .failure(.broken(let problem)):
            return "Error: the \(name) skill cannot be used. \(problem)"
        case .success(let (skill, document)):
            return Self.instructions(skill: skill, document: document, fileListLimit: fileListLimit)
        }
    }

    /// A skill's instructions as the agent reads them: where it is, the files beside SKILL.md,
    /// and the instructions. A skill invoked with a slash sends the same text in its message.
    public static func instructions(skill: Skill, document: SkillDocument, fileListLimit: Int = 50) -> String {
        var text = "Skill \(document.name), from \(skill.fileURL.plainPath)\n"
        var files = SkillLibrary.files(in: skill.folderURL)
        if files.count > fileListLimit {
            files = Array(files.prefix(fileListLimit)) + ["(\(files.count - fileListLimit) more)"]
        }
        if !files.isEmpty {
            text += "Files beside SKILL.md, in \(skill.folderURL.plainPath):\n"
            text += files.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        return text + "\n" + document.body
    }
}
