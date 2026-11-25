import Foundation

/// How a run reaches its models.
///
/// - A release build, the one with the update feed, signs in with ChatGPT itself and calls
///   api.openai.com and Ollama directly. That is unchanged by `--data-folder`.
/// - A development build has no sign-in of its own. It sends every model request through
///   inference-gateway on this Mac, which holds the sign-in for all the owner's apps. That
///   includes a run with `--data-folder`.
///
/// It is the same signal `SecretStorage` uses to tell the two builds apart.
public enum ModelAccess: Equatable, Sendable {
    case signIn
    case gateway

    public static func forBuild(hasFeed: Bool) -> ModelAccess {
        hasFeed ? .signIn : .gateway
    }

    /// The access for this run of the app, from its Info.plist.
    public static func forThisRun(bundle: Bundle = .main) -> ModelAccess {
        forBuild(hasFeed: AppUpdates.hasFeed(bundle.infoDictionary))
    }
}

/// inference-gateway, the local server a development build sends its model requests to. It
/// adds the sign-in itself, so a request carries no credentials. Its code is in
/// `~/dev/inference-gateway`.
public enum InferenceGateway {
    public static let baseURL = URL(string: "http://127.0.0.1:47811")!
    /// The header a caller names itself with, and this app's name in it.
    public static let clientHeader = "X-Client-App"
    public static let clientName = "mac-os-agent"

    /// Where OpenAI requests go. The gateway sends `/openai/...` to `https://api.openai.com/v1/...`.
    public static func openAIBaseURL(_ base: URL = baseURL) -> URL { base.appending(path: "openai") }

    /// Where Ollama requests go. The gateway sends `/ollama/...` to `http://127.0.0.1:11434/...`.
    public static func ollamaBaseURL(_ base: URL = baseURL) -> URL { base.appending(path: "ollama") }

    /// The address in a few words, such as `http://127.0.0.1:47811`.
    public static func address(_ base: URL = baseURL) -> String {
        "http://\(base.host() ?? "127.0.0.1"):\(base.port ?? 47811)"
    }

    /// What the owner sees when nothing answers at the gateway's address.
    public static func notRunningMessage(_ base: URL = baseURL) -> String {
        "inference-gateway is not running on \(base.host() ?? "127.0.0.1"):\(base.port ?? 47811). Its launchd agent, dev.lubelski.inference-gateway, starts it. scripts/install.sh in ~/dev/inference-gateway installs the agent."
    }

    /// The gateway's own message when it answers 503 because it has no sign-in, or nil for any
    /// other answer. Its body is shaped like an OpenAI error, with the type
    /// `authentication_error`. An error from OpenAI passes through the gateway unchanged and
    /// returns nil here.
    static func notSignedInMessage(status: Int, body: String) -> String? {
        guard status == 503, let error = JSONValue.parse(body)?["error"],
              error["type"]?.stringValue == "authentication_error",
              let message = error["message"]?.stringValue
        else { return nil }
        return message
    }
}
