import AppKit
import MacOSAgentCore
import Observation

/// The state of one conversation window while it works: its history, the running task, and
/// the sign-in. The task belongs to this object, not to the window, so hiding the main panel
/// never stops it.
///
/// There are two kinds, one per window:
/// - The main panel's session runs on the kept thread. It keeps track of episodes: when the
///   panel comes up after the current episode has timed out, or after `/new`, it starts a
///   fresh page, and the owner's next message starts a new episode.
/// - The incognito window's session runs on a loop of its own over a store held only in
///   memory, with the incognito tools and instructions. It has no episode timeout. `/new` and
///   Clear start its conversation over, and closing the window drops the session and
///   everything in it.
@MainActor
@Observable
final class AgentSession {
    enum SignInState: Equatable {
        case signedOut
        case signingIn
        case signedIn
    }

    enum Kind: Equatable {
        /// The main panel, on the kept thread.
        case kept
        /// The incognito window, held in memory only.
        case incognito
    }

    /// What the owner asked to do with an incognito conversation.
    enum Discard: Equatable {
        /// Close the window, which discards the conversation.
        case close
        /// Discard the conversation and keep the window open on a fresh one.
        case clear
    }

    let kind: Kind
    /// The conversation's history.
    private(set) var transcript = Transcript()
    private(set) var streamingText = ""
    private(set) var isRunning = false
    private(set) var pendingConfirmation: ConfirmationRequest?
    private(set) var signInState: SignInState = .signedOut
    /// Changes every time the window is shown, so the text field takes focus again.
    private(set) var focusRequest = 0
    /// Changes each time an incognito conversation is discarded and started over, so the
    /// history and the inspector let go of the old one.
    private(set) var conversation = 0
    /// A close or clear asked for while a task runs, waiting for the owner to confirm it.
    private(set) var pendingDiscard: Discard?
    var draft = "" {
        didSet {
            instantActions.draftChanged(draft)
            if draft != oldValue { draftChangedForHint() }
            suggestionListFollowsDraft()
        }
    }
    /// The skills the main panel offers as slash commands, kept live. Nil in the incognito
    /// window, which has no skills, and where nothing set one up.
    var skillCommands: SkillCommandsModel?
    /// Which of the listed commands Return or Tab completes.
    private(set) var hintSelection = 0
    /// The draft the owner dismissed the command list for with Escape. It stays dismissed while
    /// they keep typing after it.
    private(set) var dismissedHintDraft: String?
    /// The skill commands as they were when the running task started, to tell afterwards which
    /// ones it added or changed.
    @ObservationIgnored private var menuAtTaskStart: SlashCommandMenu?
    /// The saved actions as they were when the running task started, to tell afterwards which
    /// ones it added or changed.
    @ObservationIgnored private var actionsAtTaskStart: [SavedActionEntry]?
    /// What Return does for the draft without the model, such as opening an app.
    @ObservationIgnored var instantActions = InstantActions()
    /// Set by the window: hides it the normal way, and shows it again.
    @ObservationIgnored var hidePanel: (() -> Void)?
    @ObservationIgnored var showPanel: (() -> Void)?
    /// Set by the app on the main panel's session: opens the incognito window, or brings it
    /// forward when it is open. `/incognito` calls it.
    @ObservationIgnored var openIncognito: (() -> Void)?
    /// Set by the incognito window: takes the window away once its conversation is discarded.
    @ObservationIgnored var closeWindow: (() -> Void)?

    /// True for the incognito window's session. Nothing from it is written anywhere.
    var isIncognito: Bool { kind == .incognito }

    @ObservationIgnored var onStatusChange: (() -> Void)?
    /// Each tool's source group by name, for the inspector to show for calls stored before the
    /// group was kept with the result.
    @ObservationIgnored var toolSources: [String: String] = [:]
    /// Errors since launch, for Settings > Debugging. Message content never goes here. The
    /// incognito session has a log of its own, which nothing shows and which goes with it.
    @ObservationIgnored let problems = ProblemLog()
    @ObservationIgnored private var loop: AgentLoop?
    /// Makes the loop for a new incognito conversation, over a fresh `InMemoryThreadStore`.
    @ObservationIgnored private let makeLoop: (() -> AgentLoop)?
    @ObservationIgnored private let authenticator: ChatGPTAuthenticator?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var confirmation: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private let episodeTimeout: () -> TimeInterval
    @ObservationIgnored var clock: () -> Date = { Date() }
    /// For a preview of the scrollback: the history opens at its top instead of its end.
    @ObservationIgnored var previewStartsAtTop = false
    /// For a preview of the fresh-start slot: stand-in lines that show how content lays out.
    @ObservationIgnored var previewFreshStartContent: [String]?
    /// For a preview of the hover controls: shows them all, since a capture has no pointer.
    @ObservationIgnored var previewRevealsControls = false
    /// True after a fresh start in the panel, until the next message starts the episode.
    @ObservationIgnored private var startsNewEpisode = false
    /// Where the switches in Settings, Behaviors and Experiments are read. Previews and tests
    /// set a stand-in suite, so they never read the owner's.
    @ObservationIgnored var preferences: UserDefaults = .standard
    /// Up and Down Arrow through the owner's earlier messages in this window.
    @ObservationIgnored private var recall = MessageRecall()
    /// Messages sent while a task ran, waiting for their turn. Held in memory only, one per
    /// window. An experiment, behind `Experiment.queueMessagesWhileRunning`.
    private(set) var queue = MessageQueue()
    /// The list under the text field, with the suggestions-in-the-field experiment on. See
    /// `SuggestionListState`.
    @ObservationIgnored let suggestionList = SuggestionListState()
    /// True while Up and Down Arrow are moving through the owner's earlier messages.
    var isRecallingMessage: Bool { recall.isRecalling }

    /// The main panel's session, on the kept thread.
    /// - Parameter signedIn: For tests, which run without an authenticator.
    init(
        loop: AgentLoop?, authenticator: ChatGPTAuthenticator?,
        episodeTimeout: @escaping () -> TimeInterval = { EpisodeTimeoutSetting.current() },
        signedIn: Bool = false
    ) {
        kind = .kept
        self.loop = loop
        makeLoop = nil
        self.authenticator = authenticator
        self.episodeTimeout = episodeTimeout
        if signedIn { signInState = .signedIn }
    }

    /// An incognito window's session. It starts a conversation at once.
    /// - Parameters:
    ///   - makeLoop: Makes the loop for each conversation, over a fresh `InMemoryThreadStore`,
    ///     with the incognito tools and instructions. Called again on `/new` and Clear.
    ///   - signedIn: Whether the main panel's session is signed in. The app keeps it in step.
    init(incognito makeLoop: @escaping () -> AgentLoop, signedIn: Bool) {
        kind = .incognito
        self.makeLoop = makeLoop
        authenticator = nil
        episodeTimeout = { .infinity }
        if signedIn { signInState = .signedIn }
        startConversation()
    }

    /// Stand-in state for rendering a window without a model.
    init(
        previewEntries: [ThreadEntry], streamingText: String = "", pendingConfirmation: ConfirmationRequest? = nil,
        isRunning: Bool = false, runningCallIDs: [String] = [], freshStart: Bool = false, incognito: Bool = false
    ) {
        kind = incognito ? .incognito : .kept
        loop = nil
        makeLoop = nil
        authenticator = nil
        episodeTimeout = { EpisodeTimeoutSetting.current() }
        if incognito {
            transcript.beginEpisode(at: previewEntries.first?.date ?? Date())
            for entry in previewEntries { transcript.apply(entry) }
        } else {
            transcript = Transcript(entries: previewEntries)
        }
        if freshStart { transcript.beginEpisode(at: Date()) }
        for callID in runningCallIDs { transcript.setToolStatus(callID, .running) }
        if let pendingConfirmation { transcript.setToolStatus(pendingConfirmation.callID, .waitingForConfirmation) }
        self.streamingText = streamingText
        self.pendingConfirmation = pendingConfirmation
        self.isRunning = isRunning
        signInState = .signedIn
        preferences = SummonPanel.previewPreferences
    }

    /// For previews: sets a tool row's status.
    func previewSetStatus(_ callID: String, _ status: TranscriptRow.ToolStatus) {
        transcript.setToolStatus(callID, status)
    }

    /// For previews: adds a row for a call whose arguments have not arrived.
    func previewToolStarted(_ callID: String) {
        transcript.toolStarted(callID)
    }

    /// For previews: shows the question asked when the owner closes or clears while a task runs.
    func previewPendingDiscard(_ discard: Discard) {
        pendingDiscard = discard
    }

    /// Loads the whole thread as history and checks for a stored sign-in.
    func start() async {
        if let loop, kind == .kept {
            transcript = Transcript(entries: await loop.thread.entries, summaries: ToolCallSummaries(loop.tools))
        }
        if let authenticator, await authenticator.isSignedIn() {
            signInState = .signedIn
        }
        onStatusChange?()
    }

    func panelDidAppear() {
        focusRequest += 1
        instantActions.refresh()
        skillCommands?.reload()
        refreshEpisode()
    }

    /// Starts a fresh page when the main panel's current episode has timed out. Idleness counts
    /// from the last activity, not from when the panel was shown. An incognito conversation has
    /// no timeout: it lasts until the owner clears it or closes its window.
    func refreshEpisode() {
        guard kind == .kept, !isRunning else { return }
        if transcript.currentEpisodeHasTimedOut(now: clock(), timeout: episodeTimeout()) {
            beginFreshEpisode()
        }
    }

    // MARK: - Commands

    func perform(_ command: SlashCommand) {
        guard !isRunning else { return }
        switch (command, kind) {
        case (.new, .kept):
            beginFreshEpisode()
        case (.new, .incognito):
            performDiscard(.clear)
        case (.incognito, .kept):
            openIncognito?()
        case (.incognito, .incognito):
            transcript.appendNotice("This window is already incognito. Nothing from it is kept.")
        }
    }

    // MARK: - The command list

    /// The commands the owner can type here: the app's own, and in the main panel the skills
    /// they can invoke. The incognito window has no skills, so it offers none.
    var slashMenu: SlashCommandMenu {
        guard !isIncognito, let skillCommands else { return .builtInOnly }
        return skillCommands.menu
    }

    /// The commands listed above the text field for the draft, or none once Escape dismissed them.
    var commandSuggestions: [SlashCommandItem] {
        guard dismissedHintDraft == nil else { return [] }
        return slashMenu.suggestions(for: draft)
    }

    private func draftChangedForHint() {
        hintSelection = 0
        if let dismissed = dismissedHintDraft, draft.isEmpty || !draft.hasPrefix(dismissed) {
            dismissedHintDraft = nil
        }
    }

    /// Up, Down, or Shift-Tab while commands are listed. False when there is nothing to choose
    /// between, so the key does what it always does.
    func moveHintSelection(by offset: Int) -> Bool {
        let count = commandSuggestions.count
        guard count > 1 else { return false }
        hintSelection = (hintSelection + offset % count + count) % count
        return true
    }

    /// Tab while commands are listed: puts the chosen one in the field. A skill gets a space
    /// after it, for its text. False when no command is listed, so Tab does what it always does.
    func completeHint() -> Bool {
        let suggestions = commandSuggestions
        guard !suggestions.isEmpty else { return false }
        complete(suggestions[min(hintSelection, suggestions.count - 1)])
        return true
    }

    /// A click on a listed command, or Tab or Return on the chosen one.
    func complete(_ item: SlashCommandItem) {
        // While a skill's text is typed, the line already has the command.
        guard !(draft.hasPrefix(item.name) && draft.dropFirst(item.name.count).first?.isWhitespace == true) else { return }
        draft = item.completion
        focusRequest += 1
    }

    /// Escape while commands are listed: hides the list for this draft and returns true, or
    /// returns false when none is listed, so Escape goes on to the inspector or the panel.
    func dismissHint() -> Bool {
        guard !commandSuggestions.isEmpty else { return false }
        dismissedHintDraft = draft
        return true
    }

    /// Escape's first step: the list under the text field when it is open, then an instant
    /// action suggestion or the command list, whichever is showing. A slash rules out a
    /// suggestion, so at most one of them is.
    func dismissSuggestionOrHint() -> Bool {
        closeSuggestionList() || instantActions.dismiss() || dismissHint()
    }

    private func beginFreshEpisode() {
        startsNewEpisode = true
        transcript.beginEpisode(at: clock())
    }

    // MARK: - Discarding an incognito conversation

    /// The close button, Command-W, and Clear in the incognito window. With no task running it
    /// happens at once. With one running, the window asks first, since the task stops and the
    /// conversation is gone.
    func requestDiscard(_ discard: Discard) {
        guard kind == .incognito else { return }
        if isRunning {
            pendingDiscard = discard
        } else {
            performDiscard(discard)
        }
    }

    /// The owner confirmed: stop the task and discard.
    func confirmDiscard() {
        guard let discard = pendingDiscard else { return }
        performDiscard(discard)
    }

    /// The owner chose to keep the conversation.
    func cancelDiscard() {
        pendingDiscard = nil
    }

    private func performDiscard(_ discard: Discard) {
        endConversation()
        switch discard {
        case .clear:
            startConversation()
            focusRequest += 1
        case .close:
            closeWindow?()
        }
    }

    /// Lets go of the incognito conversation: its task, its loop and store, its rows, and the draft.
    private func endConversation() {
        pendingDiscard = nil
        task?.cancel()
        resolveConfirmation(false)
        task = nil
        isRunning = false
        streamingText = ""
        loop = nil
        transcript = Transcript()
        draft = ""
        recall.reset()
        queue.clear()
        conversation += 1
        onStatusChange?()
    }

    private func startConversation() {
        guard let makeLoop else { return }
        loop = makeLoop()
        transcript = Transcript()
        transcript.beginEpisode(at: clock())
    }

    // MARK: - Running instructions

    /// Return. Takes the instant action the row offers when there is one, and otherwise sends
    /// the text to the agent.
    func submit() {
        guard !isRunning || queuesWhileRunning else { return }
        // With the list under the field open, Return acts on its highlighted row.
        if submitFromSuggestionList() { return }
        // While a task runs, what the app does itself, an instant action or one of its own
        // commands, is not queued: it stays in the field until the task ends.
        if isRunning, let candidate = instantActions.offered(for: draft) {
            transcript.appendNotice("\(candidate.title) can be run when the task ends. Command-Return queues the text as a message instead.")
            return
        }
        if let candidate = instantActions.take(for: draft) {
            perform(candidate)
            return
        }
        // A partly typed command, such as `/ren`, completes to the chosen one first. A command
        // typed in full runs.
        let suggestions = commandSuggestions
        if !suggestions.isEmpty, slashMenu.parse(draft) == nil, !draft.contains(where: \.isWhitespace) {
            complete(suggestions[min(hintSelection, suggestions.count - 1)])
            return
        }
        submitToAgent()
    }

    /// An instant action, such as opening an app. It is never sent to the model and never
    /// written to the thread, so the episode's request, and its prompt cache, stay as they were.
    /// The main panel hides the normal way. The incognito window stays, since hiding it is
    /// closing it. If the action fails, the window comes back with the text and a line saying
    /// why, which is shown only and never kept.
    func perform(_ candidate: InstantActionCandidate) {
        if case .action(let id) = candidate.target {
            runSavedAction(id: id, title: candidate.title)
            return
        }
        let text = draft
        let conversation = conversation
        draft = ""
        recall.reset()
        if kind == .kept { hidePanel?() }
        Task {
            do {
                try await instantActions.perform(candidate)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                problems.record("Instant action", "Could not open \(candidate.title): \(message)")
                guard conversation == self.conversation else { return }
                if draft.isEmpty { draft = text }
                transcript.appendNotice("Could not open \(candidate.title). \(message)")
                showPanel?()
            }
        }
    }

    /// A saved action, from the instant row. It runs with no model request, through the same
    /// tools the agent's calls use, and with every go-ahead given, since the owner chose it from
    /// a list. Unlike opening an app it is kept: the owner's typed text and a record of each
    /// step go into the thread as their message, so the agent sees what happened next time.
    /// The main panel hides the normal way and comes back when a step fails, with the text in
    /// the field and the failure in the history.
    private func runSavedAction(id: String, title: String) {
        guard kind == .kept, let loop else { return }
        let text = draft
        // Read as it is now, so the action runs as its file says, or not at all.
        guard let entry = instantActions.actionLibrary?.entry(id: id), let action = entry.action, entry.isAvailable else {
            instantActions.reloadActions()
            transcript.appendError("\(title) cannot be run. " + (instantActions.actionLibrary?.entry(id: id)?.problem
                ?? "It was turned off or removed from the actions folder."))
            return
        }
        let startsNew = startsNewEpisode
        startsNewEpisode = false
        let conversation = conversation
        draft = ""
        recall.reset()
        streamingText = ""
        isRunning = true
        onStatusChange?()
        hidePanel?()
        if let skillCommands {
            skillCommands.reload()
            menuAtTaskStart = skillCommands.menu
        }
        actionsAtTaskStart = instantActions.actionLibrary?.entries()
        task = Task {
            do {
                let entry = try await loop.runAction(
                    action, typed: text, startsNewEpisode: startsNew, now: clock(),
                    onEvent: { event in await self.handle(event, in: conversation) })
                if case .userMessage(_, _, let record?) = entry.item, let failed = record.failedStep {
                    let output = record.steps[failed].output
                    problems.record("Action", "\(action.name) stopped at step \(failed + 1): \(output.prefix(200))")
                    if draft.isEmpty { draft = text }
                    showPanel?()
                }
            } catch is CancellationError {
                finishTask(conversation, ending: .stopped)
                return
            } catch {
                appendError(error, in: conversation)
                if draft.isEmpty { draft = text }
                showPanel?()
                finishTask(conversation, ending: .failed)
                return
            }
            finishTask(conversation, ending: .finished)
        }
    }

    /// Command-Return, and Return when nothing is offered: sends the text to the agent. While a
    /// task runs with the queue experiment on, the message waits in the queue instead.
    func submitToAgent() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if case .builtIn(let command) = slashMenu.parse(text) {
            if submitCommand(command, typed: text) {
                draft = ""
                recall.reset()
            }
            return
        }
        if isRunning {
            guard queuesWhileRunning else { return }
            queue.append(text)
            draft = ""
            recall.reset()
            return
        }
        if send(text) {
            draft = ""
            recall.reset()
        }
    }

    /// One of the app's own commands, typed and sent, or from keys, such as Delete twice for
    /// `/new`. Both come here, so they behave the same. While a task runs it is not run and not
    /// queued: with the queue experiment on a line says it can be used when the task ends, and
    /// with it off nothing happens, as Return does nothing then. Returns true when it ran.
    @discardableResult
    private func submitCommand(_ command: SlashCommand, typed: String) -> Bool {
        if isRunning {
            if queuesWhileRunning {
                transcript.appendNotice("\(typed) can be used when the task ends.")
            }
            return false
        }
        perform(command)
        return true
    }

    /// Delete twice in quick succession in an empty field, with the behavior on: does what
    /// typing `/new` and Return does, through the same path. Returns false when the behavior is
    /// off or the field has text, so the key does what it always does.
    func startNewEpisodeFromKeys() -> Bool {
        guard HarnessBehavior.doubleDeleteStartsNewEpisode.isOn(preferences), draft.isEmpty else { return false }
        if submitCommand(.new, typed: SlashCommand.new.name) {
            recall.reset()
        }
        return true
    }

    /// Whether Return while a task runs queues the message. Read each time, so the switch in
    /// Settings applies at once.
    var queuesWhileRunning: Bool { Experiment.queueMessagesWhileRunning.isOn(preferences) }

    /// Sends one message to the agent as its own turn: the field's text, or a queued message.
    /// Returns false when nothing was sent and the text should stay where it was.
    @discardableResult
    private func send(_ text: String) -> Bool {
        guard !isRunning else { return false }
        // A known command is the app's to handle. It is never sent or written down.
        var skill: ThreadItem.SkillInvocation?
        switch slashMenu.parse(text) {
        case .builtIn(let command):
            perform(command)
            return true
        case .skill(let command, _):
            // Read as it is now, so the agent gets the instructions the owner sees in Settings.
            switch skillCommands?.library.invocation(typed: text, command: command) {
            case .success(let invocation):
                skill = invocation
            case .failure(let error):
                skillCommands?.reload()
                transcript.appendError("\(command.slashName) cannot be used. \(Self.describe(error))")
                return false
            case nil:
                return false
            }
        case nil:
            break
        }
        guard let loop else { return false }
        guard signInState == .signedIn else {
            transcript.appendError("Sign in with ChatGPT first, from the mac-os-agent menu in the menu bar.")
            return false
        }
        let startsNew = startsNewEpisode
        startsNewEpisode = false
        let conversation = conversation
        streamingText = ""
        isRunning = true
        onStatusChange?()
        if !isIncognito, let skillCommands {
            skillCommands.reload()
            menuAtTaskStart = skillCommands.menu
        }
        if !isIncognito { actionsAtTaskStart = instantActions.actionLibrary?.entries() }

        // The task holds the session strongly until it ends. Discarding an incognito
        // conversation cancels it, and anything it reports after that is dropped.
        task = Task {
            var ending = TaskEnding.finished
            do {
                try await loop.run(
                    text,
                    skill: skill,
                    startsNewEpisode: startsNew,
                    onEvent: { event in await self.handle(event, in: conversation) },
                    confirm: { request in await self.requestConfirmation(request, in: conversation) })
            } catch is CancellationError {
                ending = .stopped
                update(conversation) {
                    $0.stopUnfinishedTools()
                    $0.appendNotice("Stopped.")
                }
            } catch {
                ending = .failed
                appendError(error, in: conversation)
            }
            finishTask(conversation, ending: ending)
        }
        return true
    }

    private enum TaskEnding {
        case finished
        case stopped
        case failed
    }

    /// Waits for the running task, for tests.
    func waitUntilIdle() async {
        await task?.value
    }

    /// Changes the history, unless the conversation the change belongs to has been discarded.
    private func update(_ conversation: Int, _ change: (inout Transcript) -> Void) {
        guard conversation == self.conversation else { return }
        change(&transcript)
    }

    /// Stops the running task. Hiding the main panel does not call this. The task is cancelled
    /// before a waiting go-ahead is answered, so the tool sees a stop and not the owner declining.
    func stop() {
        task?.cancel()
        resolveConfirmation(false)
    }

    func resolveConfirmation(_ approved: Bool) {
        guard let confirmation else { return }
        self.confirmation = nil
        if let request = pendingConfirmation {
            let status: TranscriptRow.ToolStatus = approved ? .running : .finished
            transcript.setToolStatus(request.callID, status)
        }
        pendingConfirmation = nil
        onStatusChange?()
        confirmation.resume(returning: approved)
    }

    private func requestConfirmation(_ request: ConfirmationRequest, in conversation: Int) async -> Bool {
        if Task.isCancelled || conversation != self.conversation { return false }
        resolveConfirmation(false)
        pendingConfirmation = request
        transcript.setToolStatus(request.callID, .waitingForConfirmation)
        onStatusChange?()
        return await withCheckedContinuation { continuation in
            confirmation = continuation
        }
    }

    private func finishTask(_ conversation: Int, ending: TaskEnding) {
        guard conversation == self.conversation else { return }
        task = nil
        isRunning = false
        streamingText = ""
        resolveConfirmation(false)
        announceSkillCommandChanges()
        announceActionChanges()
        onStatusChange?()
        switch ending {
        case .finished: sendNextQueued()
        case .stopped: queue.pause(.stopped)
        case .failed: queue.pause(.failed)
        }
    }

    // MARK: - The queue

    /// After a turn that finished normally: the next queued message, as its own turn.
    private func sendNextQueued() {
        guard let item = queue.next() else { return }
        sendQueued(item)
    }

    private func sendQueued(_ item: MessageQueue.Item) {
        if !send(item.text) {
            // It could not go out, such as when signed out. It goes back to the front, paused.
            queue = Self.requeued(queue, puttingBack: item)
        }
    }

    private static func requeued(_ queue: MessageQueue, puttingBack item: MessageQueue.Item) -> MessageQueue {
        var rebuilt = MessageQueue()
        rebuilt.append(item.text)
        for other in queue.items { rebuilt.append(other.text) }
        rebuilt.pause(.failed)
        return rebuilt
    }

    /// Send in the paused queue's line: sends the next message and resumes the queue.
    func resumeQueue() {
        guard !isRunning, let item = queue.resume() else { return }
        sendQueued(item)
    }

    func clearQueue() {
        queue.clear()
    }

    func removeQueued(_ id: UUID) {
        queue.remove(id)
    }

    /// Edit on a queued row: takes it out of the queue and into the field, when the field is
    /// empty, so nothing typed is lost.
    func editQueued(_ id: UUID) {
        guard draft.isEmpty, let text = queue.pullBack(id) else { return }
        draft = text
        recall.reset()
        focusRequest += 1
    }

    // MARK: - Habits from terminal coding agents

    /// Up (-1) or Down (1) with the insertion point on the field's first or last line. Up on an
    /// empty field while messages are queued takes the newest back into the field. Otherwise,
    /// with the behavior on, it moves through the owner's earlier messages in this window.
    /// Returns false when it did nothing, so the key does what it always does.
    func recallMessage(by offset: Int) -> Bool {
        if offset < 0, draft.isEmpty, !recall.isRecalling, let text = queue.pullBack() {
            draft = text
            return true
        }
        guard HarnessBehavior.recallEarlierMessages.isOn(preferences), !isRunning || queuesWhileRunning else { return false }
        let text = offset < 0
            ? recall.older(current: draft, history: { recallHistory })
            : recall.newer(current: draft)
        guard let text else { return false }
        draft = text
        return true
    }

    /// The owner's messages in this window, newest first. The main panel's history is the whole
    /// kept thread. The incognito window's is only its own conversation.
    var recallHistory: [String] {
        MessageRecall.history(newestFirst: transcript.rows.reversed().lazy.compactMap { row in
            if case .user(let text, _, _) = row.kind { text } else { nil }
        })
    }

    /// Control-C, with the behavior on: stops the running task the way Command-Period does, or
    /// with no task running clears the field. Returns false when it did nothing, as with an
    /// empty field and no task, so the key does what it always does.
    func interrupt() -> Bool {
        guard HarnessBehavior.controlCStopsOrClears.isOn(preferences) else { return false }
        if isRunning {
            stop()
            return true
        }
        guard !draft.isEmpty else { return false }
        draft = ""
        recall.reset()
        return true
    }

    /// After a task in which a skill the owner can invoke was added or changed, such as one the
    /// agent just wrote, the list already has it, and a quiet line by the text field says so.
    private func announceSkillCommandChanges() {
        guard let before = menuAtTaskStart, let skillCommands else { return }
        menuAtTaskStart = nil
        skillCommands.reload()
        if let notice = SlashCommandMenu.changes(from: before, to: skillCommands.menu).notice {
            transcript.appendNotice(notice)
        }
    }

    /// After a task in which a saved action was added or changed, such as one the agent just
    /// saved, the instant row already offers it, and a quiet line by the text field says so.
    private func announceActionChanges() {
        guard let before = actionsAtTaskStart, let library = instantActions.actionLibrary else { return }
        actionsAtTaskStart = nil
        instantActions.reloadActions()
        if let notice = SavedActionLibrary.changeNotice(from: before, to: library.entries()) {
            transcript.appendNotice(notice)
        }
    }

    private static func describe(_ error: SkillLibrary.LoadError) -> String {
        switch error {
        case .notFound: "The skill is no longer in the skills folder."
        case .turnedOff: "The skill is turned off in Settings."
        case .broken(let problem): problem
        }
    }

    private func handle(_ event: AgentEvent, in conversation: Int) {
        guard conversation == self.conversation else { return }
        switch event {
        case .entryAdded(let entry):
            switch entry.item {
            case .assistantMessage, .toolCall: streamingText = ""
            default: break
            }
            transcript.apply(entry)
        case .textDelta(let text):
            streamingText += text
        case .toolCallStarted(let callID, _):
            transcript.toolStarted(callID)
        case .toolRunning(let callID, let summary):
            transcript.toolRunning(callID, command: summary)
        case .toolFinished(let callID):
            transcript.setToolStatus(callID, .finished)
            // A command may have written a skill or an action. The lists follow at once.
            skillCommands?.reload()
            if !isIncognito { instantActions.reloadActions() }
        case .actionStarted(let start):
            transcript.beginActionRun(start)
        }
    }

    private func appendError(_ error: Error, in conversation: Int) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        update(conversation) { $0.appendError(message) }
        problems.record("Request", message)
    }

    /// Keeps the incognito session's sign-in in step with the main panel's.
    func followSignIn(_ state: SignInState) {
        guard kind == .incognito, signInState != state else { return }
        signInState = state
    }

    // MARK: - Sign-in

    func signIn() {
        guard let authenticator, signInState != .signingIn else { return }
        signInState = .signingIn
        onStatusChange?()
        Task {
            do {
                try await authenticator.signIn { url in
                    await MainActor.run { _ = NSWorkspace.shared.open(url) }
                }
                signInState = .signedIn
            } catch ChatGPTSignIn.SignInError.cancelled {
                signInState = await authenticator.isSignedIn() ? .signedIn : .signedOut
            } catch {
                signInState = await authenticator.isSignedIn() ? .signedIn : .signedOut
                problems.record("Sign-in", (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                Self.showAlert("Sign-in did not finish", error)
            }
            onStatusChange?()
        }
    }

    func cancelSignIn() {
        guard let authenticator else { return }
        Task { await authenticator.cancelSignIn() }
    }

    func signOut() {
        guard let authenticator else { return }
        Task {
            await authenticator.signOut()
            signInState = .signedOut
            onStatusChange?()
        }
    }

    private static func showAlert(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        NSApp.activate()
        alert.runModal()
    }
}
