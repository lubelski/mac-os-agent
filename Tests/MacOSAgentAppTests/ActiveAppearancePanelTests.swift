import AppKit
import MacOSAgentCore
import SwiftUI
import Testing
@testable import mac_os_agent

/// The panel looks the same when it loses focus (MAC-88). These never order a window in: the
/// windows are built offscreen and never take focus.
@MainActor
struct ActiveAppearancePanelTests {
    /// AppKit still asks the window this question. If a later macOS drops it, the glass goes back
    /// to changing on blur, and this says so.
    @Test func appKitStillAsksTheQuestionThePanelAnswers() {
        #expect(NSWindow.instancesRespond(to: NSSelectorFromString(ActiveAppearancePanel.activeAppearanceSelector)))
    }

    @Test func thePanelAndTheInspectorHoldTheActiveLookButNotFocus() {
        let panel = ActiveAppearancePanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
        let answer = panel.perform(NSSelectorFromString(ActiveAppearancePanel.activeAppearanceSelector))
        #expect(answer != nil)
        #expect(!panel.isKeyWindow)
        #expect((SummonPanel.self as AnyClass).isSubclass(of: ActiveAppearancePanel.self))
        #expect((ToolInspectorWindow.self as AnyClass).isSubclass(of: ActiveAppearancePanel.self))
    }

    /// Tinted glass, as Ember's is, in a window without focus: in an ordinary panel the glass
    /// draws its inactive look, with the tint gone gray. In the panel it draws as it does with
    /// focus. Without the panel's answer the two would be the same.
    @Test func tintedGlassKeepsItsActiveLookWithoutFocus() {
        let ordinary = glassFilterInputs(in: NSPanel.self)
        let panel = glassFilterInputs(in: ActiveAppearancePanel.self)
        #expect(!ordinary.isEmpty)
        #expect(ordinary != panel)
    }

    /// The inputs of every Core Animation filter the glass draws with, as text.
    private func glassFilterInputs(in windowClass: NSPanel.Type) -> [String] {
        let window = windowClass.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: Color.clear
            .frame(width: 200, height: 120)
            .glassEffect(.regular.tint(Color(red: 0.23, green: 0.13, blue: 0.08, opacity: 0.86)), in: RoundedRectangle(cornerRadius: 12)))
        host.frame = window.contentLayoutRect
        window.contentView = host
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        var inputs: [String] = []
        func walk(_ layer: CALayer) {
            for filter in layer.filters ?? [] {
                guard let filter = filter as? NSObject else { continue }
                for key in ["inputColorMatrix", "inputBlurOpacity0", "inputShadowOpacity", "inputRefractionOpacity"] {
                    if let value = filter.value(forKey: key) { inputs.append("\(key)=\(value)") }
                }
            }
            layer.sublayers?.forEach(walk)
        }
        if let layer = host.layer { walk(layer) }
        return inputs
    }
}
