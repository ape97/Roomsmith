import AppKit
import SwiftUI

/// Window-level Esc fallback. The plan and the 3D view handle Esc themselves, but only while they are the first
/// responder; after selecting through the sidebar, the inspector or the toolbar the key went nowhere. With a selection
/// and the focus on such a control, Esc now clears the selection.
/// Not touched: a text field (Esc only cancels its editing), the plan and the 3D view (they cancel a running action
/// first), windows with a sheet and Esc with modifier keys.
/// Delete/Backspace (no modifiers) takes the same route and deletes the unlocked part of the selection.
/// In the Hand tool Esc returns to Select and Delete does nothing.
struct EscapeClearsSelection: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.model = model
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) { probe.model = model }

    static func dismantleNSView(_ probe: Probe, coordinator: ()) { probe.removeMonitor() }

    final class Probe: NSView {
        var model: AppModel?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            // Local monitors run on the main thread; the SDK just does not say so for the closure.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                nonisolated(unsafe) let event = event
                let used = MainActor.assumeIsolated { self?.consume(event) ?? false }
                return used ? nil : event
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// True when the event was used. Internal so tests can run the monitor's logic (a local monitor only
        /// sees events that go through the running application).
        func consume(_ event: NSEvent) -> Bool {
            let isEsc = event.keyCode == 53
            guard let window, event.window === window, isEsc || KeyCode.isDelete(event.keyCode),
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  window.attachedSheet == nil, let model, model.sheet == nil
            else { return false }
            let responder = window.firstResponder
            if responder is NSText || responder is PlanNSView || responder is SceneARView { return false }
            // Hand tool: Esc returns to Select (the selection stays); Delete changes nothing.
            if model.tool == .hand {
                guard isEsc else { return false }
                model.tool = .select
                return true
            }
            guard !model.selection.isEmpty else { return false }
            if isEsc { model.selection = [] } else { model.deleteUnlocked(model.selectionIds) }
            return true
        }
    }
}
