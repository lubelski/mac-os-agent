import AppKit
import MacOSAgentCore
import Observation

/// The panel's instant actions: what the current draft would do on Return without the model,
/// if anything, and which of a few choices is chosen. See `InstantActionRule` for when a draft
/// counts.
///
/// Matching runs on the main thread on every change to the draft. Against a few hundred apps
/// it takes a fraction of a millisecond, so it never holds up typing, and because it runs in
/// step with the draft, a suggestion can never be left over from text that has since changed.
/// The list of apps is read off the main thread at launch and again each time the panel
/// shows, and the catalog re-reads only folders that changed.
///
/// The owner's saved actions are offered beside the apps, ranked by the same rule and learned
/// use. They are read from the actions folder, which is watched, so an action the agent saves
/// or the owner edits shows at once. The incognito window offers none, as it has no skills.
@MainActor
@Observable
final class InstantActions {
    /// What Return does for the current draft, or nil when it goes to the agent.
    private(set) var suggestion: InstantActionSuggestion?
    /// Which of the suggestion's choices Return takes.
    private(set) var selection = 0

    @ObservationIgnored private var engine: InstantActionEngine
    @ObservationIgnored private var draft = ""
    /// The draft the owner dismissed the suggestion for with Escape. It stays dismissed while
    /// they keep typing after it.
    @ObservationIgnored private var dismissedDraft: String?
    /// Nil keeps what is learned in memory only, for previews and tests.
    @ObservationIgnored private let store: InstantActionHistoryStore?
    @ObservationIgnored private var memoryHistory = InstantActionHistory()
    /// False for the incognito window, which learns nothing from what the owner opens.
    @ObservationIgnored let learns: Bool
    @ObservationIgnored private let catalog: ApplicationCatalog?
    @ObservationIgnored private let runningPaths: @MainActor () -> Set<String>
    /// Opens an app and brings it to the front. Tests stand in their own.
    @ObservationIgnored var openApplication: @MainActor (InstalledApplication) async throws -> Void
    @ObservationIgnored var clock: () -> Date = { Date() }
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// Where saved actions are read from. Nil offers none, as in the incognito window.
    @ObservationIgnored let actionLibrary: SavedActionLibrary?
    /// The saved actions that are on, as last read.
    @ObservationIgnored private(set) var actions: [SavedAction] = []
    @ObservationIgnored private var actionWatcher: FolderWatcher?
    @ObservationIgnored private var actionObserver: NSObjectProtocol?
    @ObservationIgnored private let summaries: ToolCallSummaries

    /// - Parameters:
    ///   - applications: the apps to match before the catalog has been read, or for good when
    ///     there is no catalog.
    ///   - catalog: where to read the installed apps from. Nil for a fixed list.
    ///   - store: where learned use is kept. Nil keeps it in memory.
    ///   - open: opens an app and brings it to the front.
    ///   - learns: false to learn nothing, for the incognito window.
    ///   - history: what was learned before, for a copy that ranks the same without a store.
    ///   - actionLibrary: where saved actions are read from. Nil offers none.
    ///   - watchesActions: false to read the actions only when asked, for previews and tests.
    init(
        applications: [InstalledApplication] = [],
        catalog: ApplicationCatalog? = nil,
        store: InstantActionHistoryStore? = nil,
        runningPaths: @escaping @MainActor () -> Set<String> = { [] },
        open: @escaping @MainActor (InstalledApplication) async throws -> Void = { _ in },
        learns: Bool = true,
        history: InstantActionHistory = InstantActionHistory(),
        actionLibrary: SavedActionLibrary? = nil,
        watchesActions: Bool = false,
        summaries: ToolCallSummaries = .builtIn
    ) {
        engine = InstantActionEngine(providers: [ApplicationInstantActions(applications: applications)])
        self.actionLibrary = actionLibrary
        self.summaries = summaries
        self.catalog = catalog
        self.store = store
        self.runningPaths = runningPaths
        openApplication = open
        self.learns = learns
        memoryHistory = history
        self.applications = applications
        guard let actionLibrary else { return }
        actions = actionLibrary.availableActions()
        rebuildEngine()
        guard watchesActions else { return }
        actionWatcher = FolderWatcher(folder: actionLibrary.folder) { [weak self] in self?.reloadActions() }
        actionObserver = NotificationCenter.default.addObserver(
            forName: SavedActionLibrary.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadActions() }
        }
    }

    isolated deinit {
        if let actionObserver { NotificationCenter.default.removeObserver(actionObserver) }
    }

    /// Reads the saved actions again. The suggestion follows at once.
    func reloadActions() {
        guard let actionLibrary else { return }
        // The folder may have been made since the last look, by the agent or in Settings.
        if actionWatcher?.isWatching == false { actionWatcher?.rearm() }
        let fresh = actionLibrary.availableActions()
        guard fresh != actions else { return }
        actions = fresh
        rebuildEngine()
        evaluate()
    }

    /// A fixed list of saved actions, for previews and tests, read from no folder.
    func setActions(_ actions: [SavedAction]) {
        offersFixedActions = true
        self.actions = actions
        rebuildEngine()
        evaluate()
    }

    @ObservationIgnored private var offersFixedActions = false

    /// Saved actions first, so an action the owner made wins a tie with an app.
    private func rebuildEngine() {
        var providers: [any InstantActionProvider] = []
        if actionLibrary != nil || offersFixedActions { providers.append(ActionInstantActions(actions: actions, summaries: summaries)) }
        providers.append(ApplicationInstantActions(applications: applications, runningPaths: runningPaths()))
        engine = InstantActionEngine(providers: providers)
    }

    /// The incognito window's instant actions: the same apps, ranked by what the main panel has
    /// learned as it stands now, with no store at all and learning turned off. Nothing taken
    /// here can reach `instant-actions.json`, or even this copy's memory. It offers no saved
    /// actions, since the window has no skills either.
    func incognitoCopy() -> InstantActions {
        let copy = InstantActions(
            applications: applications, catalog: catalog, store: nil, runningPaths: runningPaths,
            open: openApplication, learns: false, history: history)
        copy.clock = clock
        copy.refresh()
        return copy
    }

    /// The real thing: the installed apps, learned use in Application Support, and Launch Services.
    static func live(summaries: ToolCallSummaries = .builtIn) -> InstantActions {
        let catalog = ApplicationCatalog()
        let workspace = SystemApplicationWorkspace(catalog: catalog)
        let actions = InstantActions(
            catalog: catalog,
            store: InstantActionHistoryStore(fileURL: AgentPaths.instantActionHistoryFile),
            runningPaths: {
                Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path(percentEncoded: false) }
                    .map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 })
            },
            open: { application in _ = try await workspace.openApplication(at: application.url) },
            actionLibrary: SavedActionLibrary(), watchesActions: true, summaries: summaries)
        actions.refresh()
        return actions
    }

    var history: InstantActionHistory { store?.history ?? memoryHistory }

    /// Reads the installed apps again, off the main thread, and the saved actions. The catalog
    /// keeps each folder until it changes, so this is cheap after the first time.
    func refresh() {
        reloadActions()
        guard let catalog, refreshTask == nil else { return }
        refreshTask = Task {
            let applications = await Task.detached(priority: .userInitiated) { catalog.applications() }.value
            refreshTask = nil
            setApplications(applications)
        }
    }

    /// Waits for a refresh in flight, for tests.
    func waitForRefresh() async { await refreshTask?.value }

    /// The apps matched against, as last read.
    @ObservationIgnored private var applications: [InstalledApplication] = []

    func setApplications(_ applications: [InstalledApplication]) {
        self.applications = applications
        rebuildEngine()
        evaluate()
    }

    /// Called on every change to the draft.
    func draftChanged(_ draft: String) {
        self.draft = draft
        if let dismissed = dismissedDraft, draft.isEmpty || !draft.hasPrefix(dismissed) {
            dismissedDraft = nil
        }
        evaluate()
    }

    private func evaluate() {
        let next = dismissedDraft == nil ? engine.suggestion(for: draft, history: history, now: clock()) : nil
        if next?.choices.map(\.id) != suggestion?.choices.map(\.id) { selection = 0 }
        if next != suggestion { suggestion = next }
    }

    /// Up, Down, Tab, or Shift-Tab while there are choices. False when there is nothing to
    /// choose between, so the key does what it always does.
    func move(by offset: Int) -> Bool {
        guard let count = suggestion?.choices.count, count > 1 else { return false }
        selection = (selection + offset % count + count) % count
        return true
    }

    func choose(_ index: Int) {
        guard let count = suggestion?.choices.count, index >= 0, index < count else { return }
        selection = index
    }

    /// Escape. Hides the suggestion for this draft and returns true, or returns false when
    /// none is showing, so Escape goes on to close the inspector or hide the panel.
    func dismiss() -> Bool {
        guard suggestion != nil else { return false }
        dismissedDraft = draft
        suggestion = nil
        return true
    }

    /// Return. The chosen candidate for this exact draft, or nil when Return should send it to
    /// the agent. Its use is learned unless `learns` is false, as in the incognito window.
    /// What Return would take for this draft, without taking it or learning anything.
    func offered(for draft: String) -> InstantActionCandidate? {
        if draft != self.draft { draftChanged(draft) }
        guard let suggestion, suggestion.input == draft else { return nil }
        return suggestion.choices[min(selection, suggestion.choices.count - 1)]
    }

    func take(for draft: String) -> InstantActionCandidate? {
        if draft != self.draft { draftChanged(draft) }
        guard let suggestion, suggestion.input == draft else { return nil }
        let candidate = suggestion.choices[min(selection, suggestion.choices.count - 1)]
        if learns {
            if let store {
                store.record(candidate.id, subject: suggestion.phrase.key, at: clock())
            } else {
                memoryHistory.record(candidate.id, subject: suggestion.phrase.key, at: clock())
            }
        }
        return candidate
    }

    /// Opens an app. A saved action is run by the session, which keeps its record in the thread.
    func perform(_ candidate: InstantActionCandidate) async throws {
        switch candidate.target {
        case .application(let application):
            try await openApplication(application)
        case .action:
            break
        }
    }
}
