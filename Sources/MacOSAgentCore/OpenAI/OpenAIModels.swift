import Foundation

/// OpenAI models the app offers: the GPT-6 family, and GPT-5.6 Luna from the family before it.
/// The ids and names come from pi's catalog (`packages/ai/catalog/providers/openai.ts`,
/// `providers/openai-codex.ts`, and `families/openai.ts`) at commit 9c4652688, November 2026.
/// Nobody has checked which of them a "Sign in with ChatGPT" token may use on each plan.
public struct OpenAIModel: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String

    /// In picker order: fastest tier to most capable (Luna, Terra, Sol, Astra), the newest
    /// version first within a tier, and the older family last.
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

    /// Reasoning effort sent with every request. All of the models above accept "low".
    /// Astra, GPT-6.1 Sol, and GPT-6.2 Sol reject "none", and every GPT-6 model rejects
    /// "minimal", so do not lower this without making it a per-model value.
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
