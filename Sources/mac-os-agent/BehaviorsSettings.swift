import MacOSAgentCore
import SwiftUI

// MARK: - Behaviors

/// Habits from terminal coding agents, each a switch with a line saying exactly what the keys
/// do. They apply in the main panel and the incognito window. See `HarnessBehavior`.
struct BehaviorsSettingsView: View {
    @AppStorage(HarnessBehavior.recallEarlierMessages.key)
    private var recallsMessages = HarnessBehavior.recallEarlierMessages.defaultValue
    @AppStorage(HarnessBehavior.controlCStopsOrClears.key)
    private var controlCStopsOrClears = HarnessBehavior.controlCStopsOrClears.defaultValue
    @AppStorage(HarnessBehavior.doubleDeleteStartsNewEpisode.key)
    private var doubleDeleteStartsNewEpisode = HarnessBehavior.doubleDeleteStartsNewEpisode.defaultValue

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $recallsMessages) {
                    Text("Up Arrow recalls earlier messages")
                    Text("Up Arrow on the field's first line puts your previous message in it, and each press goes further back. Down Arrow on the last line comes forward, then brings back what you were typing.")
                }
                Toggle(isOn: $controlCStopsOrClears) {
                    Text("Control-C stops or clears")
                    Text("Control-C stops the running task, as Command-Period does. With no task running, it clears the field. Command-C still copies.")
                }
                Toggle(isOn: $doubleDeleteStartsNewEpisode) {
                    Text("Delete twice starts a new episode")
                    Text("Pressing Delete twice quickly in an empty field does what /new does: a new episode, or in the incognito window a cleared conversation. Holding Delete down does not.")
                }
            } header: {
                Text("Habits from terminal coding agents such as Claude Code, pi, and Codex.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Experiments

/// Features being tried, each a switch, off until the owner turns it on. See `Experiment`.
struct ExperimentsSettingsView: View {
    @AppStorage(Experiment.queueMessagesWhileRunning.key) private var queuesMessages = false
    @AppStorage(Experiment.suggestionsInFieldAndFooter.key) private var suggestionsInField = false
    @AppStorage(Experiment.mcpServers.key) private var mcpServers = false
    @AppStorage(Experiment.panelWithBarsAndInputPill.key) private var panelWithBars = false
    @AppStorage(Experiment.scripts.key) private var scripts = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $queuesMessages) {
                    Text("Queue messages while a task runs")
                    Text("Return while a task runs adds the message to a queue above the field, and each one is sent as its own turn when the one before finishes. Stopping the task pauses the queue.")
                }
                Toggle(isOn: $suggestionsInField) {
                    Text("Suggestions in the field and a footer")
                    Text("An app or quick action that Return would open is shown in the field itself, with its icon beside it and its name in gray after what you typed, and a line under the field says what the keys do. Down Arrow lists the other matches under the field. Nothing is added above the field, so the conversation stays where it is.")
                }
                Toggle(isOn: $panelWithBars) {
                    Text(Experiment.panelWithBarsAndInputPill.title)
                    Text("The panel reads as bar, conversation, band. The title bar shows the model's name at the left and MacOS Agent in the middle. The text field is a pill at the bottom with the logo beside it, and a line under it says what the keys do. Matches show in the field as the suggestions experiment shows them, whether or not that switch is on.")
                }
                Toggle(isOn: $mcpServers) {
                    Text("MCP servers")
                    Text("The agent gets the tools of the MCP servers listed in mcp-servers.json, and Settings gets an MCP Servers section. Turning it on starts the servers now, and their tools join at the next launch. Turning it off stops them, and their tools leave at the next launch.")
                }
                Toggle(isOn: $scripts) {
                    Text(Experiment.scripts.title)
                    Text("The agent gets run_script, which runs a short JavaScript script that calls its other tools, so it can chain them without writing a program in the shell. Each call asks for a go-ahead exactly when calling the tool directly would. Takes effect at the next launch.")
                }
            } header: {
                Text("Features being tried. They may change or go.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }
        }
        .formStyle(.grouped)
    }
}
