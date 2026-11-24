import Foundation

/// A habit from terminal coding agents, such as Claude Code, pi, and Codex, that the panel's text
/// field can follow. Each is a switch in Settings, Behaviors, kept in the app's preferences.
/// The incognito window reads them and never writes them: they say only how keys behave, so
/// they are not a trace.
public enum HarnessBehavior: String, CaseIterable, Sendable, Identifiable {
    /// Up Arrow on the field's first line recalls the owner's earlier messages, and Down Arrow
    /// on its last line comes forward again. See `MessageRecall`.
    case recallEarlierMessages
    /// Control-C stops the running task, or with none running clears the field.
    case controlCStopsOrClears
    /// Delete twice in quick succession in an empty field does what `/new` does. See `DoubleDelete`.
    case doubleDeleteStartsNewEpisode

    public var id: String { rawValue }

    public var key: String {
        switch self {
        case .recallEarlierMessages: "BehaviorUpArrowRecallsMessages"
        case .controlCStopsOrClears: "BehaviorControlCStopsOrClears"
        case .doubleDeleteStartsNewEpisode: "BehaviorDoubleDeleteStartsNewEpisode"
        }
    }

    public var defaultValue: Bool {
        switch self {
        case .recallEarlierMessages: true
        case .controlCStopsOrClears: false
        case .doubleDeleteStartsNewEpisode: true
        }
    }

    public func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil ? defaultValue : defaults.bool(forKey: key)
    }

    public func set(_ on: Bool, _ defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: key)
    }
}

/// A feature being tried, behind a switch in Settings, Experiments. Every experiment is off
/// until the owner turns it on, and may change or go. Kept in the app's preferences.
public enum Experiment: String, CaseIterable, Sendable, Identifiable {
    /// Return while a task runs queues the message, and the queue is sent one message per turn
    /// when the task finishes. See `MessageQueue`.
    case queueMessagesWhileRunning
    /// The instant action and the slash commands are offered in the text field itself, with a
    /// footer under it that says what the keys do, and Down Arrow grows the footer into a short
    /// list of matches. The row above the field is not shown. See `InputFooter`.
    case suggestionsInFieldAndFooter
    /// Tools from MCP servers listed in `mcp-servers.json`, and the MCP Servers section in
    /// Settings. A change takes effect in the tool list at the next launch. See `MCPServerPool`.
    case mcpServers
    /// The panel's frame redrawn as bar, conversation, band: a title bar with the model's name,
    /// "MacOS Agent", and the menu, and a band at the bottom holding the text field as a pill
    /// with the app's logo as its mark, and a status line under it. It uses the suggestions
    /// experiment's gray completion and status line whether or not that switch is on. See
    /// `PanelFrame`.
    case panelWithBarsAndInputPill

    public var id: String { rawValue }

    /// The switch's title in Settings, Experiments.
    public var title: String {
        switch self {
        case .queueMessagesWhileRunning: "Queue messages while a task runs"
        case .suggestionsInFieldAndFooter: "Suggestions in the field and a footer"
        case .mcpServers: "MCP servers"
        case .panelWithBarsAndInputPill: "Panel with bars and an input pill"
        }
    }

    /// Every experiment is off until the owner turns it on.
    public var defaultValue: Bool { false }

    public var key: String {
        switch self {
        case .queueMessagesWhileRunning: "ExperimentQueueMessagesWhileRunning"
        case .suggestionsInFieldAndFooter: "ExperimentSuggestionsInFieldAndFooter"
        case .mcpServers: "ExperimentMCPServers"
        case .panelWithBarsAndInputPill: "ExperimentPanelWithBarsAndInputPill"
        }
    }

    public func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil ? defaultValue : defaults.bool(forKey: key)
    }

    public func set(_ on: Bool, _ defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: key)
    }
}
