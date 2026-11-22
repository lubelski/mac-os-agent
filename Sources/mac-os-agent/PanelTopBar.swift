import AppKit
import MacOSAgentCore
import SwiftUI

/// What the top bar shows about the panel's place, the actions that change it, and what a
/// window that attaches to the panel needs to know. The panel owns it and hands it to its
/// content through the environment.
@MainActor @Observable
final class PanelPlacement {
    /// The layout the panel is in.
    var preset: PanelPreset = .centered
    /// Moves the panel to a preset.
    var choose: (PanelPreset) -> Void = { _ in }
    /// Hides the panel, as Escape does. It never stops a running task.
    var close: () -> Void = {}

    /// The glass's frame when in place, in screen coordinates.
    var panelFrame: CGRect = .zero
    /// The visible area of the screen the panel is on.
    var visibleFrame: CGRect = .zero

    /// The side of the panel with room beside it, for a window that attaches to the panel's
    /// edge, such as an inspector: the right, unless the panel is in slide over at the right.
    var freeSide: PanelEdge { preset.freeSide }

    /// How much room there is beside the panel on its free side, inside the screen's visible
    /// area and the slide over margin.
    var roomOnFreeSide: CGFloat {
        PanelGeometry.room(on: freeSide, of: panelFrame, in: visibleFrame)
    }

    /// Called with where the glass is on every frame of a slide in or out, and once when the
    /// panel comes to rest shown or hidden. A window that slides with the panel as one unit,
    /// such as an inspector beside it, moves by `offset`, takes `alpha`, and cuts itself off
    /// at `clip`. Not observed, so setting it redraws nothing.
    @ObservationIgnored var onMotion: ((PanelMotionFrame) -> Void)?
}

/// The slim bar across the top of the glass. The whole bar moves the panel, apart from its
/// controls. It has two areas, a leading one and a trailing one, each a row of small items:
///
/// - `leading` starts with the close button. After it is room for a state label, such as the
///   incognito one, a clear button, or an episode title. Plain text or a small mark, so the
///   bar stays quiet.
/// - `trailing` holds the layout menu. A new control is one more `TopBarButton` in that row,
///   before the layout menu.
///
/// A label in either area takes `.allowsHitTesting(false)`, so dragging it still moves the
/// panel. A control does not. Double-clicking the bar does nothing: the panel has no zoom and
/// no minimize, and hiding it on a double click would be easy to do by accident.
struct PanelTopBar: View {
    static let height: CGFloat = 30
    /// The space from the panel's side to the control at each end.
    static let sidePadding: CGFloat = 12
    @Environment(PanelPlacement.self) private var placement: PanelPlacement?

    var body: some View {
        HStack(spacing: 0) {
            leading
            Spacer(minLength: 12)
                .allowsHitTesting(false)
            trailing
        }
        .padding(.horizontal, Self.sidePadding)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background { WindowDragArea() }
    }

    /// The close button, then labels. Give a label here `.allowsHitTesting(false)`, so dragging
    /// it moves the panel.
    @ViewBuilder
    private var leading: some View {
        if let placement {
            HStack(spacing: 8) {
                TopBarButton(
                    symbol: "xmark",
                    label: "Close",
                    help: "Hide the panel. A running task keeps going.",
                    action: placement.close)
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if let placement {
            HStack(spacing: 2) {
                LayoutMenuButton(placement: placement)
            }
        }
    }
}

/// A small monochrome control in the top bar, in the text color like the conversation's
/// marks. It is faint until the pointer is over it, and full strength while it is on. Its size
/// and weight never change, so hover moves nothing.
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

/// The one control for the panel's layout. It shows the current preset's symbol and opens a
/// standard menu of the presets under it.
struct LayoutMenuButton: View {
    let placement: PanelPlacement
    @State private var anchor = MenuAnchor()

    var body: some View {
        TopBarButton(
            symbol: placement.preset.symbol,
            label: "Layout",
            help: "Layout: \(placement.preset.title)",
            action: { anchor.popUp(LayoutMenu(current: placement.preset, choose: placement.choose)) })
            .background(MenuAnchorView(anchor: anchor))
            .accessibilityValue(placement.preset.title)
            .accessibilityHint("Opens a menu of layouts")
    }
}

/// The layout menu: one item per preset, in `PanelPreset.allCases` order, with a check on the
/// current one. A new preset shows up here on its own.
///
/// No item has a keyboard shortcut. The standard ones for placing a window, Fn-Control with
/// an arrow, belong to the system's window tiling and mean half the screen, not slide over.
@MainActor
final class LayoutMenu: NSObject {
    let menu = NSMenu(title: "Layout")
    private let choose: (PanelPreset) -> Void

    init(current: PanelPreset, choose: @escaping (PanelPreset) -> Void) {
        self.choose = choose
        super.init()
        menu.autoenablesItems = false
        for preset in PanelPreset.allCases {
            let item = NSMenuItem(title: preset.title, action: #selector(chosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.rawValue
            item.state = preset == current ? .on : .off
            item.image = NSImage(systemSymbolName: preset.symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
    }

    @objc func chosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let preset = PanelPreset(rawValue: raw) else { return }
        choose(preset)
    }
}

/// The AppKit view under a SwiftUI control, so a menu can open just below the control.
@MainActor
final class MenuAnchor {
    weak var view: NSView?

    /// Opens the menu under the control and waits until it closes. The panel keeps keyboard
    /// focus, and whatever had it inside the panel, such as the text field, has it again after.
    func popUp(_ layoutMenu: LayoutMenu) {
        guard let view, let window = view.window else { return }
        let wasKey = window.isKeyWindow
        let responder = window.firstResponder
        let below = NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : view.bounds.minY - 4)
        // The menu's items target `layoutMenu`, which lives until this returns.
        layoutMenu.menu.popUp(positioning: nil, at: below, in: view)
        Self.restoreFocus(in: window, wasKey: wasKey, responder: responder)
    }

    /// After a menu closes: the panel is key again if it was, with the same first responder.
    static func restoreFocus(in window: NSWindow, wasKey: Bool, responder: NSResponder?) {
        if wasKey, window.isVisible, !window.isKeyWindow { window.makeKey() }
        if let responder, window.firstResponder !== responder { window.makeFirstResponder(responder) }
    }
}

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
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
