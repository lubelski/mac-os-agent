import Foundation

/// Sends an HTTP request. Tests substitute a fake.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Receives the browser's redirect for one sign-in. `OAuthCallbackListener` in the app, a
/// stand-in in tests.
protocol OAuthCallbackReceiving: AnyObject, Sendable {
    func start() async throws
    func result() async throws -> ChatGPTSignIn.AuthorizationResult
    func stop()
}

extension OAuthCallbackListener: OAuthCallbackReceiving {}

/// How a sign-out's revocation went. Local sign-out has happened in every case.
public enum RevocationResult: Sendable, Equatable {
    /// OpenAI answered 200, so the renewable session is over.
    case revoked
    /// No answer confirmed it, after retrying network failures and server errors for a short time.
    case notConfirmed
    /// There was no stored refresh token to revoke.
    case nothingToRevoke
}

/// Holds the ChatGPT sign-in: runs the browser flow, keeps the access token in memory, and
/// refreshes it ahead of expiry.
///
/// The secret store, a file in the data folder, holds two kinds of thing under separate keys:
/// - The registration: the issued client id and the account it belongs to. It outlives a
///   sign-out, so the next sign-in to the same account reuses the client instead of
///   registering a new one.
/// - The tokens: the refresh token and the ID token. Signing out revokes the refresh token
///   and removes both.
/// The access token is never written anywhere.
public actor ChatGPTAuthenticator {
    public static let refreshTokenKey = "chatgpt-refresh-token"
    public static let idTokenKey = "chatgpt-id-token"
    /// The issued client id. An installation from before registrations were kept has this and
    /// the refresh token only, and its next sign-in reuses the client and records the account.
    public static let clientIDKey = "chatgpt-client-id"
    public static let accountSubjectKey = "chatgpt-account-subject"
    public static let accountEmailKey = "chatgpt-account-email"
    /// Waits between revocation attempts. With the first try that is three attempts in about
    /// three seconds, plus the requests' own time limits.
    static let revocationRetryDelays: [Duration] = [.seconds(1), .seconds(2)]

    private let secrets: any SecretStore
    private let installationID: UUID
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let makeListener: @Sendable (_ state: String, _ savedClientID: String?) throws -> any OAuthCallbackReceiving
    private var credential: ChatGPTSignIn.Credential?
    private var refreshTask: Task<ChatGPTSignIn.Credential, Error>?
    private var pendingListener: (any OAuthCallbackReceiving)?
    /// Goes up at every sign-out, so a refresh that was under way does not store its tokens after it.
    private var session = 0
    private var lastTokenDate: Date?
    private var lastError: (date: Date, message: String)?

    public init(
        secrets: any SecretStore,
        installationID: UUID,
        transport: any HTTPTransport = URLSessionTransport(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            secrets: secrets, installationID: installationID, transport: transport, now: now,
            sleep: { try await Task.sleep(for: $0) },
            makeListener: { try OAuthCallbackListener(expectedState: $0, savedClientID: $1) })
    }

    init(
        secrets: any SecretStore,
        installationID: UUID,
        transport: any HTTPTransport,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        makeListener: @escaping @Sendable (String, String?) throws -> any OAuthCallbackReceiving
    ) {
        self.secrets = secrets
        self.installationID = installationID
        self.transport = transport
        self.now = now
        self.sleep = sleep
        self.makeListener = makeListener
    }

    /// True when a refresh token is stored. The token may still turn out to be revoked.
    public func isSignedIn() -> Bool {
        secrets.read(Self.refreshTokenKey) != nil && secrets.read(Self.clientIDKey) != nil
    }

    /// The kept registration, signed in or not.
    public func registration() -> ChatGPTSignIn.Registration? {
        guard let clientID = secrets.read(Self.clientIDKey), !clientID.isEmpty else { return nil }
        return ChatGPTSignIn.Registration(
            clientID: clientID, subject: secrets.read(Self.accountSubjectKey), email: secrets.read(Self.accountEmailKey))
    }

    /// Runs the browser sign-in. `openBrowser` is called with the authorize URL once the
    /// callback listener is ready. Returns when the tokens are stored.
    ///
    /// It reuses the kept registration, so the same account signs in to the same client. When
    /// OpenAI rejects that client, the registration is dropped and a fresh one is made in the
    /// same call, which opens the browser a second time.
    /// - Parameter differentAccount: Register anew for another ChatGPT account. The kept
    ///   registration is replaced once the browser returns with the new one.
    public func signIn(differentAccount: Bool = false, openBrowser: @Sendable (URL) async -> Void) async throws {
        do {
            let kept = differentAccount ? nil : registration()
            do {
                try await authorize(registration: kept, openBrowser: openBrowser)
            } catch ReuseError.rejected where kept != nil {
                forgetRegistration()
                try await authorize(registration: nil, openBrowser: openBrowser)
            }
        } catch ChatGPTSignIn.SignInError.cancelled {
            throw ChatGPTSignIn.SignInError.cancelled
        } catch {
            record(error)
            throw error
        }
    }

    /// OpenAI turned down a reused client id. Internal, so the caller falls back to a new registration.
    private enum ReuseError: Error {
        case rejected
    }

    private func authorize(
        registration: ChatGPTSignIn.Registration?, openBrowser: @Sendable (URL) async -> Void
    ) async throws {
        cancelSignIn()
        let pkce = ChatGPTSignIn.PKCE.generate()
        let state = ChatGPTSignIn.randomValue()
        let nonce = ChatGPTSignIn.randomValue()
        let listener = try makeListener(state, registration?.clientID)
        pendingListener = listener
        defer {
            listener.stop()
            if pendingListener === listener { pendingListener = nil }
        }
        try await listener.start()
        await openBrowser(ChatGPTSignIn.authorizationURL(
            installationID: installationID, state: state, challenge: pkce.challenge, nonce: nonce,
            registration: registration,
            idTokenHint: registration == nil ? nil : secrets.read(Self.idTokenKey)))
        let result: ChatGPTSignIn.AuthorizationResult
        do {
            result = try await listener.result()
        } catch ChatGPTSignIn.SignInError.authorizationFailed(let code)
            where registration != nil && Self.rejectedClientCodes.contains(code)
        {
            throw ReuseError.rejected
        }

        if registration == nil {
            // Keep the issued client id before the code exchange, so a code that fails or
            // expires does not cost a second registration. Tokens and the account from an
            // earlier registration never go with the new client id.
            clearTokens()
            secrets.delete(Self.accountSubjectKey)
            secrets.delete(Self.accountEmailKey)
            try secrets.write(result.clientID, for: Self.clientIDKey)
        }

        var request = Self.tokenRequest()
        request.httpBody = Data(ChatGPTSignIn.authorizationCodeBody(
            code: result.code, verifier: pkce.verifier, clientID: result.clientID).utf8)
        let data: Data
        do {
            data = try await sendTokenRequest(request)
        } catch ChatGPTSignIn.SignInError.tokenRequestFailed(let status, let body)
            where registration != nil && Self.isInvalidClient(status: status, body: body)
        {
            throw ReuseError.rejected
        }
        let credential = try ChatGPTSignIn.credential(
            fromTokenResponse: data, clientID: result.clientID, requireIDToken: true, now: now())
        let claims = try ChatGPTSignIn.idTokenClaims(
            credential.idToken ?? "", clientID: result.clientID, nonce: nonce, now: now())
        if let subject = registration?.subject, subject != claims.subject {
            // Not this registration's account. Its tokens are not kept, and the session they
            // opened is ended so it does not linger.
            Task { [self] in _ = await revoke(refreshToken: credential.refreshToken, clientID: credential.clientID) }
            throw ChatGPTSignIn.SignInError.differentAccount
        }
        try secrets.write(claims.subject, for: Self.accountSubjectKey)
        if let email = claims.email {
            try secrets.write(email, for: Self.accountEmailKey)
        } else {
            secrets.delete(Self.accountEmailKey)
        }
        // A refresh still under way holds the tokens from before. It must not replace these.
        session += 1
        try store(credential)
    }

    /// Callback errors that mean the reused client id is no good.
    static let rejectedClientCodes: Set<String> = ["invalid_client", "unauthorized_client"]

    static func isInvalidClient(status: Int, body: String) -> Bool {
        guard (400..<500).contains(status) else { return false }
        return JSONValue.parse(body)?["error"]?.stringValue == "invalid_client"
    }

    /// Stops a sign-in that is waiting for the browser.
    public func cancelSignIn() {
        pendingListener?.stop()
        pendingListener = nil
    }

    /// Signs out. The tokens are gone from memory and from the secret store before this first
    /// waits, so local sign-out always completes, and a sign-in started meanwhile cannot lose
    /// its tokens to it. Then it revokes the refresh token it took, retrying for a few seconds.
    /// The registration stays, for the next sign-in.
    @discardableResult
    public func signOut() async -> RevocationResult {
        cancelSignIn()
        refreshTask?.cancel()
        refreshTask = nil
        session += 1
        let refreshToken = secrets.read(Self.refreshTokenKey)
        let clientID = secrets.read(Self.clientIDKey)
        clearTokens()
        guard let refreshToken, let clientID else { return .nothingToRevoke }
        let result = await revoke(refreshToken: refreshToken, clientID: clientID)
        if result == .notConfirmed {
            lastError = (now(), "Signed out on this Mac, but OpenAI did not confirm that the session was revoked.")
        }
        return result
    }

    private func clearTokens() {
        credential = nil
        secrets.delete(Self.refreshTokenKey)
        secrets.delete(Self.idTokenKey)
    }

    private func forgetRegistration() {
        clearTokens()
        secrets.delete(Self.clientIDKey)
        secrets.delete(Self.accountSubjectKey)
        secrets.delete(Self.accountEmailKey)
    }

    /// Revokes a refresh token at the endpoint OpenAI's OpenID configuration names. A network
    /// failure or a server error is tried again after a short wait, up to three attempts. Any
    /// other answer than 200 is not retried.
    func revoke(refreshToken: String, clientID: String) async -> RevocationResult {
        var endpoint: URL?
        for attempt in 0...Self.revocationRetryDelays.count {
            if attempt > 0 {
                do { try await sleep(Self.revocationRetryDelays[attempt - 1]) } catch { return .notConfirmed }
            }
            do {
                if endpoint == nil {
                    var discovery = URLRequest(url: ChatGPTSignIn.discoveryURL)
                    discovery.timeoutInterval = 10
                    discovery.setValue("application/json", forHTTPHeaderField: "Accept")
                    let (data, response) = try await transport.send(discovery)
                    if response.statusCode >= 500 { continue }
                    guard response.statusCode == 200,
                          let found = ChatGPTSignIn.revocationEndpoint(fromDiscovery: data)
                    else { return .notConfirmed }
                    endpoint = found
                }
                guard let endpoint else { return .notConfirmed }
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.timeoutInterval = 10
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data(ChatGPTSignIn.revocationBody(refreshToken: refreshToken, clientID: clientID).utf8)
                let (_, response) = try await transport.send(request)
                if response.statusCode == 200 { return .revoked }
                if response.statusCode >= 500 { continue }
                return .notConfirmed
            } catch {
                // A network failure. Try again while attempts remain.
                continue
            }
        }
        return .notConfirmed
    }

    /// A current access token, refreshed first when it is close to expiry.
    public func accessToken() async throws -> String {
        if let credential, credential.refreshAfter > now() { return credential.accessToken }
        if let refreshTask { return try await refreshTask.value.accessToken }
        guard let refreshToken = secrets.read(Self.refreshTokenKey),
              let clientID = secrets.read(Self.clientIDKey)
        else { throw ChatGPTSignIn.SignInError.notSignedIn }

        let session = session
        let task = Task { [transport, now] in
            var request = Self.tokenRequest()
            request.httpBody = Data(ChatGPTSignIn.refreshBody(refreshToken: refreshToken, clientID: clientID).utf8)
            let data = try await Self.sendTokenRequest(request, transport: transport)
            return try ChatGPTSignIn.credential(
                fromTokenResponse: data, clientID: clientID, requireIDToken: false, now: now())
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let fresh = try await task.value
            // Signed out while the refresh was under way: keep nothing from it.
            guard session == self.session else { throw ChatGPTSignIn.SignInError.notSignedIn }
            try store(fresh)
            return fresh.accessToken
        } catch {
            record(error)
            throw error
        }
    }

    /// The state of the sign-in for the Debugging section. It holds dates and an error message,
    /// never a token or the client id.
    public func status() -> SignInStatus {
        SignInStatus(
            isSignedIn: isSignedIn(),
            accessTokenExpires: credential.map { $0.refreshAfter.addingTimeInterval(ChatGPTSignIn.expiryMargin) },
            lastTokenDate: lastTokenDate,
            lastErrorDate: lastError?.date,
            lastError: lastError?.message)
    }

    private func record(_ error: Error) {
        lastError = (now(), (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    /// Forgets the access token so the next request refreshes it, for example after a 401.
    public func discardAccessToken() {
        credential = nil
    }

    /// Keeps a token set. The client id is the registration's and is already stored. A refresh
    /// that returns no ID token keeps the one from before.
    private func store(_ credential: ChatGPTSignIn.Credential) throws {
        self.credential = credential
        lastTokenDate = now()
        try secrets.write(credential.refreshToken, for: Self.refreshTokenKey)
        if let idToken = credential.idToken {
            try secrets.write(idToken, for: Self.idTokenKey)
        }
    }

    private func sendTokenRequest(_ request: URLRequest) async throws -> Data {
        try await Self.sendTokenRequest(request, transport: transport)
    }

    private static func tokenRequest() -> URLRequest {
        var request = URLRequest(url: ChatGPTSignIn.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        return request
    }

    private static func sendTokenRequest(_ request: URLRequest, transport: any HTTPTransport) async throws -> Data {
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            let body = String(decoding: data, as: UTF8.self)
            throw ChatGPTSignIn.SignInError.tokenRequestFailed(
                status: response.statusCode,
                body: body.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: response.statusCode) : body)
        }
        return data
    }
}
