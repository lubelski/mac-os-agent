import AppKit
import MacOSAgentCore
import Observation

/// The app's state while it works: the thread's history, the running task, and the sign-in.
/// The task belongs to this object, not to the panel, so hiding the panel never stops it.
@MainActor
@Observable
final class AgentSession {
    enum SignInState: Equatable {
        case signedOut
        case signingIn
        case signedIn
    }

    private(set) var transcript = Transcript()
    private(set) var streamingText = ""
    private(set) var isRunning = false
    private(set) var pendingConfirmation: ConfirmationRequest?
    private(set) var signInState: SignInState = .signedOut
    /// Changes every time the panel is shown, so the text field takes focus again.
    private(set) var focusRequest = 0
    var draft = ""

    @ObservationIgnored var onStatusChange: (() -> Void)?
    @ObservationIgnored private let loop: AgentLoop?
    @ObservationIgnored private let authenticator: ChatGPTAuthenticator?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var confirmation: CheckedContinuation<Bool, Never>?

    init(loop: AgentLoop?, authenticator: ChatGPTAuthenticator?) {
        self.loop = loop
        self.authenticator = authenticator
    }

    /// Stand-in state for rendering the panel without a model.
    init(previewEntries: [ThreadEntry], streamingText: String = "", pendingConfirmation: ConfirmationRequest? = nil, isRunning: Bool = false, runningCallIDs: [String] = []) {
        loop = nil
        authenticator = nil
        transcript = Transcript(entries: previewEntries)
        for callID in runningCallIDs { transcript.setToolStatus(callID, .running) }
        if let pendingConfirmation { transcript.setToolStatus(pendingConfirmation.callID, .waitingForConfirmation) }
        self.streamingText = streamingText
        self.pendingConfirmation = pendingConfirmation
        self.isRunning = isRunning
        signInState = .signedIn
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
    }

    // MARK: - Running instructions

    func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning, let loop else { return }
        guard signInState == .signedIn else {
            transcript.appendError("Sign in with ChatGPT first, from the mac-os-agent menu in the menu bar.")
            return
        }
        draft = ""
        streamingText = ""
        isRunning = true
        onStatusChange?()

        // The session lives as long as the app, so the task holds it strongly.
        task = Task {
            do {
                try await loop.run(
                    text,
                    onEvent: { event in await self.handle(event) },
                    confirm: { request in await self.requestConfirmation(request) })
            } catch is CancellationError {
                appendNotice("Stopped.")
            } catch {
                appendError(error)
            }
            finishTask()
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
        if let request = pendingConfirmation { transcript.setToolStatus(request.callID, approved ? .running : .finished) }
        pendingConfirmation = nil
        onStatusChange?()
        confirmation.resume(returning: approved)
    }

    private func requestConfirmation(_ request: ConfirmationRequest) async -> Bool {
        if Task.isCancelled { return false }
        resolveConfirmation(false)
        pendingConfirmation = request
        transcript.setToolStatus(request.callID, .waitingForConfirmation)
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

    private func handle(_ event: AgentEvent) {
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
        }
    }

    private func appendNotice(_ text: String) {
        transcript.appendNotice(text)
    }

    private func appendError(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        transcript.appendError(message)
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
