import AppKit
import MacOSAgentCore
import Observation
import SwiftUI

// A stack of panes that slide over each other from the right, for any Settings section that
// goes several levels deep.
//
// A section keeps a `PaneStackState` in its model, so the stack and each pane's scroll place
// last while the window is open, and shows a `PaneStackView` with three things:
//
// - `pane`: the view for each level, from the base (depth 0) to the top. A pane is usually a
//   `StackPane`, a pinned title over content that scrolls under it.
// - `stripWidth`: how wide each covered pane's strip is, given its depth and the top's depth.
// - `title`: each pane's name, for its strip's "Back to" button.
//
// Inside a pane, a `PaneStackLink` is a row that opens its item one level deeper. The view
// handles the rest: the cards and their drop, dimming and hiding covered panes, clicks on a
// strip, Escape, motion, and giving way when the window is narrow (`PaneStackLayout`).

/// A stack's place and each pane's scroll place, kept by the section's model so both survive
/// leaving the section and coming back while the window is open.
@MainActor
@Observable
final class PaneStackState {
    var path: PaneStackPath
    /// Each pane's scroll offset, by its path. Not observed: it is read only when a pane appears.
    @ObservationIgnored var scrollOffsets: [String: CGFloat] = [:]
    /// For previews and renders: the top pane opens scrolled to its end instead of its top.
    @ObservationIgnored var topStartsAtEnd = false

    init(path: PaneStackPath = PaneStackPath()) {
        self.path = path
    }
}

/// One covered pane's strip, as a section is asked its width.
struct PaneStrip {
    /// The covered pane's depth. 0 is the base.
    let depth: Int
    /// The top pane's depth.
    let topDepth: Int

    /// True for the strip just under the top pane.
    var isNearest: Bool { depth == topDepth - 1 }
}

/// One pane of a stack, as a section is asked to draw it.
struct PaneLevel: Identifiable {
    /// 0 for the base.
    let depth: Int
    /// The path up to this pane. Its last entry is the item this pane shows.
    let path: PaneStackPath
    /// The top pane's depth.
    let topDepth: Int

    var id: String { "\(depth)|\(path)" }
    /// The item this pane shows, or nil for the base.
    var item: String? { path.entry(at: depth) }
    var isCovered: Bool { depth < topDepth }
}

/// What a pane's parts need from the stack: what is open from it and how to open more.
struct PaneStackContext {
    var depth = 0
    var isCovered = false
    /// The item open from this pane, which its row marks.
    var openedID: String?
    /// Where this pane's scroll offset is kept, if anywhere.
    var scrollKey: String?
    weak var state: PaneStackState?
    var startsAtEnd = false
    var open: (String) -> Void = { _ in }
}

extension EnvironmentValues {
    @Entry var paneStack = PaneStackContext()
}

/// Panes that slide over each other from the right. See the top of this file.
struct PaneStackView<Pane: View>: View {
    @Bindable var state: PaneStackState
    let stripWidth: (PaneStrip) -> CGFloat
    let title: (PaneLevel) -> String
    @ViewBuilder let pane: (PaneLevel) -> Pane

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let topDepth = state.path.depth
        let levels = (0...topDepth).map { PaneLevel(depth: $0, path: state.path.prefix($0), topDepth: topDepth) }
        GeometryReader { proxy in
            let widths = PaneStackLayout.stripWidths(
                preferred: (0..<topDepth).map { stripWidth(PaneStrip(depth: $0, topDepth: topDepth)) },
                available: proxy.size.width)
            let edges = PaneStackLayout.leadingEdges(stripWidths: widths)
            let tops = PaneStackLayout.topEdges(stripWidths: widths)
            ZStack(alignment: .topLeading) {
                ForEach(levels) { level in
                    paneView(level)
                        .padding(.leading, edges[level.depth])
                        .padding(.top, tops[level.depth])
                        .transition(level.depth == 0 ? .identity : paneTransition)
                        .zIndex(Double(level.depth))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .clipped()
        .background {
            // Escape closes one pane. With only the base showing there is no button, so Escape
            // means what it meant before.
            if !state.path.isAtBase {
                Button("Back") { change { state.path.goBack() } }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
    }

    private func paneView(_ level: PaneLevel) -> some View {
        let depth = level.depth
        let context = PaneStackContext(
            depth: depth, isCovered: level.isCovered, openedID: state.path.opened(from: depth),
            scrollKey: level.id, state: state, startsAtEnd: state.topStartsAtEnd && !level.isCovered,
            open: { id in change { state.path.open(id, from: depth) } })
        return pane(level)
            .environment(\.paneStack, context)
            .modifier(CoveredPane(
                isCovered: level.isCovered, backLabel: "Back to \(title(level))", openedID: context.openedID,
                click: { item in change { state.path.clickStrip(at: depth, on: item) } }))
            .modifier(PaneCard(level: depth))
    }

    /// Panes slide in from the right, or fade with Reduce Motion on.
    private var paneTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .trailing)
    }

    private func change(_ body: () -> Void) {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.28, bounce: 0), body)
    }
}

// MARK: - Parts a section builds its panes from

/// A pane with a title pinned above a faint line, and content that scrolls under it.
struct StackPane<Content: View>: View {
    let title: Text
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneTitle(title: title, subtitle: subtitle)
            Divider().opacity(0.6)
            PaneScrollView { content }
        }
    }
}

/// A pane's scrolling content. It keeps its place in the stack's state, so a pane comes back
/// where it was left, and it does not scroll while covered.
struct PaneScrollView<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.paneStack) private var stack
    @State private var position = ScrollPosition(idType: Never.self)

    var body: some View {
        ScrollView {
            content
        }
        .scrollPosition($position)
        .defaultScrollAnchor(stack.startsAtEnd ? .bottom : .top)
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y + $0.contentInsets.top }) { _, offset in
            if let key = stack.scrollKey { stack.state?.scrollOffsets[key] = offset }
        }
        .onAppear {
            if let key = stack.scrollKey, let offset = stack.state?.scrollOffsets[key], offset > 0 {
                position.scrollTo(y: offset)
            }
        }
    }
}

/// A row that opens its item one level deeper. On a covered pane, the open item's row stays
/// marked, and a click on another row in the strip opens that item instead.
struct PaneStackLink<Label: View>: View {
    let id: String
    @ViewBuilder let label: Label
    @Environment(\.paneStack) private var stack

    var body: some View {
        let isOpen = stack.openedID == id
        Button { stack.open(id) } label: {
            label.contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background { PaneRowSelection(isSelected: isOpen) }
        .accessibilityAddTraits(isOpen ? .isSelected : [])
        .anchorPreference(key: PaneItemAnchors.self, value: .bounds) { [id: $0] }
    }
}

/// Where each row of a pane is, so a click on a covered strip can tell which row it hit.
struct PaneItemAnchors: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]

    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { first, _ in first }
    }
}

/// A pane's pinned title, with a line of secondary text under it.
struct PaneTitle: View {
    let title: Text
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            title.lineLimit(1).truncationMode(.middle)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct PaneChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

/// A faint line between rows, starting at the rows' text.
struct PaneRowDivider: View {
    let leading: CGFloat

    var body: some View {
        Divider().opacity(0.5).padding(.leading, leading)
    }
}

/// The mark on the open item's row, which stays while a pane covers it.
struct PaneRowSelection: View {
    let isSelected: Bool

    var body: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.22))
                .padding(.horizontal, 4)
        }
    }
}

// MARK: - The stack's own parts

/// The hairline along a card's top and leading edges, round at the top-leading corner.
struct PaneCardEdge: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.minY),
            tangent2End: CGPoint(x: rect.minX + radius, y: rect.minY), radius: radius)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

/// A sliding pane's card: a surface a little lighter than the one under it, round at the
/// top-leading corner, square and flush at the bottom and right, with a shadow to the left.
/// The base (level 0) has no card.
struct PaneCard: ViewModifier {
    static let cornerRadius: CGFloat = 12

    let level: Int
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        if level == 0 {
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            let shape = UnevenRoundedRectangle(topLeadingRadius: Self.cornerRadius, style: .continuous)
            let dark = colorScheme == .dark
            // Each level lifts toward white, a little in dark mode and more in light mode, where
            // the window's gray is already light. It stops lifting after a few levels.
            let lift = Double(min(level, 4))
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background {
                    ZStack {
                        Color(nsColor: .windowBackgroundColor)
                        Color.white.opacity(dark ? 0.045 * lift : min(0.4 * lift, 0.85))
                    }
                }
                .clipShape(shape)
                .overlay {
                    PaneCardEdge(radius: Self.cornerRadius)
                        .offset(x: 0.5 / displayScale, y: 0.5 / displayScale)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1 / displayScale)
                }
                .shadow(color: .black.opacity(dark ? 0.4 : 0.12), radius: 10, x: -4, y: 0)
        }
    }
}

/// A pane under another: dimmed, still, and hidden from accessibility apart from a "Back to"
/// button. A click on its strip goes back to it, or opens another of its rows instead.
struct CoveredPane: ViewModifier {
    let isCovered: Bool
    let backLabel: String
    let openedID: String?
    /// Called with the row the click landed on, if any.
    let click: (String?) -> Void

    func body(content: Content) -> some View {
        content
            .scrollDisabled(isCovered)
            .allowsHitTesting(!isCovered)
            .accessibilityHidden(isCovered)
            .overlayPreferenceValue(PaneItemAnchors.self) { anchors in
                if isCovered {
                    GeometryReader { proxy in
                        Rectangle()
                            .fill(Color.black.opacity(0.3))
                            .contentShape(.rect)
                            .gesture(SpatialTapGesture().onEnded { tap in
                                click(anchors.first { proxy[$0.value].contains(tap.location) }?.key)
                            })
                    }
                    .transition(.opacity)
                    .accessibilityElement()
                    .accessibilityLabel(Text(backLabel))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { click(nil) }
                }
            }
    }
}
