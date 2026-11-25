import AppKit
import MacOSAgentCore
import Observation
import SwiftUI

/// What Debugging shows, read again each time the window comes forward. Everything in it is
/// counts, dates, paths, and error messages. It never holds message content or a secret.
@MainActor
@Observable
final class DebuggingSettingsModel {
    private(set) var report: DiagnosticsReport?
    @ObservationIgnored let prompt: AgentPrompt
    @ObservationIgnored let usageLog: UsageLog
    @ObservationIgnored let tools: ToolRegistry
    @ObservationIgnored let problems: ProblemLog
    @ObservationIgnored let signInStatus: @Sendable () async -> SignInStatus?
    /// Where this run keeps the sign-in. Decided once at launch.
    @ObservationIgnored let secretStorage: SecretStorage.Status?
    /// `.gateway` in a development build, which has no sign-in. Decided once at launch.
    @ObservationIgnored let modelAccess: ModelAccess
    /// The web search this run launched with, and the Brave key's store. Only whether a key
    /// is set is shown, never the key.
    @ObservationIgnored let webSearch: WebSearchContext
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private var loading: Task<Void, Never>?
    /// A part to scroll to when the section appears, such as "sign-in". Used by previews.
    @ObservationIgnored var scrollTarget: String?

    init(
        prompt: AgentPrompt, usageLog: UsageLog, tools: ToolRegistry, problems: ProblemLog,
        signInStatus: @escaping @Sendable () async -> SignInStatus?, secretStorage: SecretStorage.Status?,
        modelAccess: ModelAccess = .signIn, webSearch: WebSearchContext, defaults: UserDefaults
    ) {
        self.prompt = prompt
        self.usageLog = usageLog
        self.tools = tools
        self.problems = problems
        self.signInStatus = signInStatus
        self.secretStorage = secretStorage
        self.modelAccess = modelAccess
        self.webSearch = webSearch
        self.defaults = defaults
    }

    func reload() {
        loading?.cancel()
        loading = Task {
            let signIn = await signInStatus()
            guard !Task.isCancelled else { return }
            report = DiagnosticsReport(
                build: BuildInfo.current(),
                dataFolder: AgentPaths.applicationSupport,
                model: ModelSetting.current(defaults),
                signIn: signIn,
                instructions: prompt.currentAsNextSent(),
                tools: tools.definitions,
                skills: prompt.skills.skills(),
                memories: prompt.memories.map { MemoryCounts($0, block: prompt.latestMemoryContents()) } ?? MemoryCounts(),
                threadFile: AgentPaths.threadFile,
                usageLog: usageLog,
                problems: problems.problems,
                secretStorage: secretStorage,
                webSearch: webSearch.status(defaults),
                modelAccess: modelAccess)
        }
    }

    func copyDiagnostics() {
        guard let report else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.plainText(), forType: .string)
    }

    func showDataFolder() {
        let folder = AgentPaths.applicationSupport
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    func showThreadFile() {
        let file = AgentPaths.threadFile
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            showDataFolder()
        }
    }
}

struct DebuggingSettingsView: View {
    let model: DebuggingSettingsModel
    let instructions: InstructionsSettingsModel
    @State private var showingFullPrompt = false
    @State private var copied = false

    var body: some View {
        Group {
            if let report = model.report {
                form(report)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { model.reload() }
        .sheet(isPresented: $showingFullPrompt) {
            // The memory block is private, so it is shown only as its count and size.
            FullPromptView(text: model.prompt.currentForDisplay())
        }
    }

    private func form(_ report: DiagnosticsReport) -> some View {
        ScrollViewReader { proxy in
            sections(report)
                .task {
                    try? await Task.sleep(for: .milliseconds(100))
                    if let target = model.scrollTarget { proxy.scrollTo(target, anchor: .top) }
                }
        }
    }

    private func sections(_ report: DiagnosticsReport) -> some View {
        Form {
            Section {
                HStack {
                    Text("For finding out why something went wrong. Copy Diagnostics leaves out messages and secrets.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(copied ? "Copied" : "Copy Diagnostics") {
                        model.copyDiagnostics()
                        copied = true
                    }
                    Button("Show Data Folder") { model.showDataFolder() }
                }
            }
            Section("Model requests") {
                LabeledContent("Today", value: Self.totals(report.today))
                if report.recentRequests.isEmpty {
                    Text("No requests yet.").foregroundStyle(.secondary)
                } else {
                    RequestTable(records: report.recentRequests)
                }
            }
            Section {
                LabeledContent("Model", value: report.model)
                LabeledContent("Instructions", value: "\(report.prompt.characters.formatted()) characters")
                LabeledContent("Fingerprint") {
                    Text(report.prompt.fingerprint).font(.body.monospaced()).textSelection(.enabled)
                }
                LabeledContent("Unchanged since", value: Self.time(report.prompt.unchangedSince, none: "Not recorded yet"))
                LabeledContent("Tools", value: "\(report.tools)")
                if let webSearch = report.webSearch {
                    LabeledContent("Web search", value: webSearch.text)
                }
                LabeledContent("Skills", value: "\(report.skills.total), \(report.skills.on) on, \(report.skills.withProblems) with problems")
                LabeledContent("Memory", value: "Core \(report.memories.coreCharacters.formatted()) characters, \(report.memories.topicFiles) topic files, block \(report.memories.blockCharacters.formatted()) characters")
                HStack {
                    Spacer()
                    Button("Show Full Prompt…") { showingFullPrompt = true }
                }
            } header: {
                Text("Prompt")
            } footer: {
                Text(report.prompt.changedSinceLastRequest
                     ? "The prompt has changed since the last request, so the next one starts the cache over."
                     : "The fingerprint covers the instructions and the tool list. When it changes, the prompt cache starts over.")
                    .foregroundStyle(.secondary)
            }
            if report.modelAccess == .gateway {
                Section {
                    LabeledContent("Models", value: "Through inference-gateway")
                    LabeledContent("Address", value: InferenceGateway.address())
                    if let storage = report.secretStorage {
                        LabeledContent("Other secrets kept in", value: storage.place)
                    }
                } header: {
                    Text("Models")
                } footer: {
                    Text("This is a development build. It has no sign-in of its own and sends every model request, to OpenAI and to Ollama, through inference-gateway, which adds the sign-in. Other secrets, such as a Brave Search key, stay in this build's store.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .id("sign-in")
            } else {
                Section {
                    if let signIn = report.signIn {
                        LabeledContent("Signed in", value: signIn.isSignedIn ? "Yes" : "No")
                        LabeledContent("Access token expires", value: Self.time(signIn.accessTokenExpires, none: "Not fetched since launch"))
                        LabeledContent("Last token received", value: Self.time(signIn.lastTokenDate, none: "Not since launch"))
                        LabeledContent("Last error") {
                            Text(signIn.lastError.map { "\($0) (\(Self.time(signIn.lastErrorDate)))" } ?? "None")
                                .multilineTextAlignment(.trailing)
                                .textSelection(.enabled)
                        }
                    } else {
                        Text("Not available.").foregroundStyle(.secondary)
                    }
                    if let storage = report.secretStorage {
                        LabeledContent("Kept in", value: storage.place)
                    }
                } header: {
                    Text("Sign-in")
                } footer: {
                    if let storage = report.secretStorage {
                        Text(storage.explanation)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .id("sign-in")
            }
            Section("Thread") {
                LabeledContent("File") {
                    Text(report.thread.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if report.thread.exists {
                    LabeledContent("Entries", value: report.thread.entries.formatted())
                    LabeledContent("Size", value: report.thread.bytes.formatted(.byteCount(style: .file)))
                    LabeledContent("Last written", value: Self.time(report.thread.modified))
                } else {
                    Text("The file does not exist yet.").foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Show in Finder") { model.showThreadFile() }
                }
            }
            .id("thread")
            Section("Problems since launch") {
                if report.problems.isEmpty {
                    Text("None.").foregroundStyle(.secondary)
                } else {
                    ForEach(report.problems) { problem in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(problem.area), \(Self.time(problem.date))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(problem.message).textSelection(.enabled)
                        }
                    }
                }
            }
            .id("problems")
            Section("Build") {
                LabeledContent("Version", value: "\(report.build.version) (\(report.build.build))")
                LabeledContent("Commit") {
                    Text(report.build.commit).font(.body.monospaced()).textSelection(.enabled)
                }
                LabeledContent("Signing") {
                    Text(report.build.signing).multilineTextAlignment(.trailing)
                }
                LabeledContent("System", value: report.system)
            }
            .id("build")
        }
        .formStyle(.grouped)
        .onChange(of: report.date) { copied = false }
    }

    static func time(_ date: Date?, none: String = "None") -> String {
        guard let date else { return none }
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .standard)
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func totals(_ totals: UsageTotals) -> String {
        guard totals.requests > 0 else { return "No requests yet" }
        let requests = totals.requests == 1 ? "1 request" : "\(totals.requests) requests"
        return "\(requests), \(totals.input.formatted()) in, \(percent(totals.cachedShare)) cached, \(totals.output.formatted()) out"
    }

    static func percent(_ share: Double) -> String {
        share.formatted(.percent.precision(.fractionLength(0)))
    }
}

/// The most recent model requests, newest first.
struct RequestTable: View {
    let records: [UsageRecord]

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
            GridRow {
                Text("Time").gridColumnAlignment(.leading)
                Text("Model").gridColumnAlignment(.leading)
                Text("Input")
                Text("Cached")
                Text("Output")
                Text("Reasoning")
                Text("Seconds")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Divider()
            ForEach(Array(records.enumerated()), id: \.offset) { _, record in
                GridRow {
                    Text(DebuggingSettingsView.time(record.date))
                    Text(record.model)
                    Text(record.input.formatted())
                    Text(DebuggingSettingsView.percent(record.usage.cachedShare))
                    Text(record.output.formatted())
                    Text(record.reasoning.map { $0.formatted() } ?? "")
                    Text(record.seconds.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "")
                }
                .monospacedDigit()
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
