import AppKit
import MacOSAgentCore
import Observation
import SwiftUI

@MainActor
@Observable
final class SkillsSettingsModel {
    private(set) var skills: [Skill] = []
    var selection: Skill.ID? {
        didSet { if selection != oldValue { readContents() } }
    }
    var filter = ""
    private(set) var contents: SkillContents?
    var errorMessage: String?
    @ObservationIgnored let library: SkillLibrary

    init(library: SkillLibrary) {
        self.library = library
        reload()
    }

    func reload() {
        skills = library.skills()
        if let selection, !skills.contains(where: { $0.id == selection }) { self.selection = nil }
        if selection == nil { selection = skills.first?.id }
        readContents()
    }

    var filteredSkills: [Skill] { skills.filter { $0.matches(filter) } }
    var selectedSkill: Skill? { skills.first { $0.id == selection } }

    var countText: String {
        let on = skills.filter(\.isAvailable).count
        return skills.count == 1 ? "1 skill, \(on) on" : "\(skills.count) skills, \(on) on"
    }

    private func readContents() {
        contents = selectedSkill.map(library.contents(of:))
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
            filter = ""
            reload()
            selection = skill.id
            NSWorkspace.shared.open(skill.fileURL)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

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

/// Skills as a list beside the selected skill's detail, so it works for dozens of skills.
struct SkillsSettingsView: View {
    @Bindable var model: SkillsSettingsModel
    @State private var creating = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                FilterField(prompt: "Filter Skills", text: $model.filter)
                    .padding(10)
                Group {
                    if model.skills.isEmpty {
                        ContentUnavailableView {
                            Label("No Skills Yet", systemImage: "puzzlepiece.extension")
                        } description: {
                            Text("Make one with New Skill, or ask the agent to write one.")
                        }
                    } else if model.filteredSkills.isEmpty {
                        ContentUnavailableView.search(text: model.filter)
                    } else {
                        ScrollViewReader { proxy in
                            List(model.filteredSkills, selection: $model.selection) { skill in
                                SkillRow(skill: skill).tag(skill.id).id(skill.id)
                            }
                            .listStyle(.inset)
                            .scrollContentBackground(.hidden)
                            .task {
                                // Waits a moment for the rows, then brings the selected skill into view.
                                try? await Task.sleep(for: .milliseconds(100))
                                if let selection = model.selection { proxy.scrollTo(selection, anchor: .center) }
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                Divider()
                HStack(spacing: 8) {
                    Button("New Skill…", systemImage: "plus") { creating = true }
                        .help("New Skill")
                    Button("Reload", systemImage: "arrow.clockwise") { model.reload() }
                        .help("Read the skills folder again")
                    Spacer()
                    Text(model.countText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .frame(width: 260)
            Divider()
            Group {
                if let skill = model.selectedSkill {
                    SkillDetailView(skill: skill, contents: model.contents, model: model)
                } else {
                    VStack(spacing: 12) {
                        ContentUnavailableView(
                            "No Skill Selected", systemImage: "puzzlepiece.extension",
                            description: Text("Skills teach the agent particular tasks. It can write new ones itself."))
                        Button("Show Skills Folder in Finder") { model.revealInFinder() }
                    }
                    .padding(.bottom, 40)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { model.reload() }
        .sheet(isPresented: $creating) {
            NewSkillView { name, description in model.create(name: name, description: description) }
        }
    }
}

/// A search-looking text field for filtering a list inside a section.
struct FilterField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.6), in: .capsule)
    }
}

struct SkillRow: View {
    let skill: Skill

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name)
                    .foregroundStyle(skill.isEnabled ? .primary : .secondary)
                Text(skill.problem ?? skill.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if skill.problem != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Has a problem")
            } else if !skill.isEnabled {
                Text("Off")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct SkillDetailView: View {
    let skill: Skill
    let contents: SkillContents?
    let model: SkillsSettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(skill.name).font(.title2)
                        Text(skill.folderURL.path(percentEncoded: false))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Toggle("Use \(skill.name)", isOn: Binding(
                        get: { skill.isEnabled }, set: { model.setEnabled($0, skill) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .help(skill.isEnabled ? "On: listed in the agent's instructions" : "Off: the agent does not see it")
                }
                if let problem = skill.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 8))
                } else {
                    Text(skill.description)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = model.errorMessage {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                HStack {
                    Button("Open SKILL.md") { model.openSelected() }
                    Button("Show in Finder") { model.revealInFinder() }
                }
                if let contents {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Files").font(.headline)
                        if contents.files.isEmpty {
                            Text(contents.hasFile ? "Only SKILL.md." : "There is no SKILL.md in this folder.")
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(["SKILL.md"] + contents.files, id: \.self) { file in
                                    Label(file, systemImage: file.hasSuffix(".sh") ? "terminal" : "doc")
                                        .font(.callout.monospaced())
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SKILL.md").font(.headline)
                        MarkdownText(text: contents.instructions.isEmpty ? "(empty)" : contents.instructions)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.background.secondary, in: .rect(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Shows Markdown for reading: headings larger, and inline styles such as code and emphasis.
/// Line breaks are kept as written.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                if let heading = Self.heading(paragraph) {
                    Text(Self.inline(heading)).font(.headline).padding(.top, 4)
                } else {
                    Text(Self.inline(paragraph))
                }
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var paragraphs: [String] {
        text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .newlines) }.filter { !$0.isEmpty }
    }

    private static func heading(_ paragraph: String) -> String? {
        guard !paragraph.contains("\n"), paragraph.hasPrefix("#") else { return nil }
        return paragraph.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
    }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
