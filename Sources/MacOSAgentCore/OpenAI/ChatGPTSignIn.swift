import CryptoKit
import Foundation

/// The pieces of "Sign in with ChatGPT" that do not touch the network: constants, PKCE,
/// the authorize URL, the callback, and token responses.
///
/// Ported from pi's `packages/ai/src/auth/oauth/openai-chatgpt.ts` and `pkce.ts`, and brought
/// in line with OpenAI's documentation for open-source apps
/// (https://developers.openai.com/siwc/token-sharing-open-source). The first sign-in registers
/// this installation as its own OAuth client through the dynamic client id, and later sign-ins
/// to the same account reuse the client id OpenAI issued. The access token is sent directly to
/// api.openai.com. It does not use the Codex client or the chatgpt.com backend.
public enum ChatGPTSignIn {
    /// The entry point for a first registration only. OpenAI returns the issued client id in the
    /// callback, and that is the id to keep and use from then on.
    public static let dynamicClientID = "dynamic_agent_client"
    public static let agentNameHint = "mac-os-agent"
    public static let authorizeURL = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    public static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    public static let issuer = "https://auth.openai.com"
    /// Where the revocation endpoint is published. The docs say to read it from here.
    public static let discoveryURL = URL(string: "https://auth.openai.com/.well-known/openid-configuration")!
    public static let resource = "https://api.openai.com/v1"
    public static let callbackHost = "127.0.0.1"
    public static let callbackPort: UInt16 = 1455
    public static let callbackPath = "/auth/callback"
    public static let redirectURI = "http://127.0.0.1:1455/auth/callback"
    public static let directTokenScope = "chatgpt.tokens.use.direct"
    public static let scope = "openid profile email offline_access resource.invoke \(directTokenScope)"
    /// Refresh this long before the real expiry, so a request never starts with a token about to expire.
    public static let expiryMargin: TimeInterval = 3 * 60

    public struct PKCE: Sendable, Equatable {
        public var verifier: String
        public var challenge: String

        /// A random 32-byte verifier and its SHA-256 challenge, both base64url without padding.
        public static func generate() -> PKCE {
            from(verifier: base64URL(randomBytes(32)))
        }

        public static func from(verifier: String) -> PKCE {
            let digest = SHA256.hash(data: Data(verifier.utf8))
            return PKCE(verifier: verifier, challenge: base64URL(Data(digest)))
        }
    }

    public struct AuthorizationResult: Sendable, Equatable {
        public var code: String
        public var clientID: String
    }

    /// This installation's registration with OpenAI for one ChatGPT account: the issued client
    /// id, and the account it was issued for. It is kept apart from the tokens, so signing out
    /// removes the tokens and keeps this for the next sign-in.
    public struct Registration: Sendable, Equatable {
        public var clientID: String
        /// The `sub` of the account's ID token. Nil for a registration kept before the app read
        /// it, which takes the subject of its next sign-in.
        public var subject: String?
        /// The account's email, sent as `login_hint` on the next sign-in.
        public var email: String?

        public init(clientID: String, subject: String? = nil, email: String? = nil) {
            self.clientID = clientID
            self.subject = subject
            self.email = email
        }
    }

    public struct Credential: Sendable, Equatable {
        public var accessToken: String
        public var refreshToken: String
        /// When to refresh: the real expiry less `expiryMargin`.
        public var refreshAfter: Date
        public var clientID: String
        public var scopes: [String]
        /// The ID token, when the response had one. It is kept with the tokens for `id_token_hint`.
        public var idToken: String? = nil
    }

    /// What the app reads from an ID token: who signed in.
    public struct IDTokenClaims: Sendable, Equatable {
        public var subject: String
        public var email: String?
    }

    public enum SignInError: Error, Equatable, LocalizedError {
        case missingCode
        case missingState
        case stateMismatch
        case missingClientID
        case authorizationFailed(String)
        case invalidTokenResponse(String)
        case missingDirectScope
        case tokenRequestFailed(status: Int, body: String)
        case portInUse
        case notSignedIn
        case cancelled
        /// A sign-in that reused a client id got a callback naming another one.
        case clientIDMismatch
        case invalidIDToken(String)
        /// A sign-in that reused this installation's registration came back as another account.
        case differentAccount

        public var errorDescription: String? {
            switch self {
            case .missingCode: "Missing authorization code"
            case .missingState: "Missing OAuth state"
            case .stateMismatch: "OAuth state mismatch"
            case .missingClientID: "OpenAI OAuth registration callback did not contain an issued client ID"
            case .authorizationFailed(let error): "ChatGPT authorization failed: \(error)"
            case .invalidTokenResponse(let detail): "OpenAI OAuth token response \(detail)"
            case .missingDirectScope: "OpenAI OAuth grant did not include \(directTokenScope)"
            case .tokenRequestFailed(let status, let body): "OpenAI OAuth token request failed (\(status)): \(body)"
            case .portInUse:
                "Port \(callbackPort) is in use, probably by an unfinished sign-in in another app such as the Codex CLI. Cancel that sign-in and try again."
            case .notSignedIn: "Not signed in to ChatGPT"
            case .cancelled: "Sign-in cancelled"
            case .clientIDMismatch: "OpenAI returned a different client ID from the one this sign-in used, so it was not accepted. Try again."
            case .invalidIDToken(let detail): "OpenAI's ID token \(detail)"
            case .differentAccount:
                "The browser signed in to a different ChatGPT account from the one this Mac is registered with, so nothing was changed. Sign in again with the account you used before, or choose Use a Different Account in Settings, General."
            }
        }
    }

    /// OpenAI identifies each installation ("agent host") by a URI such as `urn:uuid:<uuid>`.
    public static func agentHostID(_ installationID: UUID) -> String {
        "urn:uuid:\(installationID.uuidString.lowercased())"
    }

    /// 32 random bytes, base64url, used for `state` and `nonce`.
    public static func randomValue() -> String {
        base64URL(randomBytes(32))
    }

    /// The browser URL that starts sign-in. The parameters and their order match pi.
    ///
    /// With no registration it is a first registration: `dynamic_agent_client` and
    /// `agent_name_hint`. With one it is a reauthorization: the issued client id, no
    /// `agent_name_hint`, and the account's email as `login_hint` and a retained ID token as
    /// `id_token_hint` when there are any. The host id is the same either way.
    public static func authorizationURL(
        installationID: UUID, state: String, challenge: String, nonce: String,
        registration: Registration? = nil, idTokenHint: String? = nil
    ) -> URL {
        var pairs: [(String, String)] = [("client_id", registration?.clientID ?? dynamicClientID)]
        if registration == nil { pairs.append(("agent_name_hint", agentNameHint)) }
        pairs += [
            ("ext_agent_host_id", agentHostID(installationID)),
            ("response_type", "code"),
            ("redirect_uri", redirectURI),
            ("resource", resource),
            ("scope", scope),
            ("state", state),
            ("code_challenge", challenge),
            ("code_challenge_method", "S256"),
            ("nonce", nonce),
        ]
        if let registration {
            if let email = registration.email, !email.isEmpty { pairs.append(("login_hint", email)) }
            if let idTokenHint, !idTokenHint.isEmpty { pairs.append(("id_token_hint", idTokenHint)) }
        }
        return URL(string: authorizeURL.absoluteString + "?" + FormEncoding.encode(pairs))!
    }

    /// True for a client id OpenAI could have issued: not the dynamic entry point, and only
    /// letters, digits, `_`, and `-`.
    static func isIssuedClientID(_ id: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        return !id.isEmpty && id.count <= 200 && id != dynamicClientID && id.allSatisfy(allowed.contains)
    }

    /// Reads the browser's redirect to the callback. Throws when OpenAI reported an error,
    /// a field is missing, or the state does not match the one this sign-in sent.
    /// - Parameter savedClientID: The issued client id a reauthorization sent. Its callback may
    ///   leave `client_id` out, and one that names a different id is refused.
    public static func authorizationResult(
        callback: URL, expectedState: String, savedClientID: String? = nil
    ) throws -> AuthorizationResult {
        var components = URLComponents(url: callback, resolvingAgainstBaseURL: false)
        // Read `+` as a space, as URLSearchParams does.
        let query = components?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%20")
        components?.percentEncodedQuery = query
        let items = components?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }
        if let error = value("error") { throw SignInError.authorizationFailed(error) }
        guard let code = value("code"), !code.isEmpty else { throw SignInError.missingCode }
        guard let state = value("state"), !state.isEmpty else { throw SignInError.missingState }
        guard state == expectedState else { throw SignInError.stateMismatch }
        let returned = value("client_id")?.trimmingCharacters(in: .whitespaces)
        if let savedClientID {
            if let returned, !returned.isEmpty, returned != savedClientID { throw SignInError.clientIDMismatch }
            return AuthorizationResult(code: code, clientID: savedClientID)
        }
        guard let clientID = returned, isIssuedClientID(clientID) else {
            throw SignInError.missingClientID
        }
        return AuthorizationResult(code: code, clientID: clientID)
    }

    /// The form body that trades the authorization code for tokens.
    public static func authorizationCodeBody(code: String, verifier: String, clientID: String) -> String {
        FormEncoding.encode([
            ("grant_type", "authorization_code"),
            ("client_id", clientID),
            ("code", code),
            ("code_verifier", verifier),
            ("redirect_uri", redirectURI),
            ("resource", resource),
        ])
    }

    /// The form body that revokes the renewable session at sign-out.
    public static func revocationBody(refreshToken: String, clientID: String) -> String {
        FormEncoding.encode([
            ("token", refreshToken),
            ("token_type_hint", "refresh_token"),
            ("client_id", clientID),
        ])
    }

    /// Reads `revocation_endpoint` from the OpenID configuration. It has to be an https address
    /// on OpenAI's issuer, so a tampered document cannot send the refresh token elsewhere.
    public static func revocationEndpoint(fromDiscovery data: Data) -> URL? {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              json["issuer"]?.stringValue == issuer,
              let text = json["revocation_endpoint"]?.stringValue,
              let url = URL(string: text), url.scheme == "https", url.host() == "auth.openai.com"
        else { return nil }
        return url
    }

    /// The form body that trades a refresh token for new tokens.
    public static func refreshBody(refreshToken: String, clientID: String) -> String {
        FormEncoding.encode([
            ("grant_type", "refresh_token"),
            ("client_id", clientID),
            ("refresh_token", refreshToken),
            ("resource", resource),
        ])
    }

    /// Checks a token response and turns it into a credential.
    /// - Parameter requireIDToken: true for the code exchange, where an ID token must be present.
    public static func credential(
        fromTokenResponse data: Data, clientID: String, requireIDToken: Bool, now: Date = Date()
    ) throws -> Credential {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data), case .object(let object) = json else {
            throw SignInError.invalidTokenResponse("must be an object")
        }
        func requireString(_ field: String) throws -> String {
            guard let value = object[field]?.stringValue, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SignInError.invalidTokenResponse("has invalid \(field)")
            }
            return value
        }
        let idToken = object["id_token"]?.stringValue.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        if requireIDToken, idToken == nil {
            throw SignInError.invalidTokenResponse("did not contain an ID token")
        }
        let access = try requireString("access_token")
        let refresh = try requireString("refresh_token")
        let scope = try requireString("scope")
        guard let expiresIn = object["expires_in"]?.numberValue, expiresIn.isFinite, expiresIn > 0 else {
            throw SignInError.invalidTokenResponse("has invalid expires_in")
        }
        let scopes = scope.split(whereSeparator: \.isWhitespace).map(String.init)
        guard scopes.contains(directTokenScope) else { throw SignInError.missingDirectScope }
        return Credential(
            accessToken: access,
            refreshToken: refresh,
            refreshAfter: now.addingTimeInterval(expiresIn - expiryMargin),
            clientID: clientID,
            scopes: scopes,
            idToken: idToken)
    }

    /// Reads who signed in from an ID token, and checks its issuer, its audience against the
    /// issued client id, its expiry, and the nonce this sign-in sent.
    ///
    /// The token's signature is not checked against OpenAI's published keys. The token comes
    /// straight from the token endpoint over TLS, and the app uses it only to tell accounts
    /// apart, but the docs do ask for the signature check, and it is not built yet.
    public static func idTokenClaims(_ token: String, clientID: String, nonce: String, now: Date = Date()) throws -> IDTokenClaims {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let payload = base64URLDecode(String(parts[1])),
              let json = try? JSONDecoder().decode(JSONValue.self, from: payload), case .object(let claims) = json
        else { throw SignInError.invalidIDToken("could not be read") }
        guard claims["iss"]?.stringValue == issuer else { throw SignInError.invalidIDToken("has the wrong issuer") }
        let audience: [String] = switch claims["aud"] {
        case .string(let value): [value]
        case .array(let values): values.compactMap(\.stringValue)
        default: []
        }
        guard audience.contains(clientID) else { throw SignInError.invalidIDToken("is for a different client") }
        guard claims["nonce"]?.stringValue == nonce else { throw SignInError.invalidIDToken("does not match this sign-in") }
        guard let expiry = claims["exp"]?.numberValue, Date(timeIntervalSince1970: expiry) > now.addingTimeInterval(-60) else {
            throw SignInError.invalidIDToken("has expired")
        }
        guard let subject = claims["sub"]?.stringValue, !subject.isEmpty else {
            throw SignInError.invalidIDToken("does not name an account")
        }
        let email = claims["email"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        return IDTokenClaims(subject: subject, email: email)
    }

    static func base64URLDecode(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// `application/x-www-form-urlencoded`, encoded the way the WHATWG `URLSearchParams` does:
/// letters, digits, and `*-._` stay as they are, a space becomes `+`, everything else is percent-encoded.
public enum FormEncoding {
    private static let unreserved: Set<UInt8> = Set(
        Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789*-._".utf8))

    public static func encode(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(encodeComponent($0.0))=\(encodeComponent($0.1))" }.joined(separator: "&")
    }

    public static func encodeComponent(_ text: String) -> String {
        var result = ""
        for byte in text.utf8 {
            if unreserved.contains(byte) {
                result.append(Character(UnicodeScalar(byte)))
            } else if byte == 0x20 {
                result.append("+")
            } else {
                result.append(String(format: "%%%02X", byte))
            }
        }
        return result
    }
}
