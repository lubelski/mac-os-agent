import Foundation

/// The agent's name, kept in the app's preferences and set in Settings, General. It is what
/// the default instructions call the agent, what the panel's top bar shows, and what Settings
/// says where running text would otherwise say "the agent". The app, the bundle, the menu bar
/// item, the folders, and error messages keep the name mac-os-agent.
///
/// A blank name is the default name, so the agent is never nameless. The name is part of the
/// instructions, so changing it starts the prompt cache over from the next request. It is read
/// once per request, so it stays the same through a request's tool calls.
public enum AgentNameSetting {
    public static let key = "agentName"
    public static let defaultName = "Iris"

    /// The name to use for what is stored: the default when it is missing or blank, and
    /// otherwise the stored text on one line, without the spaces around it.
    public static func resolve(_ stored: String?) -> String {
        let name = (stored ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return name.isEmpty ? defaultName : name
    }

    public static func current(_ defaults: UserDefaults = .standard) -> String {
        resolve(defaults.string(forKey: key))
    }

    public static func set(_ name: String, _ defaults: UserDefaults = .standard) {
        defaults.set(name, forKey: key)
    }
}
