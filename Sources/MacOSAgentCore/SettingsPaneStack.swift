import Foundation

/// Settings as one pane stack, behind the experiment "Settings as One Stack of Panes".
///
/// The whole window is one `PaneStackPath`. The section list is the base, at depth 0. The
/// chosen section is the first entry, at depth 1, by its id. A section's own levels, such as
/// Tools' group and tool or History's episode and command, continue the same path from depth 2,
/// so a section sees its own part of the path as it always did: its first level is its depth 0.
///
/// Something is always chosen: the path never goes below depth 1, so the window never shows the
/// section list with nothing over it. Each section keeps its own place while the window is
/// open, so choosing a section from the list brings back where it was left.
public enum SettingsPaneStack {
    /// The depth of a section's first level, and the lowest the stack goes.
    public static let sectionDepth = 1

    /// The window's path for a section and the section's own part of it.
    public static func path(section: String, within sectionPath: PaneStackPath = PaneStackPath()) -> PaneStackPath {
        PaneStackPath([section] + sectionPath.entries)
    }

    /// The section a path shows, or nil when it shows only the section list.
    public static func section(of path: PaneStackPath) -> String? {
        path.entry(at: sectionDepth)
    }

    /// The section's own part of a path: the levels above its first, as the section counts them.
    public static func sectionPath(of path: PaneStackPath) -> PaneStackPath {
        PaneStackPath(Array(path.entries.dropFirst(sectionDepth)))
    }

    /// A depth in the window's stack as the section counts it, where its first level is 0.
    /// Negative for the section list.
    public static func depthInSection(_ depth: Int) -> Int {
        depth - sectionDepth
    }

    /// What a change the stack asked for leads to.
    ///
    /// - A path below a section's first level, such as a click on the section list's strip
    ///   away from any section, or on the chosen section's own row, stays at the chosen
    ///   section's first level. The list never shows alone.
    /// - Another section picked from the list is a swap at depth 1, and it opens that section
    ///   where it was left, with the levels it had open.
    /// - Anything else is as asked.
    ///
    /// - Parameters:
    ///   - requested: The path the stack asked for.
    ///   - current: The path before the change.
    ///   - kept: Each section's own part of the path, as it was last left, by the section's id.
    public static func resolve(
        _ requested: PaneStackPath, from current: PaneStackPath, kept: (String) -> PaneStackPath
    ) -> PaneStackPath {
        guard let section = section(of: requested) else { return current.prefix(sectionDepth) }
        if requested.depth == sectionDepth, section != self.section(of: current) {
            return path(section: section, within: kept(section))
        }
        return requested
    }

    /// What Escape does at a path: it closes the top pane while that pane is above a section's
    /// first level. At a section's first level it returns nil, and Escape does what it did
    /// before the stack, since closing that pane would leave the section list alone.
    public static func escape(from path: PaneStackPath) -> PaneStackPath? {
        guard path.depth > sectionDepth else { return nil }
        return path.prefix(path.depth - 1)
    }
}
