import Foundation

/// How the agent searches the web, set in Settings, General and kept in the preferences.
///
/// - `off`, the default: no web search of any kind. The tool list, the request, and the prompt
///   are exactly as they were before web search existed.
/// - `openAI`: OpenAI's hosted web search. The request carries the hosted tool, and the model
///   searches on OpenAI's side. No call comes back to the app.
/// - `brave`: the built-in `search_web` tool, which calls the Brave Search API with the
///   owner's key.
///
/// The tool list is put together once at launch and stays fixed for the run, for the prompt
/// cache, so the setting is read once at launch and a change takes effect at the next one.
public enum WebSearchSetting: String, CaseIterable, Sendable, Identifiable {
    case off
    case openAI = "openai"
    case brave

    public static let key = "webSearch"

    public var id: String { rawValue }

    public static func current(_ defaults: UserDefaults = .standard) -> WebSearchSetting {
        defaults.string(forKey: key).flatMap(WebSearchSetting.init(rawValue:)) ?? .off
    }

    public static func set(_ value: WebSearchSetting, _ defaults: UserDefaults = .standard) {
        defaults.set(value.rawValue, forKey: key)
    }

    /// The name in the picker.
    public var title: String {
        switch self {
        case .off: "Off"
        case .openAI: "OpenAI"
        case .brave: "Brave Search"
        }
    }

    /// What the choice does, in one line for Settings.
    public var explanation: String {
        switch self {
        case .off: "The agent does not search the web."
        case .openAI: "The model searches on OpenAI's side with your ChatGPT sign-in."
        case .brave: "The agent calls the Brave Search API with your key."
        }
    }

    /// The line Settings shows when the stored choice differs from what this run launched with.
    public static let nextLaunchNote = "Takes effect the next time mac-os-agent launches."

    /// Whether the request asks for the provider's hosted web search.
    public var usesHostedSearch: Bool { self == .openAI }
}

extension ToolSource {
    public static let webSearch = ToolSource(id: "web-search", title: "Web Search")
}
