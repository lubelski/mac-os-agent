import Foundation

/// A skill the owner can invoke with a slash in the main panel, such as `/rename-photos`.
public struct SkillCommand: Sendable, Equatable, Hashable {
    /// The skill's name, without the slash.
    public var name: String
    public var description: String
    public var folderName: String
    /// The skill's `revision`, so a change to its `SKILL.md` makes a different command.
    public var revision: String?

    public init(name: String, description: String, folderName: String, revision: String? = nil) {
        self.name = name
        self.description = description
        self.folderName = folderName
        self.revision = revision
    }

    /// What the owner types, with its slash.
    public var slashName: String { "/" + name }
}

/// One entry in the list of commands shown as the owner types a slash.
public enum SlashCommandItem: Sendable, Equatable, Hashable, Identifiable {
    case builtIn(SlashCommand)
    case skill(SkillCommand)

    public var id: String { name }

    /// What the owner types, with its slash.
    public var name: String {
        switch self {
        case .builtIn(let command): command.name
        case .skill(let skill): skill.slashName
        }
    }

    /// The hint beside the name. A skill's is its description.
    public func summary(incognito: Bool = false) -> String {
        switch self {
        case .builtIn(let command): incognito ? command.incognitoSummary : command.summary
        case .skill(let skill): skill.description
        }
    }

    /// What choosing it puts in the field. A skill takes the rest of the line as its text, so
    /// it ends with a space for the owner to go on typing.
    public var completion: String {
        switch self {
        case .builtIn(let command): command.name
        case .skill(let skill): skill.slashName + " "
        }
    }
}

/// The commands the owner can type with a slash: the app's own, then each skill that is on,
/// has no problem, and can be invoked by the owner.
///
/// The app's commands win over a skill with the same name. Such a skill is left out of the
/// list and cannot be invoked with a slash, and Settings says why. The agent can still load it.
/// The incognito window has no skills, so its menu has only the app's commands.
public struct SlashCommandMenu: Sendable, Equatable {
    /// The skill commands, sorted by name.
    public let skills: [SkillCommand]

    public init(skills: [SkillCommand] = []) {
        self.skills = skills.sorted { $0.name < $1.name }
    }

    /// The menu for these skills, as `SkillLibrary.skills()` lists them.
    public init(skills: [Skill]) {
        self.init(skills: skills.compactMap(Self.command(for:)))
    }

    /// The app's commands only, for the incognito window.
    public static let builtInOnly = SlashCommandMenu()

    /// The command a skill gives, or nil when it is off, broken, not for the owner, or its
    /// name belongs to one of the app's commands.
    public static func command(for skill: Skill) -> SkillCommand? {
        guard skill.isAvailable, skill.isUserInvocable, builtInClash(for: skill.name) == nil else { return nil }
        return SkillCommand(
            name: skill.name, description: skill.description, folderName: skill.folderName, revision: skill.revision)
    }

    /// The app's command a skill's name collides with, if any.
    public static func builtInClash(for skillName: String) -> SlashCommand? {
        SlashCommand(rawValue: skillName.lowercased())
    }

    /// What Settings says about invoking a skill with a slash, or nil for a broken skill, whose
    /// problem is shown instead. `agentName` is the agent's name from `AgentNameSetting`.
    public static func commandStatus(for skill: Skill, agentName: String = AgentNameSetting.defaultName) -> String? {
        guard skill.problem == nil else { return nil }
        let slashName = "/" + skill.name
        if !skill.isUserInvocable {
            return "Not offered as a slash command. Its SKILL.md has \(SkillDocument.userInvocableKey): false, so only \(AgentNameSetting.resolve(agentName)) uses it."
        }
        if let clash = builtInClash(for: skill.name) {
            return "Not offered as a slash command, because \(clash.name) is one of the app's own commands. Rename the skill to invoke it with a slash."
        }
        if !skill.isEnabled {
            return "Offered as \(slashName) in the panel once it is on."
        }
        return "Type \(slashName) in the panel to use it, followed by what to use it on."
    }

    /// Every command, the app's first.
    public var items: [SlashCommandItem] {
        SlashCommand.allCases.map(SlashCommandItem.builtIn) + skills.map(SlashCommandItem.skill)
    }

    /// The commands to list for what the owner has typed so far.
    /// - Before any space: every command whose name starts with the typed name, ignoring case.
    ///   Just a slash lists them all. Characters a name cannot have, such as a second slash in
    ///   `/usr/`, list nothing.
    /// - After a space: the one skill whose name was typed in full, while its text is typed.
    ///   The app's commands take no text, so they are not listed then.
    public func suggestions(for text: String) -> [SlashCommandItem] {
        guard text.hasPrefix("/") else { return [] }
        let afterSlash = text.dropFirst()
        if let space = afterSlash.firstIndex(where: \.isWhitespace) {
            let typed = afterSlash[..<space].lowercased()
            return skills.first { $0.name == typed }.map { [.skill($0)] } ?? []
        }
        let typed = afterSlash.lowercased()
        guard typed.allSatisfy({ Self.isNameCharacter($0) }) else { return [] }
        return items.filter { $0.name.dropFirst().hasPrefix(typed) }
    }

    /// What a message is when the owner sends it.
    public enum Parsed: Sendable, Equatable {
        /// One of the app's commands, which the app handles itself.
        case builtIn(SlashCommand)
        /// A skill, with the rest of the message as its text, which may be empty.
        case skill(SkillCommand, text: String)
    }

    /// The command a message is, or nil when it goes to the model as it is. An app's command
    /// has to be the whole message. A skill is its name after a slash, then optionally a
    /// space and its text, which can run over several lines.
    public func parse(_ text: String) -> Parsed? {
        if let command = SlashCommand.parse(text) { return .builtIn(command) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let afterSlash = trimmed.dropFirst()
        let end = afterSlash.firstIndex(where: \.isWhitespace) ?? afterSlash.endIndex
        let name = afterSlash[..<end].lowercased()
        guard let skill = skills.first(where: { $0.name == name }) else { return nil }
        let rest = afterSlash[end...].trimmingCharacters(in: .whitespacesAndNewlines)
        return .skill(skill, text: rest)
    }

    static func isNameCharacter(_ character: Character) -> Bool {
        ("a"..."z").contains(character) || ("0"..."9").contains(character) || character == "-"
    }

    // MARK: - What changed

    /// The skill commands in `after` that are new or changed since `before`, for the notice
    /// shown when the agent has added or edited a skill.
    public static func changes(from before: SlashCommandMenu, to after: SlashCommandMenu) -> SkillCommandChanges {
        let earlier = Dictionary(before.skills.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var changes = SkillCommandChanges()
        for command in after.skills {
            if let previous = earlier[command.name] {
                if previous != command { changes.changed.append(command) }
            } else {
                changes.added.append(command)
            }
        }
        return changes
    }
}

/// Skill commands that appeared or changed during a task.
public struct SkillCommandChanges: Sendable, Equatable {
    public var added: [SkillCommand] = []
    public var changed: [SkillCommand] = []

    public init(added: [SkillCommand] = [], changed: [SkillCommand] = []) {
        self.added = added
        self.changed = changed
    }

    public var isEmpty: Bool { added.isEmpty && changed.isEmpty }

    /// The one line shown by the text field, such as "/rename-photos is ready to use.", or nil
    /// when nothing changed.
    public var notice: String? {
        var sentences: [String] = []
        if !added.isEmpty {
            sentences.append("\(Self.list(added)) \(added.count == 1 ? "is" : "are") ready to use.")
        }
        if !changed.isEmpty {
            sentences.append("\(Self.list(changed)) \(changed.count == 1 ? "is" : "are") updated.")
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    private static func list(_ commands: [SkillCommand]) -> String {
        let names = commands.map(\.slashName)
        switch names.count {
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + ", and " + names.last!
        }
    }
}

// MARK: - Invoking a skill

extension ThreadItem.SkillInvocation {
    /// The message the model is sent when the owner invokes a skill: the line they typed, then
    /// a short note from the app and the skill's instructions between `<skill>` tags. It comes
    /// in the new message, so the request before it stays exactly as it was and the prompt
    /// cache holds, and the agent needs no `load_skill` call for it.
    public static func make(typed: String, skill: Skill, document: SkillDocument) -> ThreadItem.SkillInvocation {
        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = document.name
        let afterName = typed.dropFirst(name.count + 1).trimmingCharacters(in: .whitespacesAndNewlines)
        let input = afterName.isEmpty
            ? "They gave no text after it, so use the skill as it stands, and ask only when it needs something they did not give."
            : "The text after /\(name) is what to use it on."
        let message = """
            \(typed)

            The app added what follows. The person typed only the line above, invoking the \(name) skill. \
            \(input) Follow the skill's instructions below. They are already loaded, so do not call \
            \(LoadSkillTool.name) for it.

            <skill name="\(name)">
            \(LoadSkillTool.instructions(skill: skill, document: document))
            </skill>
            """
        return ThreadItem.SkillInvocation(name: name, message: message)
    }
}

extension SkillLibrary {
    /// Reads a skill's `SKILL.md` as it is now and makes the message for invoking it.
    public func invocation(typed: String, command: SkillCommand) -> Result<ThreadItem.SkillInvocation, LoadError> {
        load(named: command.name).map { skill, document in
            ThreadItem.SkillInvocation.make(typed: typed, skill: skill, document: document)
        }
    }
}
