import AppKit
import MacOSAgentCore
import Observation

/// One row of the current exchange in the panel.
struct ExchangeRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case user(String)
        case assistant(String)
        case tool(command: String, status: ToolStatus, output: String?)
        case notice(String)
        case error(String)
    }

    enum ToolStatus: Equatable {
        case preparing
        case waitingForConfirmation
        case running
        case finished
    }

    var id: String
    var kind: Kind
}

/// The app's state while it works: the current exchange, the running task, and the sign-in.
/// The task belongs to this object, not to the panel, so hiding the panel never stops it.
@MainActor
@Observable
final class AgentSession {
    enum SignInState: Equatable {
        case signedOut
        case signingIn
        case signedIn
    }

    private(set) var rows: [ExchangeRow] = []
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
    @ObservationIgnored private var toolCommands: [String: String] = [:]

    init(loop: AgentLoop?, authenticator: ChatGPTAuthenticator?) {
        self.loop = loop
        self.authenticator = authenticator
    }

    /// Stand-in state for rendering the panel without a model.
    init(previewRows: [ExchangeRow], streamingText: String = "", pendingConfirmation: ConfirmationRequest? = nil, isRunning: Bool = false) {
        loop = nil
        authenticator = nil
        rows = previewRows
        self.streamingText = streamingText
        self.pendingConfirmation = pendingConfirmation
        self.isRunning = isRunning
        signInState = .signedIn
    }

    /// Loads the last exchange from the thread and checks for a stored sign-in.
    func start() async {
        if let loop {
            let entries = await loop.thread.entries
            let lastUser = entries.lastIndex { if case .userMessage = $0.item { true } else { false } }
            if let lastUser {
                for entry in entries[lastUser...] { apply(entry) }
            }
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
            rows = [ExchangeRow(id: "sign-in", kind: .error("Sign in with ChatGPT first, from the mac-os-agent menu in the menu bar."))]
            return
        }
        draft = ""
        rows = []
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
        if let request = pendingConfirmation { setToolStatus(request.callID, approved ? .running : .finished) }
        pendingConfirmation = nil
        onStatusChange?()
        confirmation.resume(returning: approved)
    }

    private func requestConfirmation(_ request: ConfirmationRequest) async -> Bool {
        if Task.isCancelled { return false }
        resolveConfirmation(false)
        pendingConfirmation = request
        setToolStatus(request.callID, .waitingForConfirmation)
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
            apply(entry)
        case .textDelta(let text):
            streamingText += text
        case .toolCallStarted(let callID, _):
            if !rows.contains(where: { $0.id == callID }) {
                rows.append(ExchangeRow(id: callID, kind: .tool(command: "", status: .preparing, output: nil)))
            }
        case .toolRunning(let callID, let summary):
            toolCommands[callID] = summary
            updateTool(callID) { command, status, _ in
                command = summary
                if status == .preparing { status = .running }
            }
        case .toolFinished(let callID):
            setToolStatus(callID, .finished)
        }
    }

    /// Adds a thread entry to the exchange. A new user message starts a new exchange.
    private func apply(_ entry: ThreadEntry) {
        switch entry.item {
        case .userMessage(let text):
            rows = [ExchangeRow(id: entry.id.uuidString, kind: .user(text))]
        case .assistantMessage(let message):
            streamingText = ""
            if !message.text.isEmpty {
                rows.append(ExchangeRow(id: entry.id.uuidString, kind: .assistant(message.text)))
            }
        case .toolCall(let call):
            let command = JSONValue.parse(call.arguments)?["command"]?.stringValue ?? call.name
            streamingText = ""
            if rows.contains(where: { $0.id == call.callID }) {
                updateTool(call.callID) { existing, _, _ in existing = command }
            } else {
                rows.append(ExchangeRow(id: call.callID, kind: .tool(command: command, status: .preparing, output: nil)))
            }
        case .toolResult(let result):
            updateTool(result.callID) { _, status, output in
                status = .finished
                output = result.output
            }
        case .providerItem:
            break
        }
    }

    private func setToolStatus(_ callID: String, _ newStatus: ExchangeRow.ToolStatus) {
        updateTool(callID) { _, status, _ in status = newStatus }
    }

    private func updateTool(_ callID: String, _ change: (inout String, inout ExchangeRow.ToolStatus, inout String?) -> Void) {
        guard let index = rows.firstIndex(where: { $0.id == callID }),
              case .tool(var command, var status, var output) = rows[index].kind
        else { return }
        change(&command, &status, &output)
        rows[index].kind = .tool(command: command, status: status, output: output)
    }

    private func appendNotice(_ text: String) {
        rows.append(ExchangeRow(id: UUID().uuidString, kind: .notice(text)))
    }

    private func appendError(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        rows.append(ExchangeRow(id: UUID().uuidString, kind: .error(message)))
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
