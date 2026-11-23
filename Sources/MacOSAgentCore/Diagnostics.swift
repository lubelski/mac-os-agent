import CryptoKit
import Foundation
import Security
import Synchronization

/// A short fingerprint of what forms the cached prefix of every request: the instructions and
/// the tool list. When it changes between requests, the prompt cache starts over.
public enum PromptFingerprint {
    public static func make(instructions: String, tools: [ToolDefinition]) -> String {
        var text = instructions + "\n"
        for tool in tools {
            text += tool.name + "\n" + tool.description + "\n" + tool.parameters.encodedString() + "\n"
        }
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}

/// The assembled prompt as Debugging shows it.
public struct PromptInfo: Sendable, Equatable {
    /// Characters in the instructions as they would be sent now.
    public var characters: Int
    /// The fingerprint of the instructions and tools as they would be sent now.
    public var fingerprint: String
    /// The fingerprint of the most recent request in the usage log, if it recorded one.
    public var lastSentFingerprint: String?
    /// When the most recent requests' fingerprint was first seen in an unbroken run of requests.
    public var unchangedSince: Date?

    public init(instructions: String, tools: [ToolDefinition], records: [UsageRecord]) {
        characters = instructions.count
        fingerprint = PromptFingerprint.make(instructions: instructions, tools: tools)
        let withPrompt = records.filter { $0.prompt != nil }
        lastSentFingerprint = withPrompt.last?.prompt
        unchangedSince = nil
        if let last = lastSentFingerprint {
            for record in withPrompt.reversed() {
                guard record.prompt == last else { break }
                unchangedSince = record.date
            }
        }
    }

    /// True when the next request will send a different prompt from the last one, so the
    /// cache will start over.
    public var changedSinceLastRequest: Bool {
        lastSentFingerprint.map { $0 != fingerprint } ?? false
    }
}

/// The thread file's size and length, without reading what it says.
public struct ThreadFileInfo: Sendable, Equatable {
    public var path: String
    public var exists: Bool
    public var bytes: Int
    /// Lines in the file. Each line is one entry.
    public var entries: Int
    public var modified: Date?

    public static func read(_ url: URL) -> ThreadFileInfo {
        let path = url.plainPath
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let data = (try? Data(contentsOf: url, options: .mappedIfSafe)) ?? Data()
        return ThreadFileInfo(
            path: path,
            exists: attributes != nil,
            bytes: (attributes?[.size] as? NSNumber)?.intValue ?? 0,
            entries: data.split(separator: 0x0A, omittingEmptySubsequences: true).count,
            modified: attributes?[.modificationDate] as? Date)
    }
}

/// The state of the ChatGPT sign-in, for diagnosis. It never holds a token or the client id.
public struct SignInStatus: Sendable, Equatable {
    public var isSignedIn: Bool
    /// When the access token in memory expires. Nil until the first request after launch.
    public var accessTokenExpires: Date?
    /// When a token was last received, by signing in or refreshing.
    public var lastTokenDate: Date?
    public var lastErrorDate: Date?
    public var lastError: String?

    public init(
        isSignedIn: Bool, accessTokenExpires: Date? = nil, lastTokenDate: Date? = nil,
        lastErrorDate: Date? = nil, lastError: String? = nil
    ) {
        self.isSignedIn = isSignedIn
        self.accessTokenExpires = accessTokenExpires
        self.lastTokenDate = lastTokenDate
        self.lastErrorDate = lastErrorDate
        self.lastError = lastError
    }
}

/// The app's version, build, commit, and code signature.
public struct BuildInfo: Sendable, Equatable {
    public var version: String
    public var build: String
    public var commit: String
    public var signing: String

    public init(version: String, build: String, commit: String, signing: String) {
        self.version = version
        self.build = build
        self.commit = commit
        self.signing = signing
    }

    /// Reads the bundle's Info.plist and code signature. `scripts/bundle.sh` writes the commit
    /// into the `MacOSAgentGitCommit` key.
    public static func current(bundle: Bundle = .main) -> BuildInfo {
        let info = bundle.infoDictionary ?? [:]
        return BuildInfo(
            version: info["CFBundleShortVersionString"] as? String ?? "unknown",
            build: info["CFBundleVersion"] as? String ?? "unknown",
            commit: info["MacOSAgentGitCommit"] as? String ?? "unknown",
            signing: signing(of: bundle.bundleURL))
    }

    static func signing(of url: URL) -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            return describeSigning(isSigned: false, isAdHoc: false, teamID: nil)
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any]
        else {
            return describeSigning(isSigned: false, isAdHoc: false, teamID: nil)
        }
        let flags = (dictionary[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let isSigned = dictionary[kSecCodeInfoIdentifier as String] != nil
        return describeSigning(
            isSigned: isSigned,
            isAdHoc: flags & SecCodeSignatureFlags.adhoc.rawValue != 0,
            teamID: dictionary[kSecCodeInfoTeamIdentifier as String] as? String)
    }

    /// How the app is signed, in words.
    public static func describeSigning(isSigned: Bool, isAdHoc: Bool, teamID: String?) -> String {
        if !isSigned { return "Not signed" }
        if isAdHoc {
            return "Signed ad hoc, so macOS may ask again for permission access after each build"
        }
        if let teamID { return "Signed by team \(teamID)" }
        return "Signed"
    }
}

/// A problem the app ran into, such as a failed request.
public struct DiagnosticProblem: Sendable, Equatable, Identifiable {
    public var id: Int
    public var date: Date
    /// Where it happened, such as "Request" or "Sign-in".
    public var area: String
    public var message: String
}

/// The most recent problems since launch, kept in memory only.
public final class ProblemLog: Sendable {
    public static let limit = 20
    /// The longest message kept.
    public static let messageLimit = 400
    private let state = Mutex<(next: Int, problems: [DiagnosticProblem])>((0, []))

    public init() {}

    public func record(_ area: String, _ message: String, date: Date = Date()) {
        var message = AgentInstructions.singleLine(message)
        if message.count > Self.messageLimit { message = String(message.prefix(Self.messageLimit)) + "…" }
        state.withLock { state in
            state.problems.append(DiagnosticProblem(id: state.next, date: date, area: area, message: message))
            state.next += 1
            if state.problems.count > Self.limit { state.problems.removeFirst(state.problems.count - Self.limit) }
        }
    }

    /// Newest first.
    public var problems: [DiagnosticProblem] {
        state.withLock { $0.problems.reversed() }
    }
}

/// How big memory is: the sizes of core and the block, and how many topic files there are.
/// Never what any of it says.
public struct MemoryCounts: Sendable, Equatable {
    public var coreCharacters: Int
    public var topicFiles: Int
    public var archivedFiles: Int
    /// The block at the end of the instructions, in characters.
    public var blockCharacters: Int
    public var journalEntries: Int

    public init(coreCharacters: Int = 0, topicFiles: Int = 0, archivedFiles: Int = 0, blockCharacters: Int = 0, journalEntries: Int = 0) {
        self.coreCharacters = coreCharacters
        self.topicFiles = topicFiles
        self.archivedFiles = archivedFiles
        self.blockCharacters = blockCharacters
        self.journalEntries = journalEntries
    }

    /// The counts for this memory folder, with the block as the next request sends it.
    public init(_ library: MemoryLibrary, block: MemoryBlock.Contents?) {
        self.init(
            coreCharacters: library.core().characters, topicFiles: library.topics().count,
            archivedFiles: library.archived().count, blockCharacters: block?.characters ?? 0,
            journalEntries: library.journal.entries().count)
    }
}

public struct SkillCounts: Sendable, Equatable {
    public var total: Int
    /// On and without problems, so listed in the instructions.
    public var on: Int
    public var withProblems: Int
}

/// Everything the Debugging section shows, and the plain text that Copy Diagnostics puts on
/// the clipboard. It is built from counts, dates, paths, and error messages only. It holds no
/// message content and no secrets.
public struct DiagnosticsReport: Sendable, Equatable {
    public var date: Date
    public var build: BuildInfo
    public var system: String
    public var dataFolder: String
    public var model: String
    public var signIn: SignInStatus?
    /// Where this run keeps the sign-in, the Keychain or the file, and why.
    public var secretStorage: SecretStorage.Status?
    public var prompt: PromptInfo
    public var tools: Int
    public var skills: SkillCounts
    public var memories: MemoryCounts
    public var thread: ThreadFileInfo
    public var recentRequests: [UsageRecord]
    public var today: UsageTotals
    public var problems: [DiagnosticProblem]

    public static let recentRequestLimit = 20

    public init(
        date: Date = Date(), build: BuildInfo, system: String = ProcessInfo.processInfo.operatingSystemVersionString,
        dataFolder: URL, model: String, signIn: SignInStatus?, instructions: String, tools: [ToolDefinition],
        skills: [Skill], memories: MemoryCounts = MemoryCounts(), threadFile: URL, usageLog: UsageLog,
        problems: [DiagnosticProblem], secretStorage: SecretStorage.Status? = nil, calendar: Calendar = .current
    ) {
        self.date = date
        self.build = build
        self.system = system
        self.dataFolder = dataFolder.plainPath
        self.model = model
        self.signIn = signIn
        self.secretStorage = secretStorage
        let records = usageLog.records()
        prompt = PromptInfo(instructions: instructions, tools: tools, records: records)
        self.tools = tools.count
        self.skills = SkillCounts(
            total: skills.count, on: skills.filter(\.isAvailable).count,
            withProblems: skills.filter { $0.problem != nil }.count)
        self.memories = memories
        thread = ThreadFileInfo.read(threadFile)
        recentRequests = Array(records.suffix(Self.recentRequestLimit).reversed())
        var today = UsageTotals()
        for record in records where calendar.isDate(record.date, inSameDayAs: date) { today.add(record) }
        self.today = today
        self.problems = problems
    }

    /// The report as plain text, for pasting into an issue or a message.
    public func plainText() -> String {
        func time(_ date: Date?) -> String {
            date.map { $0.formatted(.iso8601) } ?? "none"
        }
        func percent(_ share: Double) -> String { "\(Int((share * 100).rounded()))%" }
        var lines: [String] = []
        lines.append("mac-os-agent diagnostics, \(time(date))")
        lines.append("")
        lines.append("Build")
        lines.append("- Version: \(build.version) (\(build.build)), commit \(build.commit)")
        lines.append("- Signing: \(build.signing)")
        lines.append("- System: \(system)")
        lines.append("- Data folder: \(dataFolder)")
        lines.append("")
        lines.append("Sign-in")
        if let signIn {
            lines.append("- Signed in: \(signIn.isSignedIn ? "yes" : "no")")
            lines.append("- Access token expires: \(time(signIn.accessTokenExpires))")
            lines.append("- Last token received: \(time(signIn.lastTokenDate))")
            if let error = signIn.lastError {
                lines.append("- Last error, \(time(signIn.lastErrorDate)): \(error)")
            } else {
                lines.append("- Last error: none")
            }
        } else {
            lines.append("- Not available")
        }
        if let secretStorage {
            lines.append("- Kept in: \(secretStorage.place). \(secretStorage.explanation)")
        }
        lines.append("")
        lines.append("Prompt")
        lines.append("- Model: \(model)")
        lines.append("- Instructions: \(prompt.characters) characters, fingerprint \(prompt.fingerprint)")
        lines.append("- Last request's fingerprint: \(prompt.lastSentFingerprint ?? "not recorded"), unchanged since \(time(prompt.unchangedSince))")
        lines.append("- Changed since the last request: \(prompt.changedSinceLastRequest ? "yes" : "no")")
        lines.append("- Tools: \(tools)")
        lines.append("- Skills: \(skills.total), \(skills.on) on, \(skills.withProblems) with problems")
        lines.append("- Memory: core \(memories.coreCharacters) characters, \(memories.topicFiles) topic files, \(memories.archivedFiles) archived, block \(memories.blockCharacters) characters, \(memories.journalEntries) journal entries")
        lines.append("")
        lines.append("Thread")
        lines.append("- File: \(thread.path)")
        lines.append(thread.exists
            ? "- \(thread.entries) entries, \(thread.bytes) bytes, modified \(time(thread.modified))"
            : "- The file does not exist yet")
        lines.append("")
        lines.append("Model requests")
        lines.append("- Today: \(today.requests) requests, \(today.input) in, \(percent(today.cachedShare)) cached, \(today.output) out, \(today.reasoning) reasoning")
        for record in recentRequests {
            var line = "- \(time(record.date)) \(record.model): \(record.input) in, \(percent(record.usage.cachedShare)) cached, \(record.output) out"
            if let reasoning = record.reasoning { line += ", \(reasoning) reasoning" }
            if let seconds = record.seconds { line += ", \(seconds) s" }
            if let prompt = record.prompt { line += ", prompt \(prompt)" }
            lines.append(line)
        }
        lines.append("")
        lines.append("Problems since launch")
        if problems.isEmpty { lines.append("- None") }
        for problem in problems {
            lines.append("- \(time(problem.date)) \(problem.area): \(problem.message)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
