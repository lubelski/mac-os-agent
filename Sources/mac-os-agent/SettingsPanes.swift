import AppKit
import MacOSAgentCore
import Observation
import SwiftUI

// MARK: - General

struct GeneralSettingsView: View {
    let session: AgentSession
    let shortcutAvailable: Bool
    @AppStorage(ModelSetting.key) private var model = OpenAIModel.defaultID

    var body: some View {
        Form {
            Section {
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
                        Button("Sign in with ChatGPT…") { session.signIn() }
                    }
                }
                Picker("Model", selection: $model) {
                    ForEach(OpenAIModel.all) { model in
                        Text(model.name).tag(model.id)
                    }
                    if !OpenAIModel.all.contains(where: { $0.id == model }) {
                        Text(model).tag(model)
                    }
                }
            } header: {
                Text("ChatGPT")
            } footer: {
                Text("A new model applies from the next reply. The model is also in the menu bar menu.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Show or hide the panel") {
                    Text(SummonShortcut.displayName)
                }
            } header: {
                Text("Keyboard")
            } footer: {
                if !shortcutAvailable {
                    Text("Another app is using \(SummonShortcut.displayName), so it does nothing here.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 280)
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
            skillsFolder: prompt.skills.folder)
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
            TextEditor(text: $model.draft)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.background.secondary, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            Text("""
                The app always adds its own rules after this text: how the go-ahead for destructive \
                commands works, the time at the start of each message, and the list of skills.
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
        .frame(width: 680, height: 540)
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
                    .font(.body.monospaced())
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

// MARK: - Skills

@MainActor
@Observable
final class SkillsSettingsModel {
    private(set) var skills: [Skill] = []
    var selection: Skill.ID?
    var errorMessage: String?
    @ObservationIgnored let library: SkillLibrary

    init(library: SkillLibrary) {
        self.library = library
        reload()
    }

    func reload() {
        skills = library.skills()
        if let selection, !skills.contains(where: { $0.id == selection }) { self.selection = nil }
    }

    func setEnabled(_ enabled: Bool, _ skill: Skill) {
        do {
            try library.setEnabled(enabled, folderName: skill.folderName)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }

    /// Makes the skill and opens its SKILL.md for writing. Returns why it could not, or nil.
    func create(name: String, description: String) -> String? {
        do {
            let skill = try library.create(name: name, description: description)
            reload()
            selection = skill.id
            NSWorkspace.shared.open(skill.fileURL)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var selectedSkill: Skill? { skills.first { $0.id == selection } }

    func openSelected() {
        guard let skill = selectedSkill else { return }
        NSWorkspace.shared.open(FileManager.default.fileExists(atPath: skill.fileURL.path) ? skill.fileURL : skill.folderURL)
    }

    func revealInFinder() {
        if let skill = selectedSkill {
            NSWorkspace.shared.activateFileViewerSelecting([skill.folderURL])
            return
        }
        try? FileManager.default.createDirectory(at: library.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(library.folder)
    }
}

struct SkillsSettingsView: View {
    @Bindable var model: SkillsSettingsModel
    @State private var creating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("""
                Skills teach the agent particular tasks. It sees the name and description of each skill \
                that is on, and reads the rest when a task needs it. It can write new skills itself.
                """)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                if model.skills.isEmpty {
                    ContentUnavailableView {
                        Label("No Skills Yet", systemImage: "puzzlepiece.extension")
                    } description: {
                        Text("Make one with New Skill, or ask the agent to write one.")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $model.selection) {
                        ForEach(model.skills) { skill in
                            SkillRow(skill: skill) { model.setEnabled($0, skill) }
                                .tag(skill.id)
                        }
                    }
                    .listStyle(.inset)
                    .alternatingRowBackgrounds()
                }
            }
            .background(.background, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            .clipShape(.rect(cornerRadius: 10))
            if let error = model.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Button("New Skill…") { creating = true }
                Button("Open SKILL.md") { model.openSelected() }
                    .disabled(model.selectedSkill == nil)
                Spacer()
                Button("Show in Finder") { model.revealInFinder() }
                Button("Reload") { model.reload() }
            }
            Text(model.library.folder.path(percentEncoded: false))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(20)
        .frame(width: 680, height: 500)
        .onAppear { model.reload() }
        .sheet(isPresented: $creating) {
            NewSkillView { name, description in model.create(name: name, description: description) }
        }
    }
}

struct SkillRow: View {
    let skill: Skill
    let setEnabled: @MainActor @Sendable (Bool) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle("Use \(skill.name)", isOn: Binding(get: { skill.isEnabled }, set: setEnabled))
                .labelsHidden()
                .toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name)
                if let problem = skill.problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                } else {
                    Text(skill.description)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

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
