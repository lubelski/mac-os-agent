import AppKit
import MacOSAgentCore
import Observation

/// The app's state while it works: the thread's history, the running task, and the sign-in.
/// The task belongs to this object, not to the panel, so hiding the panel never stops it.
///
/// It also keeps track of episodes. When the panel comes up after the current episode has
/// timed out, or after `/new`, it starts a fresh page, and the owner's next message starts a
/// new episode. An incognito episode runs on a loop of its own over a store held in memory,
/// with a transcript of its own, and both are dropped when it ends.
@MainActor
@Observable
final class AgentSession {
    enum SignInState: Equatable {
        case signedOut
        case signingIn
        case signedIn
    }

    /// The kept thread's history.
    private(set) var transcript = Transcript()
    /// The incognito episode's history while one is on.
    private(set) var incognitoTranscript: Transcript?
    private(set) var streamingText = ""
    private(set) var isRunning = false
    private(set) var pendingConfirmation: ConfirmationRequest?
    private(set) var signInState: SignInState = .signedOut
    /// Changes every time the panel is shown, so the text field takes focus again.
    private(set) var focusRequest = 0
    var draft = ""

    /// True while an incognito episode is on. Nothing from it is written anywhere.
    var isIncognito: Bool { incognitoTranscript != nil }
    /// The history the panel shows: the incognito episode while one is on, the kept thread otherwise.
    var visibleTranscript: Transcript { incognitoTranscript ?? transcript }

    @ObservationIgnored var onStatusChange: (() -> Void)?
    /// Errors since launch, for Settings > Debugging. Message content never goes here.
    @ObservationIgnored let problems = ProblemLog()
    @ObservationIgnored private let loop: AgentLoop?
    @ObservationIgnored private let makeIncognitoLoop: (() -> AgentLoop)?
    @ObservationIgnored private var incognitoLoop: AgentLoop?
    @ObservationIgnored private let authenticator: ChatGPTAuthenticator?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var confirmation: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private let episodeTimeout: () -> TimeInterval
    @ObservationIgnored var clock: () -> Date = { Date() }
    /// For a preview of the scrollback: the history opens at its top instead of its end.
    @ObservationIgnored var previewStartsAtTop = false
    /// For a preview of the fresh-start slot: stand-in lines that show how content lays out.
    @ObservationIgnored var previewFreshStartContent: [String]?
    /// True after a fresh start in the panel, until the next message starts the episode.
    @ObservationIgnored private var startsNewEpisode = false
    @ObservationIgnored private var incognitoLastActivity = Date.distantPast
    @ObservationIgnored private var incognitoTimer: Task<Void, Never>?

    /// - Parameters:
    ///   - makeIncognitoLoop: Makes the loop for a new incognito episode, over a fresh
    ///     `InMemoryThreadStore`. Nil turns incognito off.
    ///   - signedIn: For tests, which run without an authenticator.
    init(
        loop: AgentLoop?, authenticator: ChatGPTAuthenticator?,
        makeIncognitoLoop: (() -> AgentLoop)? = nil,
        episodeTimeout: @escaping () -> TimeInterval = { EpisodeTimeoutSetting.current() },
        signedIn: Bool = false
    ) {
        self.loop = loop
        self.authenticator = authenticator
        self.makeIncognitoLoop = makeIncognitoLoop
        self.episodeTimeout = episodeTimeout
        if signedIn { signInState = .signedIn }
    }

    /// Stand-in state for rendering the panel without a model.
    init(
        previewEntries: [ThreadEntry], streamingText: String = "", pendingConfirmation: ConfirmationRequest? = nil,
        isRunning: Bool = false, runningCallIDs: [String] = [], freshStart: Bool = false, incognitoEntries: [ThreadEntry]? = nil
    ) {
        loop = nil
        makeIncognitoLoop = nil
        authenticator = nil
        episodeTimeout = { EpisodeTimeoutSetting.current() }
        transcript = Transcript(entries: previewEntries)
        if freshStart { transcript.beginEpisode(at: Date()) }
        if let incognitoEntries {
            var incognito = Transcript()
            incognito.beginEpisode(at: incognitoEntries.first?.date ?? Date())
            for entry in incognitoEntries { incognito.apply(entry) }
            incognitoTranscript = incognito
        }
        for callID in runningCallIDs { transcript.setToolStatus(callID, .running) }
        if let pendingConfirmation { transcript.setToolStatus(pendingConfirmation.callID, .waitingForConfirmation) }
        self.streamingText = streamingText
        self.pendingConfirmation = pendingConfirmation
        self.isRunning = isRunning
        signInState = .signedIn
    }

    /// For previews: sets a tool row's status.
    func previewSetStatus(_ callID: String, _ status: TranscriptRow.ToolStatus) {
        transcript.setToolStatus(callID, status)
    }

    /// For previews: adds a row for a call whose arguments have not arrived.
    func previewToolStarted(_ callID: String) {
        transcript.toolStarted(callID)
    }

    /// Loads the whole thread as history and checks for a stored sign-in.
    func start() async {
        if let loop {
            transcript = Transcript(entries: await loop.thread.entries)
        }
        if let authenticator, await authenticator.isSignedIn() {
            signInState = .signedIn
        }
        onStatusChange?()
    }

    func panelDidAppear() {
        focusRequest += 1
        refreshEpisode()
    }

    /// Starts a fresh page when the current episode has timed out, and ends an incognito
    /// episode that has. Idleness counts from the last activity, not from when the panel was shown.
    func refreshEpisode() {
        guard !isRunning else { return }
        let now = clock()
        if isIncognito {
            if incognitoHasTimedOut(now: now) { endIncognito() }
            return
        }
        if transcript.currentEpisodeHasTimedOut(now: now, timeout: episodeTimeout()) {
            beginFreshEpisode()
        }
    }

    // MARK: - Commands

    func perform(_ command: SlashCommand) {
        guard !isRunning else { return }
        switch command {
        case .new:
            if isIncognito { endIncognito() } else { beginFreshEpisode() }
        case .incognito:
            toggleIncognito()
        }
    }

    func toggleIncognito() {
        guard !isRunning else { return }
        if isIncognito { endIncognito() } else { startIncognito() }
    }

    /// Whether the menu bar menu can offer incognito.
    var canUseIncognito: Bool { makeIncognitoLoop != nil }

    private func beginFreshEpisode() {
        startsNewEpisode = true
        transcript.beginEpisode(at: clock())
    }

    private func startIncognito() {
        guard let makeIncognitoLoop else { return }
        incognitoLoop = makeIncognitoLoop()
        var incognito = Transcript()
        incognito.beginEpisode(at: clock())
        incognitoTranscript = incognito
        incognitoLastActivity = clock()
        streamingText = ""
        watchIncognitoTimeout()
        onStatusChange?()
    }

    /// Drops the incognito episode: its loop, its store, and its rows. The kept thread picks up
    /// on a fresh page.
    private func endIncognito() {
        incognitoTimer?.cancel()
        incognitoTimer = nil
        incognitoLoop = nil
        incognitoTranscript = nil
        streamingText = ""
        beginFreshEpisode()
        onStatusChange?()
    }

    private func incognitoHasTimedOut(now: Date) -> Bool {
        now.timeIntervalSince(incognitoLastActivity) >= episodeTimeout()
    }

    /// Ends the incognito episode once it has been idle for the timeout, even with the panel
    /// open, so the indicator never shows an episode that is already over. It waits for a
    /// running task to finish first.
    private func watchIncognitoTimeout() {
        incognitoTimer?.cancel()
        incognitoTimer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isIncognito else { return }
                let remaining = self.incognitoLastActivity.addingTimeInterval(self.episodeTimeout()).timeIntervalSince(self.clock())
                if remaining <= 0, !self.isRunning {
                    self.endIncognito()
                    return
                }
                // Look again at least every minute, since the timeout setting can change.
                try? await Task.sleep(for: .seconds(min(max(remaining, 1), 60)))
            }
        }
    }

    // MARK: - Running instructions

    private enum Target {
        case kept
        case incognito
    }

    func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        // A known command is the app's to handle. It is never sent or written down.
        if let command = SlashCommand.parse(text) {
            draft = ""
            perform(command)
            return
        }
        if isIncognito, incognitoHasTimedOut(now: clock()) {
            // The owner may still believe they are incognito. Keep the message instead of
            // sending it into the kept thread.
            endIncognito()
            transcript.appendNotice("Incognito ended after \(EpisodeTimeoutSetting.describe(episodeTimeout())) without activity. Your message was not sent.")
            return
        }
        let target: Target = isIncognito ? .incognito : .kept
        guard let loop = target == .incognito ? incognitoLoop : loop else { return }
        guard signInState == .signedIn else {
            update(target) { $0.appendError("Sign in with ChatGPT first, from the mac-os-agent menu in the menu bar.") }
            return
        }
        let startsNew = target == .kept && startsNewEpisode
        if target == .kept { startsNewEpisode = false }
        draft = ""
        streamingText = ""
        isRunning = true
        onStatusChange?()

        // The session lives as long as the app, so the task holds it strongly.
        task = Task {
            do {
                try await loop.run(
                    text,
                    startsNewEpisode: startsNew,
                    onEvent: { event in await self.handle(event, target: target) },
                    confirm: { request in await self.requestConfirmation(request, target: target) })
            } catch is CancellationError {
                update(target) { $0.appendNotice("Stopped.") }
            } catch {
                appendError(error, target: target)
            }
            finishTask()
        }
    }

    /// Waits for the running task, for tests.
    func waitUntilIdle() async {
        await task?.value
    }

    /// Changes the transcript the running task writes to. Events for an incognito episode that
    /// has already ended are dropped.
    private func update(_ target: Target, _ change: (inout Transcript) -> Void) {
        switch target {
        case .kept:
            change(&transcript)
        case .incognito:
            guard var incognito = incognitoTranscript else { return }
            change(&incognito)
            incognitoTranscript = incognito
            incognitoLastActivity = clock()
        }
    }

    /// Stops the running task. Hiding the panel does not call this.
    func stop() {
        resolveConfirmation(false)
        task?.cancel()
    }

    func resolveConfirmation(_ approved: Bool) {
        guard let confirmation else { return }
        self.confirmation = nil
        if let request = pendingConfirmation {
            let status: TranscriptRow.ToolStatus = approved ? .running : .finished
            update(isIncognito ? .incognito : .kept) { $0.setToolStatus(request.callID, status) }
        }
        pendingConfirmation = nil
        onStatusChange?()
        confirmation.resume(returning: approved)
    }

    private func requestConfirmation(_ request: ConfirmationRequest, target: Target) async -> Bool {
        if Task.isCancelled { return false }
        resolveConfirmation(false)
        pendingConfirmation = request
        update(target) { $0.setToolStatus(request.callID, .waitingForConfirmation) }
        onStatusChange?()
        return await withCheckedContinuation { continuation in
            confirmation = continuation
        }
    }

    private func finishTask() {
        task = nil
        isRunning = false
        streamingText = ""
        resolveConfirmation(false)
        onStatusChange?()
    }

    private func handle(_ event: AgentEvent, target: Target) {
        switch event {
        case .entryAdded(let entry):
            switch entry.item {
            case .assistantMessage, .toolCall: streamingText = ""
            default: break
            }
            update(target) { $0.apply(entry) }
        case .textDelta(let text):
            streamingText += text
        case .toolCallStarted(let callID, _):
            update(target) { $0.toolStarted(callID) }
        case .toolRunning(let callID, let summary):
            update(target) { $0.toolRunning(callID, command: summary) }
        case .toolFinished(let callID):
            update(target) { $0.setToolStatus(callID, .finished) }
        }
    }

    private func appendError(_ error: Error, target: Target) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        update(target) { $0.appendError(message) }
        problems.record("Request", message)
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
