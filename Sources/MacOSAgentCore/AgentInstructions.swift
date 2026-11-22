import Foundation

/// The instructions sent at the head of every request, in two parts.
///
/// - The editable part is the person's to change in Settings. `defaultEditable` is what it
///   holds until they do.
/// - The fixed part always follows it. It states what the app depends on to work correctly:
///   how the go-ahead for destructive commands works, the time at the start of each message,
///   and how skills are found and loaded. No edit can remove it.
///
/// The assembled text is the first thing in every request, so it has to come out byte for
/// byte the same when nothing changed, or the prompt cache is lost. Nothing in it depends on
/// the time, and skills are listed in a fixed order.
public enum AgentInstructions {
    public static let defaultEditable = """
        You are mac-os-agent, an agent that lives in the menu bar of the person's Mac. They summon \
        you with a hotkey and type short instructions such as "change the wallpaper to a sunset" or \
        "delete zoom". You act on the Mac for them.

        How to work:
        - Do the task. Use the run_shell_command tool to inspect and change the system: shell \
        commands, osascript for AppleScript and JavaScript for Automation, open, defaults, \
        mdfind, and the other tools macOS ships with.
        - For apps, use the app tools instead of the shell. search_applications finds an installed \
        app from a loose name, open_application opens it or brings it to the front, and \
        list_running_applications says what is running. When a search finds nothing, say so. Do \
        not open a website instead unless the person asked for one.
        - Look before you change things. Find the exact app, file, or setting first, then act on it.
        - Prefer moving files to the Trash over deleting them outright.
        - Keep replies short. The panel is small. Say what you did or what you found in a sentence \
        or two. Do not use Markdown headings or tables.
        - Ask a question only when the instruction is ambiguous in a way that matters.
        """

    /// A skill as the instructions list it.
    public struct SkillSummary: Sendable, Equatable {
        public var name: String
        public var description: String

        public init(name: String, description: String) {
            self.name = name
            self.description = description
        }
    }

    /// The part the app always sends after the editable part.
    public static func fixed(skills: [SkillSummary], skillsFolder: URL) -> String {
        let folder = skillsFolder.plainPath
        let list = skills.isEmpty
            ? "There are no skills yet."
            : "Skills you have:\n" + skills
                .sorted { $0.name < $1.name }
                .map { "- \($0.name): \(singleLine($0.description))" }
                .joined(separator: "\n")
        return """
            How this app works. These rules come from the app and hold whatever the text above says.
            - Some commands wait for the person's go-ahead in the panel before they run. Set \
            destructive to true on run_shell_command for any command that deletes, overwrites, \
            uninstalls, quits apps, or changes something that is hard to undo. The app also asks on \
            its own for commands that look destructive. If the person declines, do not try to reach \
            the same result another way. Say what you would have done.
            - This is one long conversation that continues every time the person summons you. The app \
            starts each of their messages with the local time it was sent, in square brackets. The \
            time is not part of what they typed.
            - Skills are instructions for particular tasks. When a task matches one of the skills \
            listed below, call \(LoadSkillTool.name) with its name before you start, and follow it.
            - Each skill is a folder in \(folder) holding a SKILL.md file, and sometimes scripts or \
            other files beside it. SKILL.md starts with front matter between two lines of three \
            dashes, with a name line and a description line, followed by the instructions. The name \
            is lowercase letters, digits, and hyphens, the same as the folder's name. The description \
            says what the skill does and when to use it, in one line.
            - You can write new skills and improve existing ones with the shell tool. That is how you \
            extend what you can do. Write one when the person asks, or when you have worked out a \
            task they are likely to ask for again. New and changed skills are listed from their next \
            message on.

            \(list)
            """
    }

    /// The instructions for one request: the editable text, then the fixed part.
    public static func assemble(editable: String, skills: [SkillSummary], skillsFolder: URL) -> String {
        let editable = editable.trimmingCharacters(in: .whitespacesAndNewlines)
        let fixed = fixed(skills: skills, skillsFolder: skillsFolder)
        return editable.isEmpty ? fixed : editable + "\n\n" + fixed
    }

    /// The default instructions with no skills, for when nothing has been set up.
    public static var defaultPrompt: String {
        assemble(editable: defaultEditable, skills: [], skillsFolder: AgentPaths.skillsFolder)
    }

    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// The editable instructions, kept as a file in Application Support. Until the person edits
/// them there is no file, and the default applies.
public struct InstructionsStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = AgentPaths.instructionsFile) {
        self.fileURL = fileURL
    }

    /// The editable instructions: the file's text exactly as saved, or the default.
    public func load() -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? AgentInstructions.defaultEditable
    }

    /// True when the person has saved instructions of their own.
    public var isCustomized: Bool {
        FileManager.default.fileExists(atPath: fileURL.plainPath)
    }

    /// Saves the text exactly as given. Saving the default text removes the file instead, so a
    /// later change to the default reaches people who never changed it.
    public func save(_ text: String) throws {
        if text == AgentInstructions.defaultEditable {
            try restoreDefault()
            return
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: fileURL, options: .atomic)
    }

    public func restoreDefault() throws {
        guard isCustomized else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

/// Puts together the instructions for a request from the files in Application Support.
public struct AgentPrompt: Sendable {
    public var instructions: InstructionsStore
    public var skills: SkillLibrary

    public init(instructions: InstructionsStore = InstructionsStore(), skills: SkillLibrary = SkillLibrary()) {
        self.instructions = instructions
        self.skills = skills
    }

    /// The full instructions as they stand now.
    public func current() -> String {
        AgentInstructions.assemble(
            editable: instructions.load(),
            skills: skills.skills().filter(\.isAvailable).map { .init(name: $0.name, description: $0.description) },
            skillsFolder: skills.folder)
    }
}
