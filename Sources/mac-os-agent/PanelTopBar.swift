import AppKit
import MacOSAgentCore
import SwiftUI

/// What the top bar shows about the panel's place, and the actions that change it. The panel
/// owns it and hands it to its content through the environment.
@MainActor @Observable
final class PanelPlacement {
    /// The edge the panel is docked to, or nil when it floats free.
    var dock: PanelDock?
    var recenter: () -> Void = {}
    /// Docks to the edge, or undocks when the panel is already docked there.
    var toggleDock: (PanelDock) -> Void = { _ in }
}

/// The slim bar across the top of the glass. The whole bar moves the panel, apart from its
/// controls. It has two areas, a leading one and a trailing one, each a row of small items:
///
/// - `leading` is empty for now. A state label, such as the incognito one, or an episode
///   title goes there. Plain text or a small mark, so the bar stays quiet.
/// - `trailing` holds the controls for the panel's place. A new control is one more
///   `TopBarButton` in that row, before the placement controls when it acts on the
///   conversation, such as a clear button.
///
/// A label in either area takes `.allowsHitTesting(false)`, so dragging it still moves the
/// panel. A control does not. Double-clicking the bar does nothing: the panel has no zoom and
/// no minimize, and hiding it on a double click would be easy to do by accident.
struct PanelTopBar: View {
    static let height: CGFloat = 30
    @Environment(PanelPlacement.self) private var placement: PanelPlacement?

    var body: some View {
        HStack(spacing: 0) {
            leading
            Spacer(minLength: 12)
                .allowsHitTesting(false)
            trailing
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background { WindowDragArea() }
    }

    /// Give a label here `.allowsHitTesting(false)`, so dragging it moves the panel.
    private var leading: some View {
        HStack(spacing: 8) {}
    }

    @ViewBuilder
    private var trailing: some View {
        if let placement {
            HStack(spacing: 2) {
                TopBarButton(
                    symbol: "rectangle.center.inset.filled",
                    label: "Re-center",
                    help: "Move back to the center at the default size",
                    isOn: false,
                    action: placement.recenter)
                TopBarButton(
                    symbol: "rectangle.lefthalf.inset.filled",
                    label: "Dock to the Left",
                    help: placement.dock == .left ? "Undock from the left edge" : "Dock to the left edge",
                    isOn: placement.dock == .left,
                    action: { placement.toggleDock(.left) })
                TopBarButton(
                    symbol: "rectangle.righthalf.inset.filled",
                    label: "Dock to the Right",
                    help: placement.dock == .right ? "Undock from the right edge" : "Dock to the right edge",
                    isOn: placement.dock == .right,
                    action: { placement.toggleDock(.right) })
            }
        }
    }
}

/// A small monochrome control in the top bar. It is faint until the pointer is over it, and
/// full strength while it is on. Its size never changes, so hover moves nothing.
struct TopBarButton: View {
    let symbol: String
    let label: String
    let help: String
    var isOn = false
    let action: () -> Void
    @State private var isHovered = false

    static let size: CGFloat = 22

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .opacity(isOn || isHovered ? 0.9 : 0.4)
                .frame(width: Self.size, height: Self.size)
                .background(.primary.opacity(isOn ? 0.12 : isHovered ? 0.07 : 0), in: .rect(cornerRadius: 6))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// The part of the bar that moves the panel. AppKit's own window drag, so it works in a panel
/// that never activates the app.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override var mouseDownCanMoveWindow: Bool { true }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}
