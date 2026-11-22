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

/// Holds the ChatGPT sign-in: runs the browser flow, keeps the access token in memory, and
/// refreshes it ahead of expiry. The refresh token and the issued client id are kept in the
/// Keychain. The access token is never written anywhere.
public actor ChatGPTAuthenticator {
    public static let refreshTokenKey = "chatgpt-refresh-token"
    public static let clientIDKey = "chatgpt-client-id"

    private let secrets: any SecretStore
    private let installationID: UUID
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date
    private var credential: ChatGPTSignIn.Credential?
    private var refreshTask: Task<ChatGPTSignIn.Credential, Error>?
    private var pendingListener: OAuthCallbackListener?

    public init(
        secrets: any SecretStore = KeychainSecrets(),
        installationID: UUID,
        transport: any HTTPTransport = URLSessionTransport(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.secrets = secrets
        self.installationID = installationID
        self.transport = transport
        self.now = now
    }

    /// True when a refresh token is stored. The token may still turn out to be revoked.
    public func isSignedIn() -> Bool {
        secrets.read(Self.refreshTokenKey) != nil && secrets.read(Self.clientIDKey) != nil
    }

    /// Runs the browser sign-in. `openBrowser` is called with the authorize URL once the
    /// callback listener is ready. Returns when the tokens are stored.
    public func signIn(openBrowser: @Sendable (URL) async -> Void) async throws {
        cancelSignIn()
        let pkce = ChatGPTSignIn.PKCE.generate()
        let state = ChatGPTSignIn.randomValue()
        let nonce = ChatGPTSignIn.randomValue()
        let listener = try OAuthCallbackListener(expectedState: state)
        pendingListener = listener
        defer {
            listener.stop()
            if pendingListener === listener { pendingListener = nil }
        }
        try await listener.start()
        await openBrowser(ChatGPTSignIn.authorizationURL(
            installationID: installationID, state: state, challenge: pkce.challenge, nonce: nonce))
        let result = try await listener.result()

        var request = Self.tokenRequest()
        request.httpBody = Data(ChatGPTSignIn.authorizationCodeBody(
            code: result.code, verifier: pkce.verifier, clientID: result.clientID).utf8)
        let data = try await sendTokenRequest(request)
        let credential = try ChatGPTSignIn.credential(
            fromTokenResponse: data, clientID: result.clientID, requireIDToken: true, now: now())
        try store(credential)
    }

    /// Stops a sign-in that is waiting for the browser.
    public func cancelSignIn() {
        pendingListener?.stop()
        pendingListener = nil
    }

    public func signOut() {
        cancelSignIn()
        refreshTask?.cancel()
        refreshTask = nil
        credential = nil
        secrets.delete(Self.refreshTokenKey)
        secrets.delete(Self.clientIDKey)
    }

    /// A current access token, refreshed first when it is close to expiry.
    public func accessToken() async throws -> String {
        if let credential, credential.refreshAfter > now() { return credential.accessToken }
        if let refreshTask { return try await refreshTask.value.accessToken }
        guard let refreshToken = secrets.read(Self.refreshTokenKey),
              let clientID = secrets.read(Self.clientIDKey)
        else { throw ChatGPTSignIn.SignInError.notSignedIn }

        let task = Task { [transport, now] in
            var request = Self.tokenRequest()
            request.httpBody = Data(ChatGPTSignIn.refreshBody(refreshToken: refreshToken, clientID: clientID).utf8)
            let data = try await Self.sendTokenRequest(request, transport: transport)
            return try ChatGPTSignIn.credential(
                fromTokenResponse: data, clientID: clientID, requireIDToken: false, now: now())
        }
        refreshTask = task
        defer { refreshTask = nil }
        let fresh = try await task.value
        try store(fresh)
        return fresh.accessToken
    }

    /// Forgets the access token so the next request refreshes it, for example after a 401.
    public func discardAccessToken() {
        credential = nil
    }

    private func store(_ credential: ChatGPTSignIn.Credential) throws {
        self.credential = credential
        try secrets.write(credential.refreshToken, for: Self.refreshTokenKey)
        try secrets.write(credential.clientID, for: Self.clientIDKey)
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
