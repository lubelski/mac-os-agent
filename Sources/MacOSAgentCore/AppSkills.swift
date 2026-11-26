import Foundation

/// Skills that are part of the app. They are listed to the agent beside the owner's skills and
/// load with `load_skill` the same way, but they are not folders in the skills folder, so
/// nothing done there can change, turn off, or replace one. A folder skill with the same name
/// is listed in Settings with a problem and is not used.
///
/// Not to be confused with the app's own slash commands, `SlashCommand`, which the app handles
/// itself and never sends to the model.
///
/// Each is written as the text of a `SKILL.md`, so it parses with `SkillDocument` like any
/// other skill. The name and description are in the instructions at the head of every request,
/// so they must never change from launch to launch. The body is read only when the skill is
/// loaded, and `AppSkillContext` adds the app's and macOS's versions to it then.
public enum AppSkills {
    /// The prefix of an app skill's `Skill.id`. A skill name cannot have a dot, so the id never
    /// matches the folder name of a working skill.
    public static let idPrefix = "app."

    public static let fileIssueAboutThisAppName = "file-issue-about-this-app"

    /// Each app skill's `SKILL.md` text, sorted by name.
    static let files: [String] = [
        """
        ---
        name: \(fileIssueAboutThisAppName)
        description: File a bug or a request about this app, mac-os-agent, as a public GitHub issue that the person reads and submits. Use when they ask to report a problem with the app, ask for a change to it, or file an issue about it.
        ---

        Use this when the person wants to report a bug in this app or ask for a change to it. \
        Issues go to the public repository lubelski/mac-os-agent on GitHub. You do not file the \
        issue. You open GitHub's new issue page with it filled in, and the person reads it and \
        presses Submit.

        ## Steps

        1. Work out the one request. If the person raised more than one, make an issue for each, \
        and say so.
        2. Write a title and a body, as below.
        3. Tell the person in one sentence that the issue will be public on GitHub, where anyone \
        can read it, and that they can change it on the page before they press Submit.
        4. Build the link and open it with open_item.
        5. Say the page is open, and that nothing is filed until they press Submit.

        ## The title and body

        - The title names the problem or the request in a few words, in terms of what the person \
        sees in the app, such as "The panel forgets its size after a restart".
        - The body says what happens now, and what done looks like: what the person would see \
        once it is fixed or built. For a bug, add the steps that make it happen, if they are known.
        - One request per issue.
        - Do not say how to build or fix it. Do not name code, the app's files, or a design. The \
        issue is the problem and the result wanted.
        - End the body with the two versions under "This Mac" below.

        ## What stays out

        The issue is public. Put in it only the request itself, written fresh in your own words. \
        Leave out everything else from the conversation and the Mac, even when it would help:

        - file paths, folder names, and the names of files, apps, people, or accounts,
        - anything the person wrote, quoted or paraphrased, beyond the request,
        - memory, skills, earlier episodes, and tool output, including error text that holds any \
        of the above.

        The app's version and the macOS version are fine. If the request cannot be stated \
        without private detail, put it in general terms, and tell the person what you left out \
        so they can add it on the page themselves if they want to.

        ## The link

        https://github.com/lubelski/mac-os-agent/issues/new?title=TITLE&body=BODY

        - Percent-encode the title and the body. Leave letters, digits, and - . _ ~ as they are, \
        and encode every other character as its UTF-8 bytes, such as %20 for a space, %0A for a \
        new line, %26 for &, %23 for #, and %3D for =.
        - Keep the body to 1,500 characters before encoding, and the whole link under 6,000 \
        characters after. A longer link can be cut off or refused.
        - When the report is longer, shorten it to the problem and what done looks like. If it is \
        long because it holds more than one request, make one issue for each. Tell the person \
        what you cut, so they can add it on the page before they press Submit.

        ## Never

        - Never file the issue yourself: not with the shell, gh, curl, git, or an API, and not \
        with any token, key, or sign-in stored on the Mac.
        - Never submit the page for the person.
        """,
    ]

    /// The app skills as Settings and the instructions list them, in name order.
    public static let skills: [Skill] = files.compactMap { text in
        guard let document = try? SkillDocument.parse(text) else { return nil }
        return Skill(
            folderName: document.name, folderURL: nil, name: document.name, description: document.description,
            isEnabled: true, problem: nil, isUserInvocable: document.isUserInvocable,
            revision: SkillLibrary.revision(of: text), isPartOfApp: true)
    }

    public static var names: Set<String> { Set(skills.map(\.name)) }

    /// The app skill with this name, or nil.
    public static func skill(named name: String) -> Skill? {
        skills.first { $0.name == name }
    }

    /// The app skill's document, with the versions from `context` at the end of its body.
    public static func document(named name: String, context: AppSkillContext) -> SkillDocument? {
        guard let text = files.first(where: { (try? SkillDocument.parse($0))?.name == name }),
              var document = try? SkillDocument.parse(text)
        else { return nil }
        document.body += "\n\n" + context.section
        return document
    }
}

/// What an app skill is told about the app and the Mac when it is loaded. It goes in the skill's
/// text, which the agent reads in a tool result or an invoked skill's message, never in the
/// instructions, so it does not touch the start of a request.
public struct AppSkillContext: Sendable, Equatable {
    /// The app's version, or nil for a build that has none, such as one from `swift build`.
    public var appVersion: String?
    /// The macOS version, as `ProcessInfo` gives it, such as "Version 27.2 (Build 25C56)".
    public var macOSVersion: String

    public init(appVersion: String?, macOSVersion: String) {
        self.appVersion = appVersion
        self.macOSVersion = macOSVersion
    }

    /// The running app's.
    public static var current: AppSkillContext {
        AppSkillContext(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString)
    }

    var section: String {
        let app = appVersion.map { "mac-os-agent \($0)" } ?? "mac-os-agent, a development build with no version number"
        return """
            ## This Mac

            - App: \(app)
            - macOS: \(macOSVersion)
            """
    }
}
