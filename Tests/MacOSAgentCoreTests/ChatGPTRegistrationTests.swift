import Foundation
import Testing
@testable import MacOSAgentCore

/// A stand-in for OpenAI's sign-in, token, discovery, revocation, and model endpoints, around
/// a real `ChatGPTAuthenticator`. Nothing here reaches the network.
final class SignInHarness: @unchecked Sendable {
    static let revocationURL = URL(string: "https://auth.openai.com/api/accounts/oauth/revoke")!

    private let lock = NSLock()
    let secrets: MemorySecrets
    private var queries: [String]
    private var opened: [URL] = []
    private var slept: [Duration] = []
    private var revokeAttempts = 0
    /// Who the ID token says signed in.
    var subject = "user-1"
    var email: String? = "owner@example.com"
    /// The answer to each revocation attempt, by attempt. Nil throws a network failure.
    var revocationStatus: @Sendable (Int) -> Int? = { _ in 200 }
    /// A failure for the code exchange, by client id, instead of tokens.
    var exchangeFailure: @Sendable (String) -> (Int, JSONValue)? = { _ in nil }
    var models: JSONValue = ["models": []]
    private(set) lazy var transport = ScriptedTransport { [unowned self] request, _ in try self.answer(request) }
    private(set) lazy var authenticator = ChatGPTAuthenticator(
        secrets: secrets, installationID: UUID(uuidString: "E61BBE28-07EF-466D-8E5D-A344F94AB305")!,
        transport: transport,
        sleep: { [unowned self] duration in self.lock.withLock { self.slept.append(duration) } },
        makeListener: { [unowned self] state, saved in
            let query = self.lock.withLock { self.queries.isEmpty ? "error=no_script" : self.queries.removeFirst() }
            return FakeCallback(state: state, savedClientID: saved, query: query)
        })

    /// - Parameter callbacks: The query of each attempt's callback, without its state.
    init(secrets: [String: String] = [:], callbacks: [String] = []) {
        self.secrets = MemorySecrets(secrets)
        queries = callbacks
    }

    var browserURLs: [URL] { lock.withLock { opened } }
    var sleeps: [Duration] { lock.withLock { slept } }

    func signIn(differentAccount: Bool = false) async throws {
        try await authenticator.signIn(differentAccount: differentAccount) { url in
            self.lock.withLock { self.opened.append(url) }
        }
    }

    func stored(_ key: String) -> String? { secrets.read(key) }

    static func query(_ url: URL) -> [String: String] {
        Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first })
    }

    static func form(_ request: URLRequest) -> [String: String] {
        query(URL(string: "http://x/?" + String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            .replacingOccurrences(of: "+", with: "%20"))!)
    }

    private func answer(_ request: URLRequest) throws -> (Int, Data) {
        switch request.url {
        case ChatGPTSignIn.tokenURL:
            let form = Self.form(request)
            let clientID = form["client_id"] ?? ""
            if form["grant_type"] == "authorization_code", let failure = exchangeFailure(clientID) {
                return (failure.0, failure.1.data)
            }
            let nonce = lock.withLock { opened.last.flatMap { Self.query($0)["nonce"] } } ?? ""
            var claims: [String: JSONValue] = [
                "iss": "https://auth.openai.com", "aud": .string(clientID), "nonce": .string(nonce),
                "exp": .number(Date().timeIntervalSince1970 + 3600), "sub": .string(subject),
            ]
            if let email { claims["email"] = .string(email) }
            return (200, JSONValue.object([
                "access_token": .string("access-\(clientID)"), "refresh_token": .string("refresh-\(clientID)"), "expires_in": 3600,
                "scope": .string(ChatGPTSignIn.scope), "id_token": .string(idToken(.object(claims))),
                "token_type": "Bearer",
            ]).data)
        case ChatGPTSignIn.discoveryURL:
            return (200, JSONValue.object([
                "issuer": "https://auth.openai.com", "revocation_endpoint": .string(Self.revocationURL.absoluteString),
            ]).data)
        case Self.revocationURL:
            let attempt = lock.withLock {
                defer { revokeAttempts += 1 }
                return revokeAttempts
            }
            guard let status = revocationStatus(attempt) else { throw URLError(.networkConnectionLost) }
            return (status, Data())
        case OpenAIModelCatalog.url:
            return (200, models.data)
        default:
            return (404, Data())
        }
    }
}

@Suite struct ChatGPTRegistrationTests {
    private typealias Keys = ChatGPTAuthenticator

    // MARK: Registration

    @Test func theFirstSignInRegistersAndKeepsTheRegistrationApartFromTheTokens() async throws {
        let harness = SignInHarness(callbacks: ["code=c1&client_id=oaiapp_new"])
        try await harness.signIn()

        let url = try #require(harness.browserURLs.first)
        let query = SignInHarness.query(url)
        #expect(query["client_id"] == "dynamic_agent_client")
        #expect(query["agent_name_hint"] == "mac-os-agent")
        #expect(query["login_hint"] == nil)
        #expect(query["id_token_hint"] == nil)

        let exchange = try #require(harness.transport.requests(to: ChatGPTSignIn.tokenURL).first)
        #expect(SignInHarness.form(exchange)["client_id"] == "oaiapp_new")
        #expect(harness.stored(Keys.clientIDKey) == "oaiapp_new")
        #expect(harness.stored(Keys.accountSubjectKey) == "user-1")
        #expect(harness.stored(Keys.accountEmailKey) == "owner@example.com")
        #expect(harness.stored(Keys.refreshTokenKey) == "refresh-oaiapp_new")
        #expect(harness.stored(Keys.idTokenKey) != nil)
        #expect(await harness.authenticator.isSignedIn())
        #expect(try await harness.authenticator.accessToken() == "access-oaiapp_new")
    }

    @Test func aLaterSignInReusesTheIssuedClientWithoutTheNameHint() async throws {
        let harness = SignInHarness(
            secrets: [Keys.clientIDKey: "oaiapp_kept", Keys.accountSubjectKey: "user-1", Keys.accountEmailKey: "owner@example.com"],
            callbacks: ["code=c2"])
        try await harness.signIn()

        let url = try #require(harness.browserURLs.first)
        let pairs = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map(\.name)
        #expect(pairs == [
            "client_id", "ext_agent_host_id", "response_type", "redirect_uri", "resource",
            "scope", "state", "code_challenge", "code_challenge_method", "nonce", "login_hint",
        ])
        let query = SignInHarness.query(url)
        #expect(query["client_id"] == "oaiapp_kept")
        #expect(query["ext_agent_host_id"] == "urn:uuid:e61bbe28-07ef-466d-8e5d-a344f94ab305")
        #expect(query["login_hint"] == "owner@example.com")
        // Signed out, so no ID token is retained to send as a hint.
        #expect(query["id_token_hint"] == nil)

        let exchange = try #require(harness.transport.requests(to: ChatGPTSignIn.tokenURL).first)
        #expect(SignInHarness.form(exchange)["client_id"] == "oaiapp_kept")
        #expect(harness.stored(Keys.clientIDKey) == "oaiapp_kept")
        #expect(harness.stored(Keys.refreshTokenKey) == "refresh-oaiapp_kept")
    }

    @Test func aRetainedIDTokenIsSentAsTheHint() async throws {
        let harness = SignInHarness(
            secrets: [Keys.clientIDKey: "oaiapp_kept", Keys.accountSubjectKey: "user-1", Keys.idTokenKey: "the-old-id-token"],
            callbacks: ["code=c"])
        try await harness.signIn()
        let query = SignInHarness.query(try #require(harness.browserURLs.first))
        #expect(query["id_token_hint"] == "the-old-id-token")
        #expect(query["login_hint"] == nil)
    }

    @Test func anInstallationFromBeforeKeepsWorkingAndRecordsItsAccount() async throws {
        // What an existing installation has: the refresh token and the client id, nothing else.
        let harness = SignInHarness(
            secrets: [Keys.refreshTokenKey: "old-refresh", Keys.clientIDKey: "oaiapp_existing"],
            callbacks: ["code=c3"])
        #expect(await harness.authenticator.isSignedIn())
        #expect(await harness.authenticator.registration() == .init(clientID: "oaiapp_existing"))

        #expect(await harness.authenticator.signOut() == .revoked)
        #expect(await !harness.authenticator.isSignedIn())
        #expect(harness.stored(Keys.clientIDKey) == "oaiapp_existing")

        harness.subject = "user-9"
        try await harness.signIn()
        #expect(SignInHarness.query(try #require(harness.browserURLs.first))["client_id"] == "oaiapp_existing")
        #expect(await harness.authenticator.registration()
            == .init(clientID: "oaiapp_existing", subject: "user-9", email: "owner@example.com"))
        #expect(await harness.authenticator.isSignedIn())
    }

    @Test func aDifferentAccountOnAReusedClientIsNotKept() async throws {
        let harness = SignInHarness(
            secrets: [Keys.clientIDKey: "oaiapp_kept", Keys.accountSubjectKey: "user-1", Keys.accountEmailKey: "owner@example.com"],
            callbacks: ["code=c4"])
        harness.subject = "user-2"
        await #expect(throws: ChatGPTSignIn.SignInError.differentAccount) { try await harness.signIn() }
        #expect(await !harness.authenticator.isSignedIn())
        #expect(harness.stored(Keys.refreshTokenKey) == nil)
        #expect(await harness.authenticator.registration()
            == .init(clientID: "oaiapp_kept", subject: "user-1", email: "owner@example.com"))
    }

    @Test func aCallbackNamingAnotherClientIsRefused() async throws {
        let harness = SignInHarness(
            secrets: [Keys.clientIDKey: "oaiapp_kept", Keys.accountSubjectKey: "user-1"],
            callbacks: ["code=c&client_id=oaiapp_other"])
        await #expect(throws: ChatGPTSignIn.SignInError.clientIDMismatch) { try await harness.signIn() }
        #expect(harness.transport.requests(to: ChatGPTSignIn.tokenURL).isEmpty)
        #expect(harness.stored(Keys.clientIDKey) == "oaiapp_kept")
    }

    @Test func aRejectedClientFallsBackToAFreshRegistration() async throws {
        let harness = SignInHarness(
            secrets: [Keys.clientIDKey: "oaiapp_gone", Keys.accountSubjectKey: "user-1", Keys.accountEmailKey: "owner@example.com"],
            callbacks: ["error=invalid_client", "code=c5&client_id=oaiapp_fresh"])
        try await harness.signIn()

        let urls = harness.browserURLs.map(SignInHarness.query)
        #expect(urls.map { $0["client_id"] } == ["oaiapp_gone", "dynamic_agent_client"])
        #expect(urls.map { $0["agent_name_hint"] } == [nil, "mac-os-agent"])
        #expect(await harness.authenticator.registration()
            == .init(clientID: "oaiapp_fresh", subject: "user-1", email: "owner@example.com"))
        #expect(await harness.authenticator.isSignedIn())
    }

    @Test func aClientTheTokenEndpointRejectsFallsBackToo() async throws {
        let harness = SignInHarness(
            secrets: [Keys.clientIDKey: "oaiapp_gone"],
            callbacks: ["code=c6", "code=c7&client_id=oaiapp_fresh"])
        harness.exchangeFailure = { $0 == "oaiapp_gone" ? (401, ["error": "invalid_client"]) : nil }
        try await harness.signIn()
        #expect(harness.browserURLs.map { SignInHarness.query($0)["client_id"] } == ["oaiapp_gone", "dynamic_agent_client"])
        #expect(harness.stored(Keys.clientIDKey) == "oaiapp_fresh")
        #expect(await harness.authenticator.isSignedIn())
    }

    @Test func aFailedCodeExchangeKeepsTheNewRegistration() async throws {
        let harness = SignInHarness(callbacks: ["code=c8&client_id=oaiapp_new"])
        harness.exchangeFailure = { _ in (400, ["error": "invalid_grant"]) }
        await #expect(throws: (any Error).self) { try await harness.signIn() }
        // The next attempt reuses this client instead of registering another.
        #expect(harness.stored(Keys.clientIDKey) == "oaiapp_new")
        #expect(await !harness.authenticator.isSignedIn())
    }

    @Test func aDifferentAccountRegistersAnewAndReplacesTheRegistration() async throws {
        let harness = SignInHarness(
            secrets: [Keys.clientIDKey: "oaiapp_first", Keys.accountSubjectKey: "user-1", Keys.accountEmailKey: "owner@example.com"],
            callbacks: ["code=c9&client_id=oaiapp_second"])
        harness.subject = "user-2"
        harness.email = nil
        try await harness.signIn(differentAccount: true)
        #expect(SignInHarness.query(try #require(harness.browserURLs.first))["client_id"] == "dynamic_agent_client")
        #expect(await harness.authenticator.registration() == .init(clientID: "oaiapp_second", subject: "user-2"))
    }

    // MARK: Sign-out

    @Test func signingOutRevokesTheRefreshTokenAndKeepsTheRegistration() async throws {
        let harness = SignInHarness(secrets: [
            Keys.refreshTokenKey: "refresh/1", Keys.idTokenKey: "id", Keys.clientIDKey: "oaiapp_1",
            Keys.accountSubjectKey: "user-1", Keys.accountEmailKey: "owner@example.com",
        ])
        #expect(await harness.authenticator.signOut() == .revoked)

        let discovery = try #require(harness.transport.requests(to: ChatGPTSignIn.discoveryURL).first)
        #expect(discovery.httpMethod == "GET")
        let revoke = try #require(harness.transport.requests(to: SignInHarness.revocationURL).first)
        #expect(revoke.httpMethod == "POST")
        #expect(revoke.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(String(decoding: revoke.httpBody ?? Data(), as: UTF8.self)
            == "token=refresh%2F1&token_type_hint=refresh_token&client_id=oaiapp_1")

        #expect(harness.stored(Keys.refreshTokenKey) == nil)
        #expect(harness.stored(Keys.idTokenKey) == nil)
        #expect(await harness.authenticator.registration()
            == .init(clientID: "oaiapp_1", subject: "user-1", email: "owner@example.com"))
        #expect(harness.sleeps.isEmpty)
    }

    @Test func serverErrorsAreRetriedForAShortTimeAndThenReported() async throws {
        let harness = SignInHarness(secrets: [Keys.refreshTokenKey: "secret-refresh", Keys.clientIDKey: "oaiapp_1"])
        harness.revocationStatus = { _ in 503 }
        #expect(await harness.authenticator.signOut() == .notConfirmed)
        #expect(harness.transport.requests(to: SignInHarness.revocationURL).count == 3)
        #expect(harness.sleeps == [.seconds(1), .seconds(2)])
        // Local sign-out happened anyway.
        #expect(await !harness.authenticator.isSignedIn())
        #expect(harness.stored(Keys.refreshTokenKey) == nil)
        let status = await harness.authenticator.status()
        let message = try #require(status.lastError)
        #expect(message.contains("did not confirm"))
        #expect(!message.contains("secret-refresh"))
    }

    @Test func aNetworkFailureIsRetried() async throws {
        let harness = SignInHarness(secrets: [Keys.refreshTokenKey: "r", Keys.clientIDKey: "c"])
        harness.revocationStatus = { $0 == 0 ? nil : 200 }
        #expect(await harness.authenticator.signOut() == .revoked)
        #expect(harness.transport.requests(to: SignInHarness.revocationURL).count == 2)
        #expect(harness.sleeps == [.seconds(1)])
    }

    @Test func aClientErrorIsNotRetried() async throws {
        let harness = SignInHarness(secrets: [Keys.refreshTokenKey: "r", Keys.clientIDKey: "c"])
        harness.revocationStatus = { _ in 400 }
        #expect(await harness.authenticator.signOut() == .notConfirmed)
        #expect(harness.transport.requests(to: SignInHarness.revocationURL).count == 1)
        #expect(harness.sleeps.isEmpty)
    }

    @Test func signingOutWithNoTokenSendsNothing() async throws {
        let harness = SignInHarness(secrets: [Keys.clientIDKey: "c"])
        #expect(await harness.authenticator.signOut() == .nothingToRevoke)
        #expect(harness.transport.requests.isEmpty)
        #expect(harness.stored(Keys.clientIDKey) == "c")
    }

    // MARK: Models

    @Test func theModelListIsReadWithTheAccessToken() async throws {
        let harness = SignInHarness(secrets: [Keys.refreshTokenKey: "r", Keys.clientIDKey: "oaiapp_1"])
        harness.models = ["models": [
            ["slug": "gpt-6.2-sol", "display_name": "GPT-6.2 Sol", "visibility": "list"],
            ["slug": "internal-model", "display_name": "Internal", "visibility": "hide"],
            ["slug": "gpt-6-luna", "display_name": "GPT-6 Luna", "visibility": "list"],
        ]]
        let models = try await OpenAIModelCatalog(authenticator: harness.authenticator, transport: harness.transport).fetch()
        #expect(models == [.init(id: "gpt-6.2-sol", name: "GPT-6.2 Sol"), .init(id: "gpt-6-luna", name: "GPT-6 Luna")])
        let request = try #require(harness.transport.requests(to: OpenAIModelCatalog.url).first)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-oaiapp_1")
    }
}
