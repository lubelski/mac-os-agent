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

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $queuesMessages) {
                    Text("Queue messages while a task runs")
                    Text("Return while a task runs adds the message to a queue above the field, and each one is sent as its own turn when the one before finishes. Stopping the task pauses the queue.")
                }
                Toggle(isOn: $suggestionsInField) {
                    Text("Suggestions in the field and a footer")
                    Text("An app or saved action that Return would open is shown in the field itself, with its icon beside it and its name in gray after what you typed, and a line under the field says what the keys do. Down Arrow lists the other matches under the field. Nothing is added above the field, so the conversation stays where it is.")
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
