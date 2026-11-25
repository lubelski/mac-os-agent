import MacOSAgentCore
import Observation
import SwiftUI

/// The web search this run launched with, and where the Brave Search key is kept. The setting
/// is read once at launch, since it changes the tool list or the request, which stay fixed for
/// the run.
struct WebSearchContext {
    var launched: WebSearchSetting
    /// Nil where there is no store to keep a key in.
    var key: BraveSearchKey?

    /// For Debugging: the setting at launch and now, and whether a key is set. Never the key.
    func status(_ defaults: UserDefaults) -> WebSearchStatus {
        WebSearchStatus(launched: launched, stored: WebSearchSetting.current(defaults), braveKeySet: key?.isSet ?? false)
    }
}

/// The key field's state in Settings, General. It knows whether a key is saved and never reads
/// the key back for showing.
@MainActor
@Observable
final class WebSearchSettingsModel {
    @ObservationIgnored let context: WebSearchContext
    var draft = ""
    private(set) var keySaved: Bool
    private(set) var problem: String?

    init(context: WebSearchContext) {
        self.context = context
        keySaved = context.key?.isSet ?? false
    }

    var launched: WebSearchSetting { context.launched }
    var canKeepKey: Bool { context.key != nil }

    func saveKey() {
        guard let key = context.key else { return }
        do {
            try key.save(draft)
            draft = ""
            problem = nil
        } catch {
            problem = "The key could not be saved: \(error.localizedDescription)"
        }
        keySaved = key.isSet
    }

    func removeKey() {
        context.key?.remove()
        keySaved = context.key?.isSet ?? false
        problem = nil
    }
}

/// The Web search group in Settings, General: the choice, what it does, the Brave key when
/// Brave is chosen, and a line when the choice takes effect at the next launch.
struct WebSearchSettingsSection: View {
    @Bindable var model: WebSearchSettingsModel
    @AppStorage(WebSearchSetting.key) private var stored = WebSearchSetting.off.rawValue

    private var choice: WebSearchSetting { WebSearchSetting(rawValue: stored) ?? .off }

    var body: some View {
        Section {
            Picker("Web search", selection: $stored) {
                ForEach(WebSearchSetting.allCases) { setting in
                    Text(setting.title).tag(setting.rawValue)
                }
            }
            if choice == .brave {
                LabeledContent("API key") {
                    if model.keySaved {
                        HStack {
                            Text("Key saved").foregroundStyle(.secondary)
                            Button("Remove") { model.removeKey() }
                        }
                    } else {
                        HStack {
                            SecureField("API key", text: $model.draft, prompt: Text("Brave Search API key"))
                                .labelsHidden()
                                .frame(maxWidth: 260)
                                .onSubmit { model.saveKey() }
                            Button("Save") { model.saveKey() }
                                .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                .disabled(!model.canKeepKey)
            }
        } header: {
            Text("Web search")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(choice.explanation)
                    .foregroundStyle(.secondary)
                if choice == .brave {
                    Text("The key is kept where the sign-in is, never in the preferences. A new key applies from the next search.")
                        .foregroundStyle(.secondary)
                }
                if let problem = model.problem {
                    Text(problem).foregroundStyle(.red)
                }
                if choice != model.launched {
                    Text(WebSearchSetting.nextLaunchNote)
                        .foregroundStyle(.primary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
