import CryptoKit
import Foundation

/// The pieces of "Sign in with ChatGPT" that do not touch the network: constants, PKCE,
/// the authorize URL, the callback, and token responses.
///
/// Ported from pi's `packages/ai/src/auth/oauth/openai-chatgpt.ts` and `pkce.ts`. The flow
/// registers this installation as its own OAuth client (the dynamic client id), and the
/// resulting access token is sent directly to api.openai.com. It does not use the Codex
/// client or the chatgpt.com backend.
public enum ChatGPTSignIn {
    /// Every sign-in registers a new client with this id. OpenAI returns the issued client id in the callback.
    public static let dynamicClientID = "dynamic_agent_client"
    public static let agentNameHint = "mac-os-agent"
    public static let authorizeURL = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    public static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
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

    public struct Credential: Sendable, Equatable {
        public var accessToken: String
        public var refreshToken: String
        /// When to refresh: the real expiry less `expiryMargin`.
        public var refreshAfter: Date
        public var clientID: String
        public var scopes: [String]
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
    public static func authorizationURL(installationID: UUID, state: String, challenge: String, nonce: String) -> URL {
        let query = FormEncoding.encode([
            ("client_id", dynamicClientID),
            ("agent_name_hint", agentNameHint),
            ("ext_agent_host_id", agentHostID(installationID)),
            ("response_type", "code"),
            ("redirect_uri", redirectURI),
            ("resource", resource),
            ("scope", scope),
            ("state", state),
            ("code_challenge", challenge),
            ("code_challenge_method", "S256"),
            ("nonce", nonce),
        ])
        return URL(string: authorizeURL.absoluteString + "?" + query)!
    }

    /// Reads the browser's redirect to the callback. Throws when OpenAI reported an error,
    /// a field is missing, or the state does not match the one this sign-in sent.
    public static func authorizationResult(callback: URL, expectedState: String) throws -> AuthorizationResult {
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
        guard let clientID = value("client_id")?.trimmingCharacters(in: .whitespaces), !clientID.isEmpty else {
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
        if requireIDToken {
            guard let idToken = object["id_token"]?.stringValue, !idToken.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw SignInError.invalidTokenResponse("did not contain an ID token")
            }
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
            scopes: scopes)
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
