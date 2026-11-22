import Foundation

/// OpenAI models the app offers. The ids come from pi's catalog
/// (`packages/ai/catalog/providers/openai.ts` and `families/openai.ts`), November 2026.
public struct OpenAIModel: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String

    public static let all: [OpenAIModel] = [
        OpenAIModel(id: "gpt-6-luna", name: "GPT-6 Luna"),
        OpenAIModel(id: "gpt-6.1-terra", name: "GPT-6.1 Terra"),
        OpenAIModel(id: "gpt-6-sol", name: "GPT-6 Sol"),
        OpenAIModel(id: "gpt-6.1-sol", name: "GPT-6.1 Sol"),
        OpenAIModel(id: "gpt-5.6-luna", name: "GPT-5.6 Luna"),
    ]

    /// The smallest and fastest GPT-6 model. Speed matters more than depth for this agent.
    public static let defaultID = "gpt-6-luna"

    /// Reasoning effort sent with every request. All of the models above accept "low".
    public static let defaultReasoningEffort = "low"
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
