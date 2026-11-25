import Foundation

/// An OpenAI model the app offers.
///
/// The models offered come from the signed-in account's own list, `GET /v1/models` with the
/// same access token, as OpenAI's docs for Sign in with ChatGPT describe
/// (https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference). That
/// list is what the token may use on the owner's plan. `all` is the fallback, for when no one is
/// signed in or the list could not be read.
public struct OpenAIModel: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    /// The fallback list: the GPT-6 family, and GPT-5.6 Luna from the family before it. The ids
    /// and names come from pi's catalog (`packages/ai/catalog/providers/openai.ts`,
    /// `providers/openai-codex.ts`, and `families/openai.ts`) at commit 9c4652688, November
    /// 2026. In picker order: fastest tier to most capable (Luna, Terra, Sol, Astra), the
    /// newest version first within a tier, and the older family last.
    public static let all: [OpenAIModel] = [
        OpenAIModel(id: "gpt-6-luna", name: "GPT-6 Luna"),
        OpenAIModel(id: "gpt-6.1-terra", name: "GPT-6.1 Terra"),
        OpenAIModel(id: "gpt-6.2-sol", name: "GPT-6.2 Sol"),
        OpenAIModel(id: "gpt-6.1-sol", name: "GPT-6.1 Sol"),
        OpenAIModel(id: "gpt-6-sol", name: "GPT-6 Sol"),
        OpenAIModel(id: "gpt-6.2-astra", name: "GPT-6.2 Astra"),
        OpenAIModel(id: "gpt-6-astra", name: "GPT-6 Astra"),
        OpenAIModel(id: "gpt-5.6-luna", name: "GPT-5.6 Luna"),
    ]

    /// The smallest and fastest GPT-6 model. Speed matters more than depth for this agent.
    public static let defaultID = "gpt-6-luna"

    /// Reasoning effort sent with every request, whatever the model. All of the models in `all`
    /// accept "low". Astra, GPT-6.1 Sol, and GPT-6.2 Sol reject "none", and every GPT-6 model
    /// rejects "minimal", so do not lower this without making it a per-model value.
    ///
    /// The account's list can hold models the app has never seen, and it does not say which
    /// efforts each one takes. "low" stays the value for those too: it is the lowest effort
    /// every known model accepts, so it is the one most likely to work, and the request body
    /// stays the same as before for every model. A model that refuses it fails its request
    /// with OpenAI's error, which the panel shows, and the owner can pick another.
    public static let defaultReasoningEffort = "low"

    /// What the model pickers offer.
    /// - Parameters:
    ///   - listed: The account's list, or nil when it has not been read, which offers `all`.
    ///   - current: The saved model. When the list leaves it out it is still offered, after the
    ///     rest, so it stays selected and is never changed behind the owner's back.
    /// - Returns: The models in order, and whether `current` is missing from the account's list.
    ///   That is only ever true for a list read from the account.
    public static func choices(listed: [OpenAIModel]?, current: String) -> (models: [OpenAIModel], currentIsUnlisted: Bool) {
        let models = listed ?? all
        guard !models.contains(where: { $0.id == current }) else { return (models, false) }
        let name = all.first(where: { $0.id == current })?.name ?? current
        return (models + [OpenAIModel(id: current, name: name)], listed != nil)
    }
}

/// Reads the signed-in account's model list.
///
/// `GET https://api.openai.com/v1/models` with the access token. The response has a `models`
/// array, and the models meant for a picker are the ones with `visibility` "list", in the
/// server's order, each with a `slug` to send as the model and a `display_name` to show.
public struct OpenAIModelCatalog: Sendable {
    public static let url = URL(string: "https://api.openai.com/v1/models")!

    public enum CatalogError: Error, Equatable, LocalizedError {
        case http(status: Int)
        case invalidResponse(String)

        public var errorDescription: String? {
            switch self {
            case .http(let status): "OpenAI's model list could not be read (\(status))."
            case .invalidResponse(let detail): "OpenAI's model list \(detail)."
            }
        }
    }

    private let authenticator: ChatGPTAuthenticator
    private let transport: any HTTPTransport

    public init(authenticator: ChatGPTAuthenticator, transport: any HTTPTransport = URLSessionTransport()) {
        self.authenticator = authenticator
        self.transport = transport
    }

    /// The account's models. After a 401 it refreshes the access token once and tries again,
    /// as the Responses provider does.
    public func fetch() async throws -> [OpenAIModel] {
        var attempt = 0
        while true {
            attempt += 1
            var request = URLRequest(url: Self.url)
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("mac-os-agent", forHTTPHeaderField: "User-Agent")
            request.setValue("Bearer \(try await authenticator.accessToken())", forHTTPHeaderField: "Authorization")
            let (data, response) = try await transport.send(request)
            if response.statusCode == 401, attempt == 1 {
                await authenticator.discardAccessToken()
                continue
            }
            guard response.statusCode == 200 else { throw CatalogError.http(status: response.statusCode) }
            return try Self.models(from: data)
        }
    }

    /// The listed models in a `/v1/models` response, in its order. An entry to list with no
    /// slug or name means the response is not what the docs describe, so the whole list is
    /// refused and the fallback stays.
    public static func models(from data: Data) throws -> [OpenAIModel] {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              let entries = json["models"]?.arrayValue
        else { throw CatalogError.invalidResponse("has no models array") }
        var models: [OpenAIModel] = []
        for entry in entries where entry["visibility"]?.stringValue == "list" {
            guard let slug = entry["slug"]?.stringValue?.trimmingCharacters(in: .whitespaces), !slug.isEmpty,
                  let name = entry["display_name"]?.stringValue?.trimmingCharacters(in: .whitespaces), !name.isEmpty
            else { throw CatalogError.invalidResponse("has a model with no slug or name") }
            guard !models.contains(where: { $0.id == slug }) else { continue }
            models.append(OpenAIModel(id: slug, name: name))
        }
        guard !models.isEmpty else { throw CatalogError.invalidResponse("lists no models") }
        return models
    }
}

/// The model setting, kept in the app's preferences.
public enum ModelSetting {
    public static let key = "model"

    public static func current(_ defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: key) ?? OpenAIModel.defaultID
    }

    public static func set(_ id: String, _ defaults: UserDefaults = .standard) {
        defaults.set(id, forKey: key)
    }
}
