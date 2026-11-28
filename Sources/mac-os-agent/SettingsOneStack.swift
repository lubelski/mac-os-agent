import AppKit
import MacOSAgentCore
import SwiftUI

// Settings as one pane stack, with the experiment "Settings as One Stack of Panes" on.
//
// The window is one `PaneStackView` over `SettingsNavigation.stack`. Its path is the section's
// id at depth 1 followed by the section's own levels (`SettingsPaneStack`):
//
// - depth 0: the section list, `SettingsSectionListPane`, 200 points wide as the sidebar was.
// - depth 1: the section. Tools and History give their first level, and every other section
//   its whole view, as it is beside the fixed sidebar.
// - depth 2 and deeper: Tools' and History's own levels, from `ToolsStackPanes` and
//   `HistoryStackPanes`, asked with their depth less one, so they see the path as they always
//   did. MCP Servers keeps its tool's pane as a stack of its own inside the section.
//
// The section models still hold each section's own path, so leaving a section and coming back
// finds it as it was, and the window's path is kept in step with them both ways. Each pane's
// scroll place is kept in the window's stack, by its path, which starts with the section.

/// The whole Settings window as one stack of panes. See the top of this file.
struct SettingsOneStackView: View {
    let models: SettingsModels
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        let tools = ToolsStackPanes(model: models.tools)
        let history = HistoryStackPanes(model: models.history, panes: models.history.panes)
        PaneStackView(state: navigation.stack) { strip in
            stripWidth(strip, tools: tools, history: history)
        } title: { level in
            title(level, tools: tools, history: history)
        } rows: { path in
            rows(path, tools: tools, history: history)
        } escape: { path in
            SettingsPaneStack.escape(from: path)
        } resolve: { requested, current in
            SettingsPaneStack.resolve(requested, from: current, kept: kept)
        } pane: { level in
            pane(level, tools: tools, history: history)
        }
        .environment(\.imageData) { [images = models.history.images] in images.data(for: $0) }
        // The section models are where each section's place is kept. A change there, such as a
        // preview opening a tool, a section shown from the menu, or a path that fell back,
        // moves the window's stack. A change the stack makes is written back to them.
        .onChange(of: keptPath, initial: true) { _, path in
            if navigation.stack.path != path { navigation.stack.path = path }
        }
        .onChange(of: navigation.stack.path) { _, path in keep(path) }
        .onChange(of: models.tools.stack.path, initial: true) { _, _ in models.tools.fallBack() }
        .onChange(of: models.history.stack.path, initial: true) { _, _ in models.history.fallBack() }
        .onChange(of: models.history.panes) { _, _ in models.history.fallBack() }
    }

    // MARK: - The section's own place

    /// The window's path as the section models keep it: the chosen section and its own levels.
    private var keptPath: PaneStackPath {
        SettingsPaneStack.path(section: navigation.section.rawValue, within: kept(navigation.section.rawValue))
    }

    /// A section's own levels, as it was last left, by its id. A section that is not a stack has
    /// none.
    private func kept(_ id: String) -> PaneStackPath {
        switch SettingsSection(rawValue: id) {
        case .tools: models.tools.stack.path
        case .history: models.history.stack.path
        default: PaneStackPath()
        }
    }

    /// Writes a path the stack moved to back to the section models: the section's own levels
    /// first, then the section, so the kept path matches the window's when both are done.
    private func keep(_ path: PaneStackPath) {
        guard let id = SettingsPaneStack.section(of: path), let section = SettingsSection(rawValue: id) else { return }
        let within = SettingsPaneStack.sectionPath(of: path)
        switch section {
        case .tools: if models.tools.stack.path != within { models.tools.stack.path = within }
        case .history: if models.history.stack.path != within { models.history.stack.path = within }
        default: break
        }
        if navigation.section != section { navigation.section = section }
    }

    // MARK: - What the stack asks for

    /// The section a level or strip belongs to: the one the window's path shows.
    private var shownSection: SettingsSection? {
        SettingsPaneStack.section(of: navigation.stack.path).flatMap(SettingsSection.init(rawValue:))
    }

    /// A level as its section counts it: its first level at depth 0.
    private func inSection(_ level: PaneLevel) -> PaneLevel {
        PaneLevel(
            depth: SettingsPaneStack.depthInSection(level.depth), path: SettingsPaneStack.sectionPath(of: level.path),
            topDepth: SettingsPaneStack.depthInSection(level.topDepth))
    }

    private func stripWidth(_ strip: PaneStrip, tools: ToolsStackPanes, history: HistoryStackPanes) -> CGFloat {
        // The section list keeps the sidebar's width. The stack's layout narrows it, and then
        // covers it, as the window narrows.
        guard strip.depth > 0 else { return SettingsRootView.sidebarWidth }
        let strip = PaneStrip(
            depth: SettingsPaneStack.depthInSection(strip.depth), topDepth: SettingsPaneStack.depthInSection(strip.topDepth))
        switch shownSection {
        case .tools: return tools.stripWidth(strip)
        case .history: return history.stripWidth(strip)
        default: return 0
        }
    }

    private func title(_ level: PaneLevel, tools: ToolsStackPanes, history: HistoryStackPanes) -> String {
        guard let id = SettingsPaneStack.section(of: level.path), let section = SettingsSection(rawValue: id) else {
            return SettingsSectionListPane.title
        }
        guard level.depth > SettingsPaneStack.sectionDepth else { return section.title }
        switch section {
        case .tools: return tools.title(inSection(level))
        case .history: return history.title(inSection(level))
        default: return section.title
        }
    }

    private func rows(_ path: PaneStackPath, tools: ToolsStackPanes, history: HistoryStackPanes) -> [String] {
        guard let id = SettingsPaneStack.section(of: path) else { return navigation.sections.map(\.rawValue) }
        let within = SettingsPaneStack.sectionPath(of: path)
        switch SettingsSection(rawValue: id) {
        case .tools: return tools.rows(within)
        case .history: return history.rows(within)
        default: return []
        }
    }

    @ViewBuilder
    private func pane(_ level: PaneLevel, tools: ToolsStackPanes, history: HistoryStackPanes) -> some View {
        if let id = SettingsPaneStack.section(of: level.path), let section = SettingsSection(rawValue: id) {
            switch section {
            case .tools:
                tools.pane(inSection(level))
            case .history:
                history.pane(inSection(level))
                    .onAppear { if level.depth == SettingsPaneStack.sectionDepth { models.history.reload() } }
            default:
                // A minimum of zero keeps a section's ideal size, such as a long line in the
                // instructions editor, from pushing the window or the panes around.
                SettingsSectionContent(section: section, models: models)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            }
        } else {
            SettingsSectionListPane(navigation: navigation)
        }
    }
}

/// The base of Settings as one stack: the sections, each with its icon and name, the chosen one
/// marked, as the fixed sidebar lists them. It is always under the chosen section, so it is a
/// covered pane, and a click on a section in the part that shows picks it.
struct SettingsSectionListPane: View {
    /// The pane's name, for its "Back to" button.
    static let title = "Sections"

    @Bindable var navigation: SettingsNavigation
    @Environment(\.paneStack) private var stack

    var body: some View {
        // A render draws offscreen, where the sidebar's selection material comes out as a solid
        // block over the row. It selects nothing there and draws the highlight itself, as the
        // fixed sidebar does. See `PreviewRender`.
        List(selection: Binding<SettingsSection?>(
            get: { PreviewRender.isRendering ? nil : navigation.section },
            set: { if let section = $0, section != navigation.section { stack.open(section.rawValue) } }
        )) {
            ForEach(navigation.sections) { section in
                // One weight across hover and selection, as in the fixed sidebar.
                Label {
                    Text(section.title).fontWeight(.regular)
                } icon: {
                    Image(systemName: section.symbolName)
                }
                // The row's whole width and height, so a click anywhere on it in the strip finds
                // it. The List's own rows are 32 points apart, and the label is about 21 tall.
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    Color.clear
                        .anchorPreference(key: PaneItemAnchors.self, value: .bounds) { [section.rawValue: $0] }
                        .padding(.vertical, -5.5)
                }
                .tag(section)
                .listRowBackground(
                    PreviewRender.isRendering && navigation.section == section
                        ? RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
                            .padding(.horizontal, 10)
                        : nil)
            }
        }
        .listStyle(.sidebar)
        .frame(width: SettingsRootView.sidebarWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
