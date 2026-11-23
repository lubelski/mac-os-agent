import AppKit
import MacOSAgentCore
import SwiftUI

/// The Appearance section: the panel's themes as small live previews, the actions on them,
/// and the Use Glass switch. Choosing a theme applies it to the panel at once. Settings itself
/// keeps the standard system look.
struct AppearanceSettingsView: View {
    @Bindable var model: ThemeModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var deleting: ThemeEntry?
    @AgentName private var agentName

    private let columns = [GridItem(.adaptive(minimum: 168, maximum: 240), spacing: 14, alignment: .top)]

    var body: some View {
        Form {
            Section {
                grid(model.builtInEntries)
            } header: {
                Text("Built-in Themes")
            } footer: {
                Text("Click a theme to use it in the panel. Built-in themes cannot be changed. Duplicate one to make your own.")
                    .foregroundStyle(.secondary)
            }

            Section {
                let own = model.ownEntries
                let readable = own.filter { $0.theme != nil }
                if readable.isEmpty {
                    Text("None yet. Duplicate a theme, put a theme file in the themes folder, or ask \(agentName) to make one.")
                        .foregroundStyle(.secondary)
                } else {
                    grid(readable)
                }
                ForEach(own.filter { $0.theme == nil }) { entry in
                    BrokenThemeRow(entry: entry, model: model, deleting: $deleting)
                }
            } header: {
                Text("Your Themes")
            } footer: {
                Text("Each theme is a JSON file in the themes folder in Application Support. A new or changed file shows here and in the panel straight away.")
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Duplicate \(model.activeEntry?.name ?? "Theme")") { model.duplicate(model.activeID) }
                        .disabled(model.activeEntry?.theme == nil)
                    Button("Delete \(model.activeEntry?.isBuiltIn == false ? model.activeEntry!.name : "Theme")…") {
                        deleting = model.activeEntry
                    }
                    .disabled(model.activeEntry?.isBuiltIn != false)
                    Spacer()
                    Button("Show Themes Folder") { model.revealFolder() }
                }
                if let error = model.errorMessage {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }

            Section {
                Toggle("Use glass", isOn: Binding(get: { model.usesGlass }, set: { model.setUsesGlass($0) }))
            } header: {
                Text("Glass")
            } footer: {
                Text(reduceTransparency
                     ? "Reduce Transparency is on in Accessibility settings, so the panel draws every theme on its solid fill whatever this says."
                     : "When this is off, every theme draws on its solid fill, without Liquid Glass or blur. The panel does the same while Reduce Transparency is on in Accessibility settings.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Delete the theme \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { entry in
            Button("Delete", role: .destructive) { model.delete(entry.id) }
        } message: { entry in
            Text(entry.id == model.activeID
                 ? "Its file, \(entry.id).json, is removed, and the panel goes back to Glass."
                 : "Its file, \(entry.id).json, is removed.")
        }
        .onAppear { model.reload() }
    }

    private func grid(_ entries: [ThemeEntry]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(entries) { entry in
                if let theme = entry.theme {
                    ThemeCard(
                        entry: entry, theme: theme, isActive: entry.id == model.activeID,
                        allowsGlass: model.usesGlass && !reduceTransparency,
                        select: { model.select(entry.id) })
                    .contextMenu {
                        Button("Use in the Panel") { model.select(entry.id) }
                        Button("Duplicate") { model.duplicate(entry.id) }
                        if !entry.isBuiltIn {
                            Button("Show in Finder") { model.revealFile(entry) }
                            Divider()
                            Button("Delete…") { deleting = entry }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// A theme file that could not be read, with its problem, as a broken skill is shown.
private struct BrokenThemeRow: View {
    let entry: ThemeEntry
    let model: ThemeModel
    @Binding var deleting: ThemeEntry?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(entry.id).json")
                Text(entry.problem ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Show in Finder") { model.revealFile(entry) }
            Button("Delete…") { deleting = entry }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One theme in the chooser: a live preview and its name. The active one has a ring in the
/// accent color. The name keeps one weight whether or not it is chosen.
private struct ThemeCard: View {
    let entry: ThemeEntry
    let theme: Theme
    let isActive: Bool
    let allowsGlass: Bool
    let select: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 6) {
                ThemeSample(theme: theme, dark: colorScheme == .dark, allowsGlass: allowsGlass)
                    .overlay {
                        RoundedRectangle(cornerRadius: ThemeSample.cornerRadius + 3, style: .continuous)
                            .strokeBorder(isActive ? AnyShapeStyle(Color(nsColor: .controlAccentColor)) : AnyShapeStyle(.separator),
                                          lineWidth: isActive ? 2.5 : 1)
                            .padding(-3)
                    }
                HStack(spacing: 4) {
                    Text(theme.name)
                    if isActive {
                        Image(systemName: "checkmark")
                            .font(.caption)
                            .foregroundStyle(Color(nsColor: .controlAccentColor))
                            .accessibilityHidden(true)
                    }
                }
                Text(theme.fixedAppearance == nil ? "Light and dark" : theme.fixedAppearance == .dark ? "Dark only" : "Light only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 3)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.name)
        .accessibilityValue(isActive ? "In use" : "")
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .help(isActive ? "\(theme.name) is in use" : "Use \(theme.name) in the panel")
    }
}

/// A few rows of conversation drawn with a theme, over a small busy backdrop so glass and blur
/// show their translucency. It is its own small view, independent of the panel's views.
struct ThemeSample: View {
    let theme: Theme
    let dark: Bool
    var allowsGlass = true
    static let cornerRadius: CGFloat = 12
    /// The small panel and its message boxes, in the proportion of the real ones.
    static let panelCornerRadius: CGFloat = 5
    static let messageCornerRadius: CGFloat = 3

    var body: some View {
        let palette = PanelPalette(theme: theme, dark: dark, allowsGlass: allowsGlass)
        ZStack {
            SampleBackdrop(dark: palette.isDark)
            VStack(spacing: 0) {
                // The top bar, on the bars' fill, with its hairline.
                Color.clear
                    .frame(height: 9)
                    .background(PanelBarFill())
                Rectangle().fill(palette.divider).frame(height: 1)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Spacer(minLength: 24)
                        Text(verbatim: "turn on dark mode")
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(palette.ownerFill, in: .rect(cornerRadius: Self.messageCornerRadius))
                            .overlay(RoundedRectangle(cornerRadius: Self.messageCornerRadius, style: .continuous).strokeBorder(palette.ownerEdge, lineWidth: 1))
                    }
                    HStack(spacing: 0) {
                        Text(verbatim: "› ").foregroundStyle(.tertiary)
                        Text(verbatim: "osascript").foregroundStyle(.secondary)
                        Text(verbatim: " -e 'tell app…'").foregroundStyle(.tertiary)
                    }
                    .font(.system(size: 8.5, design: .monospaced))
                    .lineLimit(1)
                    .padding(.leading, 6)
                    HStack {
                        Text(verbatim: "Dark mode is on.")
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(palette.agentFill, in: .rect(cornerRadius: Self.messageCornerRadius))
                            .overlay(RoundedRectangle(cornerRadius: Self.messageCornerRadius, style: .continuous).strokeBorder(palette.agentEdge, lineWidth: 1))
                        Spacer(minLength: 24)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                // The band with the text field, on the same fill as the top bar.
                Rectangle().fill(palette.divider).frame(height: 1)
                HStack(spacing: 5) {
                    PromptMark(size: 7)
                    Text(verbatim: "Tell your Mac what to do").foregroundStyle(.tertiary)
                }
                .font(.system(size: 9))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PanelBarFill())
            }
            .font(.system(size: 10))
            .environment(\.panelPalette, palette)
            .panelText(palette)
            // The bars' fill stays inside the small panel's rounded corners, as the window's
            // clip keeps it inside the real one's.
            .clipShape(.rect(cornerRadius: Self.panelCornerRadius, style: .continuous))
            .previewSurface(palette, cornerRadius: Self.panelCornerRadius)
            .padding(7)
        }
        .frame(height: 124)
        .clipShape(.rect(cornerRadius: Self.cornerRadius, style: .continuous))
        .environment(\.colorScheme, palette.isDark ? .dark : .light)
        .accessibilityHidden(true)
    }
}

/// A small document page with lines of text and two colored blocks, behind a sample.
private struct SampleBackdrop: View {
    let dark: Bool

    var body: some View {
        let ink: Color = dark ? .white.opacity(0.55) : .black.opacity(0.55)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<12, id: \.self) { line in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1).fill(ink).frame(width: CGFloat(60 + (line * 37) % 90), height: 3)
                    if line % 4 == 1 { RoundedRectangle(cornerRadius: 2).fill(.blue.opacity(0.75)).frame(width: 34, height: 7) }
                    if line % 5 == 3 { RoundedRectangle(cornerRadius: 2).fill(.orange.opacity(0.85)).frame(width: 26, height: 7) }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(dark ? Color(white: 0.14) : .white)
    }
}
