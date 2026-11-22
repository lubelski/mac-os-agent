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
    /// The panel menu's last item, as Command-W does. The main panel hides, as Escape does, and
    /// its task keeps going. The incognito window closes and discards its conversation.
    var close: () -> Void = {}
    /// A double click on the bar: back to the default frame of the current layout, forgetting
    /// the owner's moves and resizes in it.
    var resetToDefault: () -> Void = {}
    /// False for the incognito window, which has no layouts.
    var offersLayouts = true
    /// Keep on Top is on: the panel stays above other apps' windows without focus.
    var keepsOnTop = false
    /// Turns Keep on Top on or off. Nil in the incognito window, which shows the setting but
    /// never writes it.
    var setKeepsOnTop: ((Bool) -> Void)?

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
/// controls, and a double click on it puts the panel back in its layout's default frame. The
/// pointer stays the arrow over it. It has three areas:
///
/// - `title`, in the middle of the bar: the agent's name from Settings, General. It is
///   centered on the whole bar, not on the room between the other two areas, and it is cut
///   short before it would reach them. In the incognito window the incognito label follows
///   the name. Its font and weight never change.
/// - `leading`: empty in the main panel, and the Clear control in the incognito window. Later
///   this is room for an episode title.
/// - `trailing`: the panel menu, an ellipsis, after a quiet pin mark while Keep on Top is on,
///   so a panel that will not go behind other windows explains itself. A new control is one
///   more `TopBarButton` in that row, before the menu.
///
/// A label takes `.allowsHitTesting(false)`, so dragging it still moves the panel and a double
/// click on it still resets the frame. A control does not.
struct PanelTopBar: View {
    /// What the incognito window's bar adds.
    struct Incognito {
        /// False while there is nothing to clear.
        var canClear: Bool
        var clear: () -> Void
    }

    static let height: CGFloat = 30
    /// False only for an offscreen render, which cannot draw the AppKit views behind the bar's
    /// drag area and menu anchor.
    nonisolated(unsafe) static var hostsAppKitViews = true
    /// The space from the panel's side to the control at each end.
    static let sidePadding: CGFloat = 12
    /// The least space between the title and the controls at either side.
    static let titleGap: CGFloat = 8
    /// Set for the incognito window.
    var incognito: Incognito?
    @Environment(PanelPlacement.self) private var placement: PanelPlacement?
    @AgentName private var agentName
    @State private var leadingWidth: CGFloat = 0
    @State private var trailingWidth: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            leading
                .onGeometryChange(for: CGFloat.self, of: \.size.width) { leadingWidth = $0 }
            Spacer(minLength: 12)
                .allowsHitTesting(false)
            trailing
                .onGeometryChange(for: CGFloat.self, of: \.size.width) { trailingWidth = $0 }
        }
        .padding(.horizontal, Self.sidePadding)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .overlay {
            // The same room off both sides keeps the title centered on the whole bar.
            title
                .padding(.horizontal, Self.sidePadding + max(leadingWidth, trailingWidth) + Self.titleGap)
        }
        .background { if Self.hostsAppKitViews { WindowDragArea(onDoubleClick: { placement?.resetToDefault() }) } }
    }

    /// The agent's name, and in the incognito window the incognito label after it.
    private var title: some View {
        HStack(spacing: 6) {
            Text(agentName)
                .font(Self.titleFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityAddTraits(.isHeader)
            if incognito != nil {
                IncognitoLabel()
                    .layoutPriority(1)
            }
        }
        .allowsHitTesting(false)
    }

    /// One font in every state, so nothing shifts when the panel gains or loses focus.
    static let titleFont = Font.system(size: 12, weight: .medium)

    /// Give a label here `.allowsHitTesting(false)`, so dragging it moves the panel.
    @ViewBuilder
    private var leading: some View {
        if placement != nil, let incognito {
            TopBarTextButton(
                title: "Clear",
                help: "Discard this conversation and start a new one. The window stays open.",
                isEnabled: incognito.canClear,
                action: incognito.clear)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if let placement {
            HStack(spacing: 2) {
                if placement.keepsOnTop {
                    KeepOnTopMark(turnOff: placement.setKeepsOnTop.map { set in { set(false) } })
                }
                PanelMenuButton(placement: placement)
            }
        }
    }
}

/// The incognito window's label, there for the window's whole life, on the theme's incognito
/// badge fill. Dragging it moves the window.
struct IncognitoLabel: View {
    static let text = "Incognito. Nothing here is kept."
    @Environment(\.panelPalette) private var palette

    var body: some View {
        Text(Self.text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(palette.incognitoBadge, in: .capsule)
            .allowsHitTesting(false)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A small word in the top bar that acts, such as Clear, in the text color. It is faint until
/// the pointer is over it, like `TopBarButton`, and its weight never changes.
struct TopBarTextButton: View {
    let title: String
    let help: String
    var isEnabled = true
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.panelPalette) private var palette

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.primary)
                .opacity(!isEnabled ? 0.25 : isHovered ? 0.9 : 0.55)
                .padding(.horizontal, 6)
                .frame(height: TopBarButton.size)
                .background(palette.textTint(isEnabled && isHovered ? 0.07 : 0), in: PanelShape.control)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(title)
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
    @Environment(\.panelPalette) private var palette

    static let size: CGFloat = 22

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .opacity(isOn || isHovered ? 0.9 : 0.4)
                .frame(width: Self.size, height: Self.size)
                .background(palette.textTint(isOn ? 0.12 : isHovered ? 0.07 : 0), in: PanelShape.control)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// The quiet mark that Keep on Top is on: a pin, as faint as an idle control. In the main
/// panel clicking it turns Keep on Top off. In the incognito window it is only a mark, since
/// that window writes nothing to the preferences, and dragging it moves the window.
struct KeepOnTopMark: View {
    static let symbol = "pin"
    static let label = "Keep on Top is on"
    /// Nil in the incognito window.
    let turnOff: (() -> Void)?

    var body: some View {
        if let turnOff {
            TopBarButton(
                symbol: Self.symbol,
                label: Self.label,
                help: "Keep on Top is on, so the panel stays above other windows. Click to turn it off.",
                action: turnOff)
                .accessibilityHint("Turns Keep on Top off")
        } else {
            Image(systemName: Self.symbol)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .opacity(0.4)
                .frame(width: TopBarButton.size, height: TopBarButton.size)
                .allowsHitTesting(false)
                .accessibilityLabel(Self.label)
        }
    }
}

/// The panel menu's control: an ellipsis that opens a standard menu under it. In the main
/// panel the menu has the layouts, Keep on Top, and Hide Panel. In the incognito window it has
/// only Close and Discard, its one pointer route to closing, since Escape never closes it.
struct PanelMenuButton: View {
    static let symbol = "ellipsis"
    let placement: PanelPlacement
    @State private var anchor = MenuAnchor()

    var body: some View {
        TopBarButton(
            symbol: Self.symbol,
            label: placement.offersLayouts ? "Panel Menu" : "Window Menu",
            help: placement.offersLayouts ? "Layout: \(placement.preset.title), Keep on Top, and Hide" : "Close and Discard",
            action: {
                anchor.popUp(PanelMenu(
                    current: placement.offersLayouts ? placement.preset : nil, choose: placement.choose,
                    keepsOnTop: placement.keepsOnTop, setKeepsOnTop: placement.setKeepsOnTop,
                    close: placement.close))
            })
            .background { if PanelTopBar.hostsAppKitViews { MenuAnchorView(anchor: anchor) } }
            .accessibilityValue(placement.offersLayouts ? placement.preset.title : "")
            .accessibilityHint(placement.offersLayouts ? "Opens a menu of layouts and Hide" : "Opens a menu with Close and Discard")
    }
}

/// The panel menu. In the main panel: one item per preset, in `PanelPreset.allCases` order,
/// with a check on the current one, so a new preset shows up here on its own. Below a
/// separator, Keep on Top, checked while it is on. It is one setting for every preset. Below
/// another, Hide Panel, which does what Command-W and Escape do.
///
/// In the incognito window, which has no layouts and never writes Keep on Top, only Close and
/// Discard, which does what Command-W does: it closes at once with no task running, and asks
/// first with one.
///
/// No layout item has a keyboard shortcut. The standard ones for placing a window, Fn-Control
/// with an arrow, belong to the system's window tiling and mean half the screen, not slide
/// over. The last item shows Command-W, which it matches.
@MainActor
final class PanelMenu: NSObject {
    let menu = NSMenu(title: "Panel")
    private let choose: (PanelPreset) -> Void
    private let keepsOnTop: Bool
    private let setKeepsOnTop: ((Bool) -> Void)?
    private let close: () -> Void
    static let keepOnTopTitle = "Keep on Top"
    static let hideTitle = "Hide Panel"
    static let closeAndDiscardTitle = "Close and Discard"

    /// - Parameter current: the current preset, or nil for a window with no layouts.
    init(
        current: PanelPreset?, choose: @escaping (PanelPreset) -> Void = { _ in },
        keepsOnTop: Bool = false, setKeepsOnTop: ((Bool) -> Void)? = nil,
        close: @escaping () -> Void = {}
    ) {
        self.choose = choose
        self.keepsOnTop = keepsOnTop
        self.setKeepsOnTop = setKeepsOnTop
        self.close = close
        super.init()
        menu.autoenablesItems = false
        if let current {
            for preset in PanelPreset.allCases {
                let item = NSMenuItem(title: preset.title, action: #selector(chosen(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = preset.rawValue
                item.state = preset == current ? .on : .off
                item.image = NSImage(systemSymbolName: preset.symbol, accessibilityDescription: nil)
                menu.addItem(item)
            }
        }
        if setKeepsOnTop != nil {
            menu.addItem(.separator())
            let item = NSMenuItem(title: Self.keepOnTopTitle, action: #selector(toggledKeepOnTop(_:)), keyEquivalent: "")
            item.target = self
            item.state = keepsOnTop ? .on : .off
            item.toolTip = "Stay above other apps' windows without focus. Settings still comes in front."
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let item = NSMenuItem(
            title: current == nil ? Self.closeAndDiscardTitle : Self.hideTitle,
            action: #selector(closed(_:)), keyEquivalent: "w")
        item.keyEquivalentModifierMask = .command
        item.target = self
        item.toolTip = current == nil
            ? "Close this window. Everything in it is discarded."
            : "Hide the panel. A running task keeps going."
        menu.addItem(item)
    }

    @objc func toggledKeepOnTop(_ sender: NSMenuItem) {
        setKeepsOnTop?(!keepsOnTop)
    }

    @objc func chosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let preset = PanelPreset(rawValue: raw) else { return }
        choose(preset)
    }

    @objc func closed(_ sender: NSMenuItem) {
        close()
    }
}

/// The AppKit view under a SwiftUI control, so a menu can open just below the control.
@MainActor
final class MenuAnchor {
    weak var view: NSView?

    /// Opens the menu under the control and waits until it closes. The panel keeps keyboard
    /// focus, and whatever had it inside the panel, such as the text field, has it again after.
    func popUp(_ panelMenu: PanelMenu) {
        guard let view, let window = view.window else { return }
        let wasKey = window.isKeyWindow
        let responder = window.firstResponder
        let below = NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : view.bounds.minY - 4)
        // The menu's items target `panelMenu`, which lives until this returns.
        panelMenu.menu.popUp(positioning: nil, at: below, in: view)
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
/// that never activates the app. The pointer stays the arrow over it. A double click calls
/// `onDoubleClick` instead of starting a drag.
struct WindowDragArea: NSViewRepresentable {
    var onDoubleClick: () -> Void = {}

    final class DragView: NSView {
        var onDoubleClick: () -> Void = {}

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                onDoubleClick()
                return
            }
            window?.performDrag(with: event)
        }

        override var mouseDownCanMoveWindow: Bool { true }
    }

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: DragView, context: Context) {
        nsView.onDoubleClick = onDoubleClick
    }
}
