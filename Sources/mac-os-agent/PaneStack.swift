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
    /// The last change the stack made itself, and the path it led to. Not observed: it is set
    /// with the path, and read by the panes' transitions while they come and go.
    @ObservationIgnored private var recorded = (change: PaneStackChange.none, path: PaneStackPath())

    init(path: PaneStackPath = PaneStackPath()) {
        self.path = path
    }

    /// What the change that led to the current path was. A path set from outside the stack,
    /// such as by a preview or when a group goes away, reads as no change, and its panes slide
    /// as they always did.
    var change: PaneStackChange {
        recorded.path == path ? recorded.change : .none
    }

    func record(_ change: PaneStackChange, leadingTo path: PaneStackPath) {
        recorded = (change, path)
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
    /// The item ids a pane lists, top to bottom, given the path that shows it on top. A swap
    /// between two of them moves up or down by their order. Without it a swap only fades.
    var rows: (PaneStackPath) -> [String] = { _ in [] }
    /// Every duration and distance the stack moves by. See `PaneStackMotion`.
    var motion: PaneStackMotion = .standard
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
                // A pane is known by its depth, so a swap keeps its card and changes only what
                // is on it. Opening a depth adds a pane, and going back takes one away.
                ForEach(levels, id: \.depth) { level in
                    paneView(level)
                        .padding(.leading, edges[level.depth])
                        .padding(.top, tops[level.depth])
                        .transition(level.depth == 0 ? .identity : paneTransition(width: proxy.size.width))
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
                Button("Back") { change { _ = $0.goBack() } }
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
            open: { id in change { $0.open(id, from: depth) } })
        // The content is known by the path up to this pane, so a swap replaces it inside the
        // card, which stays.
        return ZStack(alignment: .topLeading) {
            pane(level)
                .environment(\.paneStack, context)
                .id(level.path)
                .transition(swapTransition(depth: depth))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(CoveredPane(
            isCovered: level.isCovered, backLabel: "Back to \(title(level))", openedID: context.openedID,
            click: { item in change { $0.clickStrip(at: depth, on: item) } }))
        .modifier(PaneCard(level: depth))
    }

    /// Panes slide in from the right, or fade with Reduce Motion on. A pane that closes because
    /// a pane under it swapped fades instead, so a swap reads as one change.
    private func paneTransition(width: CGFloat) -> AnyTransition {
        .asymmetric(
            insertion: reduceMotion ? .opacity : .move(edge: .trailing),
            removal: .modifier(
                active: PaneLeaving(state: state, width: width, reduceMotion: reduceMotion, isActive: true),
                identity: PaneLeaving(state: state, width: width, reduceMotion: reduceMotion, isActive: false)))
    }

    /// A pane's content coming and going inside its card, which only a swap does.
    private func swapTransition(depth: Int) -> AnyTransition {
        func effect(_ phase: PaneSwapping.Phase) -> PaneSwapping {
            PaneSwapping(state: state, depth: depth, distance: motion.swapDistance, reduceMotion: reduceMotion, phase: phase)
        }
        return .asymmetric(
            insertion: .modifier(active: effect(.entering), identity: effect(.identity)),
            removal: .modifier(active: effect(.leaving), identity: effect(.identity)))
    }

    /// Makes a change to the path, recording what kind of change it is so the panes' transitions
    /// can follow it, and animates it: a swap with a short ease out, anything else with the
    /// stack's spring.
    private func change(_ mutate: (inout PaneStackPath) -> Void) {
        let old = state.path
        var new = old
        mutate(&new)
        let change = PaneStackChange(from: old, to: new, rows: rows)
        guard change != .none else { return }
        state.record(change, leadingTo: new)
        let animation: Animation = if reduceMotion {
            .easeInOut(duration: motion.reduceMotionFadeDuration)
        } else if change.swapDepth != nil {
            .easeOut(duration: motion.swapDuration)
        } else {
            .spring(duration: motion.slideDuration, bounce: motion.slideBounce)
        }
        withAnimation(animation) { state.path = new }
    }
}

/// A pane leaving the stack. Going back slides it out to the right. When it closes because a
/// pane under it swapped, or with Reduce Motion on, it fades.
///
/// The kind of change is read from the state when the pane leaves, not when it was drawn last,
/// since the pane cannot know beforehand which change will close it.
private struct PaneLeaving: ViewModifier {
    let state: PaneStackState
    /// The stack's width, which takes the pane fully past the right edge.
    let width: CGFloat
    let reduceMotion: Bool
    let isActive: Bool

    func body(content: Content) -> some View {
        let fades = reduceMotion || state.change.swapDepth != nil
        content
            .opacity(isActive && fades ? 0 : 1)
            .offset(x: isActive && !fades ? width : 0)
            .allowsHitTesting(!isActive)
    }
}

/// A pane's content swapping for another item's inside the card: a fade with a short move up
/// or down, by the two items' order in their list. A fade alone with Reduce Motion on, or when
/// the order is not known.
private struct PaneSwapping: ViewModifier {
    enum Phase { case identity, entering, leaving }

    let state: PaneStackState
    let depth: Int
    let distance: CGFloat
    let reduceMotion: Bool
    let phase: Phase

    func body(content: Content) -> some View {
        content
            .opacity(phase == .identity ? 1 : 0)
            .offset(y: offset)
            .allowsHitTesting(phase != .leaving)
    }

    private var offset: CGFloat {
        guard phase != .identity, !reduceMotion, state.change.swapDepth == depth else { return 0 }
        // From below: the new content rises into place and the old one rises out.
        let distance = phase == .entering ? distance : -distance
        switch state.change.swapDirection {
        case .fromBelow: return distance
        case .fromAbove: return -distance
        case .inPlace, nil: return 0
        }
    }
}

// MARK: - Parts a section builds its panes from

/// A pane with a title pinned above a faint line, and content that scrolls under it.
struct StackPane<Content: View>: View {
    /// What the pane's item is inside, as a quiet line above the title, outer before inner.
    var scope: String?
    let title: Text
    var subtitle: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneTitle(scope: scope, title: title, subtitle: subtitle)
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

/// A pane's pinned title, with what it is inside above it and facts about it under it, each a
/// quiet line.
struct PaneTitle: View {
    var scope: String?
    let title: Text
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let scope {
                Text(scope)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            title.lineLimit(1).truncationMode(.middle)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
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
                    .transition(.opacity.ignoringClicksWhileLeaving)
                    .accessibilityElement()
                    .accessibilityLabel(Text(backLabel))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { click(nil) }
                }
            }
    }
}

extension AnyTransition {
    /// The same transition, except that a leaving view stops taking clicks as soon as it starts
    /// to leave. SwiftUI keeps a leaving view in place until its animation settles: about half
    /// a second for the stack's spring, well after it stops showing. A click on a row just
    /// after its pane closed could land on the pane's fading dimming, or on the pane sliding
    /// out, and do nothing (MAC-49).
    var ignoringClicksWhileLeaving: AnyTransition {
        .asymmetric(
            insertion: self,
            removal: combined(with: .modifier(active: IgnoringClicks(isOn: true), identity: IgnoringClicks(isOn: false))))
    }
}

/// Turns hit testing off. As a transition's active state it takes effect when the view starts
/// to leave, since it does not animate.
private struct IgnoringClicks: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        content.allowsHitTesting(!isOn)
    }
}
