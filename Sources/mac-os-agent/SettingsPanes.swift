import AppKit
import MacOSAgentCore
import Observation
import SwiftUI

// MARK: - General

struct GeneralSettingsView: View {
    let session: AgentSession
    @Bindable var shortcut: ShortcutRecorderModel
    let webSearch: WebSearchSettingsModel
    let updater: AppUpdater
    /// Read from Sparkle when the section appears. Sparkle keeps it in its own preferences.
    @State private var updatesAutomatically = false
    @AppStorage(ModelSetting.key) private var model = OpenAIModel.defaultID
    @AppStorage(Experiment.localModelsThroughOllama.key) private var localModelsOn = false
    /// Read from Ollama when the section appears, with the local models experiment on.
    @State private var localModels: [String] = []
    @AppStorage(EpisodeTimeoutSetting.key) private var episodeTimeout = EpisodeTimeoutSetting.defaultMinutes

    private var modelChoices: (models: [OpenAIModel], currentIsUnlisted: Bool) {
        session.modelChoices(current: model)
    }

    private var listedModels: [String] {
        modelChoices.models.map(\.id) + (localModelsOn ? localModels.map(Ollama.modelID) : [])
    }

    var body: some View {
        Form {
            Section {
                if session.modelAccess == .gateway {
                    LabeledContent("Account", value: "Through inference-gateway")
                } else {
                    LabeledContent("Account") {
                        switch session.signInState {
                        case .signedIn:
                            HStack {
                                Text("Signed in")
                                Button("Sign Out") { session.signOut() }
                            }
                        case .signingIn:
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Waiting for the browser…")
                                Button("Cancel") { session.cancelSignIn() }
                            }
                        case .signedOut:
                            HStack {
                                Button("Sign in with ChatGPT…") { session.signIn() }
                                // A sign-in reuses this Mac's registration, which belongs to one
                                // account. Another account needs a registration of its own.
                                if session.hasRegistration {
                                    Button("Use a Different Account…") { session.signIn(differentAccount: true) }
                                }
                            }
                        }
                    }
                }
                Picker("Model", selection: $model) {
                    ForEach(modelChoices.models) { model in
                        Text(model.name).tag(model.id)
                    }
                    if localModelsOn {
                        Section("Ollama") {
                            ForEach(localModels, id: \.self) { name in
                                Text(Ollama.displayName(name)).tag(Ollama.modelID(name))
                            }
                        }
                    }
                    if !listedModels.contains(model) {
                        Text(ModelSetting.displayName(id: model)).tag(model)
                    }
                }
            } header: {
                Text("ChatGPT")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if modelChoices.currentIsUnlisted {
                        Text("\(model) is not in your ChatGPT account's model list. It stays selected until you choose another, and requests may fail with it.")
                    }
                    Text((session.accountModels == nil ? "" : "These are the models your ChatGPT account lists. ")
                        + (localModelsOn
                            ? "A new model applies from the next reply. The model is also in the menu bar menu. Models marked Ollama run on this Mac, through Ollama at localhost:11434, and need no sign-in.\(localModels.isEmpty ? " Ollama has no models, or is not running." : "")"
                            : "A new model applies from the next reply. The model is also in the menu bar menu.")
                        + (session.modelAccess == .gateway
                            ? " This development build has no sign-in of its own. It sends every model request through inference-gateway at \(InferenceGateway.address())."
                            : ""))
                }
                .foregroundStyle(.secondary)
            }
            .task(id: localModelsOn) {
                localModels = localModelsOn ? await Ollama.installedModels() : []
            }
            WebSearchSettingsSection(model: webSearch)
            Section {
                Picker("Start a new episode after", selection: $episodeTimeout) {
                    ForEach(EpisodeTimeoutSetting.choices, id: \.self) { minutes in
                        Text(EpisodeTimeoutSetting.describe(TimeInterval(minutes * 60))).tag(minutes)
                    }
                    if !EpisodeTimeoutSetting.choices.contains(episodeTimeout) {
                        Text(EpisodeTimeoutSetting.describe(TimeInterval(episodeTimeout * 60))).tag(episodeTimeout)
                    }
                }
            } header: {
                Text("Episodes")
            } footer: {
                Text("A message sent after this long without activity starts a new episode, and the panel opens on a fresh page. The agent sees only the current episode and searches earlier ones when it needs them. Type /new to start one sooner. Type /incognito to open an incognito window beside the panel. It keeps nothing, only opens apps and answers questions, and has no timeout. It lasts until you clear it or close it.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Show or hide the panel") {
                    HStack {
                        ShortcutRecorderView(model: shortcut)
                        Button("Restore Default") { shortcut.restoreDefault() }
                            .disabled(shortcut.controller.isDefault && shortcut.controller.problem == nil)
                    }
                }
            } header: {
                Text("Keyboard")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let status = shortcut.status {
                        Text(status.text)
                            .foregroundStyle(status.kind == .problem ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Click the shortcut and press a new one. Escape cancels and Delete removes it. Clicking the menu bar icon also shows or hides the panel.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section {
                if updater.isAvailable {
                    Toggle("Update automatically", isOn: Binding(
                        get: { updatesAutomatically },
                        set: {
                            updater.updatesAutomatically = $0
                            updatesAutomatically = $0
                        }
                    ))
                }
                LabeledContent("Version") {
                    HStack {
                        Text(AppUpdates.version(Bundle.main.infoDictionary))
                            .textSelection(.enabled)
                        if updater.isAvailable {
                            Button("Check for Updates…") { updater.checkForUpdates() }
                        }
                    }
                }
            } header: {
                Text("Updates")
            } footer: {
                Text(updater.isAvailable
                     ? "Checks about once a day, downloads a newer release, and relaunches into it. While a task runs, waits for a go-ahead, has queued messages, or an incognito conversation is open, the relaunch waits until it ends. Check for Updates is also in the menu bar menu."
                     : "This build does not update itself. Only a release build does.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { updatesAutomatically = updater.updatesAutomatically }
    }
}

// MARK: - Instructions

@MainActor
@Observable
final class InstructionsSettingsModel {
    var draft: String
    private(set) var saved: String
    private(set) var isCustomized: Bool
    var errorMessage: String?
    @ObservationIgnored let prompt: AgentPrompt

    init(prompt: AgentPrompt) {
        self.prompt = prompt
        let text = prompt.instructions.load()
        saved = text
        draft = text
        isCustomized = prompt.instructions.isCustomized
    }

    var hasChanges: Bool { draft != saved }
    var isDefault: Bool { draft == AgentInstructions.defaultEditable }

    /// Picks up changes made outside the window, unless there are edits that are not saved yet.
    func reloadIfUnchanged() {
        guard !hasChanges else { return }
        saved = prompt.instructions.load()
        draft = saved
        isCustomized = prompt.instructions.isCustomized
    }

    func save() {
        do {
            try prompt.instructions.save(draft)
            saved = draft
            isCustomized = prompt.instructions.isCustomized
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func revert() {
        draft = saved
    }

    func restoreDefault() {
        draft = AgentInstructions.defaultEditable
        save()
    }

    /// What the agent receives, for showing in the window.
    var fullPrompt: String {
        AgentInstructions.assemble(
            editable: draft,
            skills: prompt.skills.skills().filter(\.isAvailable).map { .init(name: $0.name, description: $0.description) },
            skillsFolder: prompt.skills.folder,
            memoryBlock: prompt.latestMemoryContents().map(MemoryBlock.placeholder))
    }
}

struct InstructionsSettingsView: View {
    @Bindable var model: InstructionsSettingsModel
    @State private var confirmingRestore = false
    @State private var showingFullPrompt = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What the agent is told before every instruction. Changes apply from your next instruction.")
                .foregroundStyle(.secondary)
            PromptEditor(text: $model.draft)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
                .padding(8)
                .background(.background.secondary, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            Text("""
                The app always adds its own rules after this text: how the go-ahead for destructive \
                commands works, the time, the list of skills, and memory.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Button("Restore Default…") { confirmingRestore = true }
                    .disabled(model.isDefault && !model.isCustomized)
                Button("Show Full Prompt…") { showingFullPrompt = true }
                Spacer()
                Button("Revert") { model.revert() }
                    .disabled(!model.hasChanges)
                Button("Save") { model.save() }
                    .keyboardShortcut("s")
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.hasChanges)
            }
        }
        .padding(20)
        .confirmationDialog("Restore the default instructions?", isPresented: $confirmingRestore) {
            Button("Restore Default", role: .destructive) { model.restoreDefault() }
        } message: {
            Text("Your edits to the instructions will be replaced.")
        }
        .sheet(isPresented: $showingFullPrompt) {
            FullPromptView(text: model.fullPrompt)
        }
    }
}

struct FullPromptView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The full prompt").font(.headline)
            ScrollView {
                Text(text)
                    .font(PromptText.font)
                    .lineSpacing(PromptText.lineSpacing)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 480)
    }
}

// MARK: - Skills: see SkillsSettings.swift

struct NewSkillView: View {
    let create: (String, String) -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var error: String?

    private var skillName: String { SkillLibrary.suggestedName(from: name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Skill").font(.headline)
            Form {
                TextField("Name", text: $name, prompt: Text("rename-photos"))
                TextField("Description", text: $description, prompt: Text("What it does and when to use it"), axis: .vertical)
                    .lineLimit(2...4)
            }
            .formStyle(.columns)
            Text(skillName.isEmpty
                 ? "The folder and the name use lowercase letters, digits, and hyphens."
                 : "Makes the folder \(skillName) with a SKILL.md to fill in, and opens it.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    error = create(skillName, description)
                    if error == nil { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(skillName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
