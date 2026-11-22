import AppKit
import Carbon.HIToolbox
import MacOSAgentCore
import Observation
import SwiftUI

/// The state behind the shortcut recorder in Settings, General.
///
/// Clicking the recorder starts recording. The next chord pressed becomes the shortcut, if it
/// is allowed. Escape cancels, Delete removes the shortcut. While recording, the hotkey is
/// suspended, so pressing it records it instead of toggling the panel, and a local event
/// monitor swallows every key, so nothing pressed reaches the menus or the focused view.
@MainActor
@Observable
final class ShortcutRecorderModel {
    struct Message: Equatable {
        enum Kind { case problem, warning }
        var kind: Kind
        var text: String
    }

    let controller: SummonTriggerController
    private(set) var isRecording = false
    /// The modifiers held while recording, shown before a key is pressed.
    private(set) var heldModifiers: KeyChord.Modifiers = []
    /// What the last action said: a rejected chord, a failed registration, or a warning.
    var message: Message?

    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var resignObserver: (any NSObjectProtocol)?

    init(controller: SummonTriggerController) {
        self.controller = controller
    }

    /// What the recorder shows.
    var label: String {
        if isRecording {
            return heldModifiers.isEmpty ? "Type a shortcut" : heldModifiers.symbols + "…"
        }
        return controller.displayName ?? "None"
    }

    /// The line under the recorder: this action's message, or else what is wrong with the
    /// shortcut in effect.
    var status: Message? {
        if let message { return message }
        if let problem = controller.problem { return Message(kind: .problem, text: problem) }
        if let conflict = controller.systemConflict { return Message(kind: .warning, text: conflict) }
        return nil
    }

    func toggleRecording(in window: NSWindow?) {
        if isRecording { cancel() } else { startRecording(in: window) }
    }

    func startRecording(in window: NSWindow? = nil) {
        guard !isRecording else { return }
        isRecording = true
        heldModifiers = []
        message = nil
        controller.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            // AppKit calls monitors on the main thread, with an event that never leaves it.
            nonisolated(unsafe) let event = event
            let swallowed = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                return self.handle(event) == nil
            }
            return swallowed ? nil : event
        }
        // Clicking into another app or closing the window ends recording.
        if let window {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            }
        }
    }

    func cancel() {
        guard isRecording else { return }
        stopRecording()
    }

    private func stopRecording() {
        isRecording = false
        heldModifiers = []
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        controller.resume()
    }

    /// Handles a key event while recording. Returns nil when it is swallowed, which is every
    /// key event while recording, so a chord such as Command-W records instead of closing the
    /// window.
    func handle(_ event: NSEvent) -> NSEvent? {
        guard isRecording else { return event }
        let modifiers = KeyChord.Modifiers(eventFlags: event.modifierFlags.rawValue)
        switch event.type {
        case .flagsChanged:
            heldModifiers = modifiers
            return nil
        case .keyUp:
            return nil
        case .keyDown:
            if event.isARepeat { return nil }
            record(KeyChord(keyCode: event.keyCode, modifiers: modifiers))
            return nil
        default:
            return event
        }
    }

    /// Takes a chord as if it had been pressed while recording.
    func record(_ chord: KeyChord) {
        if chord.modifiers.isEmpty {
            switch Int(chord.keyCode) {
            case kVK_Escape:
                stopRecording()
                return
            case kVK_Delete, kVK_ForwardDelete:
                stopRecording()
                clear()
                return
            default: break
            }
        }
        if KeyNames.isModifierKey(chord.keyCode) { return }
        // The same shortcut again changes nothing.
        if case .keyChord(chord)? = controller.trigger, controller.problem == nil {
            stopRecording()
            return
        }
        if let reason = KeyChordRules.rejection(for: chord, keys: controller.keys()) {
            // Stays recording, so the owner can try another chord straight away.
            message = Message(kind: .problem, text: reason)
            heldModifiers = []
            return
        }
        stopRecording()
        show(controller.set(chord))
    }

    func clear() {
        cancel()
        controller.clear()
        message = nil
    }

    func restoreDefault() {
        cancel()
        show(controller.restoreDefault())
    }

    private func show(_ outcome: SummonTriggerController.Outcome) {
        switch outcome {
        case .applied(let warning): message = warning.map { Message(kind: .warning, text: $0) }
        case .rejected(let reason), .failed(let reason): message = Message(kind: .problem, text: reason)
        }
    }
}

/// The recorder: a field that shows the shortcut and records a new one when clicked, with a
/// control to remove it.
struct ShortcutRecorderView: View {
    @Bindable var model: ShortcutRecorderModel
    @State private var window: NSWindow?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                model.toggleRecording(in: window)
            } label: {
                Text(model.label)
                    .foregroundStyle(model.isRecording || model.controller.trigger == nil ? .secondary : .primary)
                    .frame(minWidth: 120)
                    .contentTransition(.identity)
            }
            .buttonStyle(.bordered)
            .overlay {
                if model.isRecording {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel("Summon shortcut")
            .accessibilityValue(model.isRecording ? "Recording. Press a shortcut, or Escape to cancel." : model.controller.spokenName ?? "None")
            .help(model.isRecording ? "Press a shortcut. Escape cancels and Delete removes it." : "Click and press a new shortcut")

            Button {
                model.clear()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove the shortcut")
            .accessibilityLabel("Remove the shortcut")
            .opacity(model.controller.trigger == nil ? 0 : 1)
            .disabled(model.controller.trigger == nil)
        }
        .background(WindowReader(window: $window))
        .onDisappear { model.cancel() }
    }
}

/// Finds the window a SwiftUI view is in.
private struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if window !== view.window {
            DispatchQueue.main.async { window = view.window }
        }
    }
}
