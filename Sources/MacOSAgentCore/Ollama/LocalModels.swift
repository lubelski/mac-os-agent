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
        var request = URLRequest(url: baseURL.appending(path: "api/tags"))
        request.timeoutInterval = 3
        guard let (data, response) = try? await transport.send(request), response.statusCode == 200,
              let tags = JSONValue.parse(String(decoding: data, as: UTF8.self))
        else { return [] }
        return (tags["models"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }.sorted()
    }
}

/// The installed local models as last read, for the menu and Settings, which draw without
/// waiting. `refresh()` reads them again.
public final class LocalModelList: Sendable {
    private let names = Mutex<[String]>([])
    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    public var models: [String] { names.withLock { $0 } }

    @discardableResult
    public func refresh() async -> [String] {
        let found = await Ollama.installedModels(transport: transport)
        names.withLock { $0 = found }
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
