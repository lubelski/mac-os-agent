import Foundation
import Testing
@testable import MacOSAgentCore

@Suite struct ChatGPTSignInTests {
    private let installationID = UUID(uuidString: "E61BBE28-07EF-466D-8E5D-A344F94AB305")!

    private func query(_ url: URL) -> [(String, String)] {
        (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }
    }

    // MARK: PKCE

    @Test func pkceMatchesTheRFC7636Example() {
        let pkce = ChatGPTSignIn.PKCE.from(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func pkceVerifiersAreRandomBase64URL() {
        let first = ChatGPTSignIn.PKCE.generate()
        let second = ChatGPTSignIn.PKCE.generate()
        #expect(first.verifier != second.verifier)
        #expect(first.verifier.count == 43)
        #expect(first.challenge.count == 43)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        #expect(first.verifier.unicodeScalars.allSatisfy(allowed.contains))
        #expect(ChatGPTSignIn.PKCE.from(verifier: first.verifier) == first)
    }

    // MARK: Authorize URL

    @Test func theAuthorizeURLCarriesPisParametersInPisOrder() {
        let url = ChatGPTSignIn.authorizationURL(installationID: installationID, state: "state-1", challenge: "challenge-1", nonce: "nonce-1")
        #expect(url.absoluteString.hasPrefix("https://auth.openai.com/api/accounts/authorize?"))
        let pairs = query(url)
        #expect(pairs.map(\.0) == [
            "client_id", "agent_name_hint", "ext_agent_host_id", "response_type", "redirect_uri", "resource",
            "scope", "state", "code_challenge", "code_challenge_method", "nonce",
        ])
        let values = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
        #expect(values["client_id"] == "dynamic_agent_client")
        #expect(values["agent_name_hint"] == "mac-os-agent")
        #expect(values["ext_agent_host_id"] == "urn:uuid:e61bbe28-07ef-466d-8e5d-a344f94ab305")
        #expect(values["response_type"] == "code")
        #expect(values["redirect_uri"] == "http://127.0.0.1:1455/auth/callback")
        #expect(values["resource"] == "https://api.openai.com/v1")
        #expect(values["state"] == "state-1")
        #expect(values["code_challenge"] == "challenge-1")
        #expect(values["code_challenge_method"] == "S256")
        #expect(values["nonce"] == "nonce-1")
    }

    @Test func theScopeIsEncodedLikeURLSearchParams() {
        let url = ChatGPTSignIn.authorizationURL(installationID: installationID, state: "s", challenge: "c", nonce: "n")
        #expect(url.absoluteString.contains(
            "&scope=openid+profile+email+offline_access+resource.invoke+chatgpt.tokens.use.direct&"))
        #expect(url.absoluteString.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A1455%2Fauth%2Fcallback"))
    }

    // MARK: Callback

    @Test func aValidCallbackGivesTheCodeAndIssuedClientID() throws {
        let callback = URL(string: "http://127.0.0.1:1455/auth/callback?code=abc&state=s1&client_id=%20oaiapp_123%20")!
        let result = try ChatGPTSignIn.authorizationResult(callback: callback, expectedState: "s1")
        #expect(result == .init(code: "abc", clientID: "oaiapp_123"))
    }

    @Test func callbackProblemsAreRejected() {
        func attempt(_ query: String) -> ChatGPTSignIn.SignInError? {
            do {
                _ = try ChatGPTSignIn.authorizationResult(
                    callback: URL(string: "http://127.0.0.1:1455/auth/callback?\(query)")!, expectedState: "s1")
                return nil
            } catch {
                return error as? ChatGPTSignIn.SignInError
            }
        }
        #expect(attempt("state=s1&client_id=x") == .missingCode)
        #expect(attempt("code=c&client_id=x") == .missingState)
        #expect(attempt("code=c&state=other&client_id=x") == .stateMismatch)
        #expect(attempt("code=c&state=s1") == .missingClientID)
        #expect(attempt("error=access_denied") == .authorizationFailed("access_denied"))
    }

    // MARK: Token requests and responses

    @Test func theCodeExchangeBodyMatchesPi() {
        let body = ChatGPTSignIn.authorizationCodeBody(code: "the code", verifier: "v", clientID: "oaiapp_1")
        #expect(body == "grant_type=authorization_code&client_id=oaiapp_1&code=the+code&code_verifier=v&redirect_uri=http%3A%2F%2F127.0.0.1%3A1455%2Fauth%2Fcallback&resource=https%3A%2F%2Fapi.openai.com%2Fv1")
    }

    @Test func theRefreshBodyMatchesPi() {
        let body = ChatGPTSignIn.refreshBody(refreshToken: "r/1", clientID: "oaiapp_1")
        #expect(body == "grant_type=refresh_token&client_id=oaiapp_1&refresh_token=r%2F1&resource=https%3A%2F%2Fapi.openai.com%2Fv1")
    }

    private func tokenResponse(scope: JSONValue = .string(ChatGPTSignIn.scope), expiresIn: JSONValue = 3600, idToken: JSONValue? = "id") -> Data {
        var object: [String: JSONValue] = [
            "access_token": "access", "refresh_token": "refresh", "expires_in": expiresIn, "scope": scope,
        ]
        if let idToken { object["id_token"] = idToken }
        return Data(JSONValue.object(object).encodedString().utf8)
    }

    @Test func aGoodTokenResponseBecomesACredentialThatRefreshesEarly() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let credential = try ChatGPTSignIn.credential(
            fromTokenResponse: tokenResponse(), clientID: "oaiapp_1", requireIDToken: true, now: now)
        #expect(credential.accessToken == "access")
        #expect(credential.refreshToken == "refresh")
        #expect(credential.clientID == "oaiapp_1")
        #expect(credential.scopes.contains("chatgpt.tokens.use.direct"))
        #expect(credential.refreshAfter == now.addingTimeInterval(3600 - 180))
    }

    @Test func badTokenResponsesAreRejected() {
        func attempt(_ data: Data, requireIDToken: Bool = true) -> ChatGPTSignIn.SignInError? {
            do {
                _ = try ChatGPTSignIn.credential(fromTokenResponse: data, clientID: "c", requireIDToken: requireIDToken)
                return nil
            } catch {
                return error as? ChatGPTSignIn.SignInError
            }
        }
        #expect(attempt(tokenResponse(scope: "openid profile")) == .missingDirectScope)
        #expect(attempt(tokenResponse(expiresIn: 0)) == .invalidTokenResponse("has invalid expires_in"))
        #expect(attempt(tokenResponse(expiresIn: "3600")) == .invalidTokenResponse("has invalid expires_in"))
        #expect(attempt(tokenResponse(idToken: nil)) == .invalidTokenResponse("did not contain an ID token"))
        #expect(attempt(tokenResponse(idToken: nil), requireIDToken: false) == nil)
        #expect(attempt(Data("[]".utf8)) == .invalidTokenResponse("must be an object"))
        #expect(attempt(Data(#"{"access_token":"a","scope":"x","expires_in":1}"#.utf8), requireIDToken: false) == .invalidTokenResponse("has invalid refresh_token"))
    }

    // MARK: Authenticator

    @Test func theAuthenticatorRefreshesAndStoresTheRotatedRefreshToken() async throws {
        let secrets = MemorySecrets([
            ChatGPTAuthenticator.refreshTokenKey: "old-refresh",
            ChatGPTAuthenticator.clientIDKey: "oaiapp_existing",
        ])
        let transport = FakeTransport(body: [
            "access_token": "new-access", "refresh_token": "new-refresh", "expires_in": 3600,
            "scope": .string(ChatGPTSignIn.scope),
        ])
        let authenticator = ChatGPTAuthenticator(secrets: secrets, installationID: installationID, transport: transport)

        #expect(try await authenticator.accessToken() == "new-access")
        #expect(try await authenticator.accessToken() == "new-access")
        #expect(transport.requests.count == 1)
        let request = try #require(transport.requests.first)
        #expect(request.url == ChatGPTSignIn.tokenURL)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            == ChatGPTSignIn.refreshBody(refreshToken: "old-refresh", clientID: "oaiapp_existing"))
        #expect(secrets.read(ChatGPTAuthenticator.refreshTokenKey) == "new-refresh")
        #expect(secrets.read(ChatGPTAuthenticator.clientIDKey) == "oaiapp_existing")
    }

    @Test func aTokenNearExpiryIsRefreshedAgain() async throws {
        let secrets = MemorySecrets([
            ChatGPTAuthenticator.refreshTokenKey: "r", ChatGPTAuthenticator.clientIDKey: "c",
        ])
        let transport = FakeTransport(body: [
            "access_token": "a", "refresh_token": "r2", "expires_in": 60, "scope": .string(ChatGPTSignIn.scope),
        ])
        // 60 seconds is inside the three minute margin, so every call refreshes.
        let authenticator = ChatGPTAuthenticator(secrets: secrets, installationID: installationID, transport: transport)
        _ = try await authenticator.accessToken()
        _ = try await authenticator.accessToken()
        #expect(transport.requests.count == 2)
    }

    @Test func signingOutForgetsTheStoredTokens() async throws {
        let secrets = MemorySecrets([
            ChatGPTAuthenticator.refreshTokenKey: "r", ChatGPTAuthenticator.clientIDKey: "c",
        ])
        let authenticator = ChatGPTAuthenticator(secrets: secrets, installationID: installationID, transport: FakeTransport(body: [:]))
        #expect(await authenticator.isSignedIn())
        await authenticator.signOut()
        #expect(await !authenticator.isSignedIn())
        await #expect(throws: ChatGPTSignIn.SignInError.notSignedIn) { try await authenticator.accessToken() }
    }

    @Test func aFailedRefreshReportsTheStatus() async {
        let secrets = MemorySecrets([
            ChatGPTAuthenticator.refreshTokenKey: "r", ChatGPTAuthenticator.clientIDKey: "c",
        ])
        let transport = FakeTransport(status: 400, body: ["error": "invalid_grant"])
        let authenticator = ChatGPTAuthenticator(secrets: secrets, installationID: installationID, transport: transport)
        await #expect(throws: ChatGPTSignIn.SignInError.tokenRequestFailed(status: 400, body: #"{"error":"invalid_grant"}"#)) {
            try await authenticator.accessToken()
        }
    }
}

/// These bind the real callback port, so they run one at a time.
@Suite(.serialized) struct OAuthCallbackListenerTests {

    @Test func theListenerAcceptsTheBrowserRedirect() async throws {
        let listener = try OAuthCallbackListener(expectedState: "s1")
        do {
            try await listener.start()
        } catch ChatGPTSignIn.SignInError.portInUse {
            // Something else on this Mac holds 1455. That is the case the error exists for.
            return
        }
        defer { listener.stop() }

        let (wrongData, wrongResponse) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:1455/auth/callback?code=c&state=other&client_id=x")!)
        #expect((wrongResponse as? HTTPURLResponse)?.statusCode == 400)
        #expect(String(decoding: wrongData, as: UTF8.self).contains("OAuth state mismatch"))

        let (_, notFound) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:1455/elsewhere")!)
        #expect((notFound as? HTTPURLResponse)?.statusCode == 404)

        let (_, response) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:1455/auth/callback?code=the-code&state=s1&client_id=oaiapp_9")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(try await listener.result() == .init(code: "the-code", clientID: "oaiapp_9"))
    }

    @Test func aSecondListenerReportsThePortInUse() async throws {
        let first = try OAuthCallbackListener(expectedState: "a")
        do {
            try await first.start()
        } catch ChatGPTSignIn.SignInError.portInUse {
            return
        }
        defer { first.stop() }
        let second = try OAuthCallbackListener(expectedState: "b")
        defer { second.stop() }
        await #expect(throws: ChatGPTSignIn.SignInError.portInUse) { try await second.start() }
    }
}
