import AppKit
import MacOSAgentCore
import SwiftUI

/// The task links above the pill, with the panel with bars experiment on: the links the model
/// set with `set_links` for the current episode, right aligned. See `TaskLinks` in the core.
///
/// - Each link is its label in quiet text, the status line's style, underlined. Under the
///   pointer it takes the theme's accent. Its weight never changes.
/// - Three show. The rest go into a menu at the row's end, so every link stays reachable.
/// - With no links the row is not drawn, so the band starts with the pill.
/// - A click opens the URL in the default browser. Each link's context menu, and the overflow
///   menu, also copy it or clear the row.
struct TaskLinksRow: View {
    let links: [TaskLink]
    var open: @MainActor (TaskLink) -> Void = { TaskLinksRow.openInBrowser($0) }
    var clear: () -> Void = {}

    /// The space above the row, from the band's hairline. The pill's own inset follows below it.
    static let topPadding: CGFloat = 6

    var body: some View {
        if !links.isEmpty {
            let visible = Array(links.prefix(TaskLinks.visibleCount))
            let more = Array(links.dropFirst(TaskLinks.visibleCount))
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                ForEach(visible) { link in
                    TaskLinkButton(link: link, open: open, clear: clear)
                }
                if !more.isEmpty {
                    TaskLinksOverflow(links: more, open: open, clear: clear)
                }
            }
            .font(InputFooter.font)
            .padding(.horizontal, 16)
            .padding(.top, Self.topPadding)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Task links")
        }
    }

    /// Opens a link's URL in the default browser. Only from a click or a menu.
    static func openInBrowser(_ link: TaskLink) {
        guard let url = URL(string: link.url), TaskLinks.isWebURL(link.url) else { return }
        NSWorkspace.shared.open(url)
    }

    static func copy(_ link: TaskLink) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.url, forType: .string)
    }

    /// What VoiceOver says a link opens: its host, such as example.com.
    static func hint(for link: TaskLink) -> String {
        let host = URL(string: link.url)?.host() ?? link.url
        return "Opens \(host) in your browser"
    }
}

/// One link: its label, underlined, quiet until the pointer is over it.
private struct TaskLinkButton: View {
    let link: TaskLink
    let open: @MainActor (TaskLink) -> Void
    let clear: () -> Void
    @State private var hovering = false

    var body: some View {
        Button { open(link) } label: {
            Text(verbatim: link.label)
                .underline()
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(hovering ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(link.url)
        .contextMenu {
            Button("Open Link") { open(link) }
            Button("Copy Link") { TaskLinksRow.copy(link) }
            Divider()
            Button("Clear Links", action: clear)
        }
        .accessibilityLabel(link.label)
        .accessibilityHint(TaskLinksRow.hint(for: link))
        .accessibilityAddTraits(.isLink)
    }
}

/// The links past the first three, in a menu at the row's end.
private struct TaskLinksOverflow: View {
    let links: [TaskLink]
    let open: @MainActor (TaskLink) -> Void
    let clear: () -> Void
    @State private var hovering = false

    var body: some View {
        Menu {
            ForEach(links) { link in
                Button(link.label) { open(link) }
            }
            Divider()
            Button("Clear Links", action: clear)
        } label: {
            Text(verbatim: "+\(links.count)")
                .underline()
                .foregroundStyle(hovering ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(links.map(\.label).joined(separator: ", "))
        .accessibilityLabel("\(links.count) more link\(links.count == 1 ? "" : "s")")
        .accessibilityHint(links.map(\.label).joined(separator: ", "))
    }
}
