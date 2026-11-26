import Foundation
import Synchronization

/// Models served by Ollama on this Mac, behind the local models experiment.
///
/// Ollama answers the same Responses API requests the OpenAI provider sends, at
/// `/v1/responses`, with the same stream events, so a local model goes through
/// `OpenAIResponsesProvider` with another base URL and no sign-in. Checked against Ollama
/// 0.40.17 on 2026-11-24 (MAC-23).
public enum Ollama {
    public static let providerName = "ollama"
    public static let baseURL = URL(string: "http://localhost:11434")!
    /// Model setting ids for a local model start with this, as in `ollama/inkling-2-mini`.
    public static let idPrefix = "ollama/"

    /// The setting id for an Ollama model name.
    public static func modelID(_ name: String) -> String { idPrefix + name }

    /// The Ollama model name in a setting id, or nil for an OpenAI model.
    public static func modelName(fromID id: String) -> String? {
        id.hasPrefix(idPrefix) ? String(id.dropFirst(idPrefix.count)) : nil
    }

    /// How a local model is named in pickers, the menu, and the footer.
    public static func displayName(_ name: String) -> String {
        let shown = name.hasSuffix(":latest") ? String(name.dropLast(":latest".count)) : name
        return "\(shown) (Ollama)"
    }

    /// The installed models, from `/api/tags`, sorted by name. Empty when Ollama is not running.
    public static func installedModels(
        baseURL: URL = baseURL, transport: any HTTPTransport = URLSessionTransport()
    ) async -> [String] {
        names(fromTags: await tags(baseURL: baseURL, transport: transport))
    }

    /// `/api/tags` as read, or nil when Ollama is not running.
    static func tags(baseURL: URL = baseURL, transport: any HTTPTransport) async -> JSONValue? {
        var request = URLRequest(url: baseURL.appending(path: "api/tags"))
        request.timeoutInterval = 3
        guard let (data, response) = try? await transport.send(request), response.statusCode == 200 else { return nil }
        return JSONValue.parse(String(decoding: data, as: UTF8.self))
    }

    static func names(fromTags tags: JSONValue?) -> [String] {
        (tags?["models"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }.sorted()
    }

    /// What each installed model says it can do, from the `capabilities` that `/api/tags` lists
    /// beside each model, such as `["completion", "vision", "tools"]`. Checked against Ollama
    /// 0.40.17 on 2026-11-25 (MAC-54). A model listed without any is left out, as unknown.
    public static func capabilities(
        baseURL: URL = baseURL, transport: any HTTPTransport = URLSessionTransport()
    ) async -> [String: [String]] {
        capabilities(fromTags: await tags(baseURL: baseURL, transport: transport))
    }

    static func capabilities(fromTags tags: JSONValue?) -> [String: [String]] {
        var found: [String: [String]] = [:]
        for model in tags?["models"]?.arrayValue ?? [] {
            guard let name = model["name"]?.stringValue, let list = model["capabilities"]?.arrayValue else { continue }
            found[name] = list.compactMap(\.stringValue)
        }
        return found
    }

    /// The capability Ollama names for reading images.
    public static let visionCapability = "vision"
}

/// Whether the model the next reply goes to can read images. OpenAI's models here all can. A
/// local model can when Ollama lists `vision` for it, cannot when Ollama lists its capabilities
/// without it, and is not known otherwise, as when Ollama is not running or is too old to say.
public enum ImageInput {
    public static func isSupported(modelID: String, localCapabilities: [String: [String]]) -> Bool? {
        guard let name = Ollama.modelName(fromID: modelID) else { return true }
        guard let capabilities = localCapabilities[name] else { return nil }
        return capabilities.contains(Ollama.visionCapability)
    }

    /// What the panel says by the field when the model cannot read images, and nothing is sent.
    public static func unsupportedMessage(modelID: String) -> String {
        "\(ModelSetting.displayName(id: modelID)) cannot read images. Remove them, or choose another model."
    }
}

/// The installed local models as last read, for the menu and Settings, which draw without
/// waiting. `refresh()` reads them again.
public final class LocalModelList: Sendable {
    private let names = Mutex<[String]>([])
    private let capabilityLists = Mutex<[String: [String]]>([:])
    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    public var models: [String] { names.withLock { $0 } }
    /// What each model said it can do when the list was last read. See `Ollama.capabilities`.
    public var capabilities: [String: [String]] { capabilityLists.withLock { $0 } }

    @discardableResult
    public func refresh() async -> [String] {
        let tags = await Ollama.tags(transport: transport)
        let found = Ollama.names(fromTags: tags)
        let capabilities = Ollama.capabilities(fromTags: tags)
        names.withLock { $0 = found }
        capabilityLists.withLock { $0 = capabilities }
        return found
    }
}

extension ModelSetting {
    /// The model the next reply uses: the setting, unless it names a local model while the
    /// local models experiment is off, when it is the default OpenAI model. The setting itself
    /// is kept, so turning the switch back on returns to the local model.
    public static func effective(_ defaults: UserDefaults = .standard) -> String {
        let id = current(defaults)
        if Ollama.modelName(fromID: id) != nil, !Experiment.localModelsThroughOllama.isOn(defaults) {
            return OpenAIModel.defaultID
        }
        return id
    }

    /// A model's name for display, whether it is an OpenAI model, a local one, or neither.
    public static func displayName(id: String) -> String {
        if let name = Ollama.modelName(fromID: id) { return Ollama.displayName(name) }
        return OpenAIModel.all.first { $0.id == id }?.name ?? id
    }
}
