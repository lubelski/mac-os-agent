/// How a summoned panel layers with other windows. The panel staying open and the panel
/// staying on top are separate: it stays open until the owner hides it, but it is above other
/// windows only while it has focus, or always when Keep on Top is on. The app's own windows,
/// such as Settings and its sheets and alerts, always win over it.
///
/// Full screen apps and Spaces need nothing here. The panel joins every Space and can show
/// in a full screen app's Space whatever its level, and it is raised whenever it has focus,
/// which is every time it is summoned, so a summon over a full screen app looks as before.
public enum PanelLayer: Sendable, Equatable {
    /// With ordinary windows, so the window the owner brings forward covers it.
    case ordinary
    /// Above ordinary windows, as a floating panel.
    case floating
}

/// What decides a panel's layer.
public struct PanelLayeringState: Sendable, Equatable {
    /// The panel, or its inspector, has keyboard focus.
    public var hasFocus: Bool
    /// The owner turned on Keep on Top.
    public var keepsOnTop: Bool
    /// One of the app's own other windows, such as Settings, a sheet on it, or an alert, took
    /// focus more recently than the panel did and is still open.
    public var ownWindowInFront: Bool

    public init(hasFocus: Bool, keepsOnTop: Bool, ownWindowInFront: Bool) {
        self.hasFocus = hasFocus
        self.keepsOnTop = keepsOnTop
        self.ownWindowInFront = ownWindowInFront
    }
}

/// Where a panel goes among ordinary windows when it drops to them. Changing a window's level
/// puts it in front of the windows of its new level, which would leave it over the window
/// that just took focus, so it is ordered below that window.
public enum PanelLowering: Sendable, Equatable {
    /// Below the app's own window that is in front, such as Settings.
    case belowOwnWindow
    /// Below the front window of the app the owner switched to.
    case belowFrontmostApplication
    /// Where it lands. Nothing took focus from it, such as when it was never in front.
    case inPlace
}

public enum PanelLayering {
    /// The layer for a state. Settings and the app's other windows come first, then focus and
    /// Keep on Top raise the panel.
    public static func layer(for state: PanelLayeringState) -> PanelLayer {
        if state.ownWindowInFront { return .ordinary }
        return state.hasFocus || state.keepsOnTop ? .floating : .ordinary
    }

    /// Where the panel goes when its layer changes from `old` to `new`, or nil when it stays
    /// where it is.
    /// - Parameter anotherApplicationIsFrontmost: whether the frontmost app is not this one,
    ///   as after the owner clicks another app's window or switches with Command-Tab.
    public static func lowering(
        from old: PanelLayer, to new: PanelLayer, ownWindowInFront: Bool, anotherApplicationIsFrontmost: Bool
    ) -> PanelLowering? {
        guard old == .floating, new == .ordinary else { return nil }
        if ownWindowInFront { return .belowOwnWindow }
        return anotherApplicationIsFrontmost ? .belowFrontmostApplication : .inPlace
    }
}

/// Which of the app's own other windows, such as Settings, is in front of a panel. It is in
/// front from when it takes focus until the panel takes focus again or the window closes.
/// Focus moving to another app leaves it in front, so a Finder window Settings reveals, or an
/// app the owner switches to from Settings, is not covered by a panel kept on top.
public struct OwnWindowInFront<ID: Hashable & Sendable>: Sendable, Equatable {
    public private(set) var window: ID?

    public init() {}

    /// The panel or its inspector took focus.
    public mutating func panelTookFocus() { window = nil }

    /// One of the app's own other windows took focus.
    public mutating func ownWindowTookFocus(_ id: ID) { window = id }

    /// A window closed, or was found no longer on screen.
    public mutating func windowClosed(_ id: ID) {
        if window == id { window = nil }
    }
}
