import AppKit
@testable import Roomsmith

/// Windows of the hosted tests must never appear, take focus or activate the app, so running them does not disturb
/// whoever uses the Mac. Three measures, none of which changes what a test checks:
/// - the process becomes an agent (activation policy `.prohibited`: no Dock icon, no menu bar, never frontmost) before the first window exists;
/// - every window is borderless and sits far off screen at its own size, and is shown only with `orderBack` (behind everything, never key, never main);
/// - the windows of an earlier test are ordered out when the next test makes its first window, so none stays behind (`prune: false` for a second window of the same test).
/// First responders, layout, drawing, drag and key-event calls need no key window and work as before.
@MainActor
enum QuietWindows {
    private static var started = false
    private static var shown: [NSWindow] = []

    /// Makes the process an agent. Safe to call again.
    static func start() {
        guard !started else { return }
        started = true
        _ = NSApplication.shared
        _ = NSApp.setActivationPolicy(.prohibited)
    }

    /// A borderless off-screen window. Nothing is shown until `show`.
    static func make(width: CGFloat, height: CGFloat, styleMask: NSWindow.StyleMask = [.borderless], prune: Bool = true) -> NSWindow {
        start()
        if prune {
            for w in shown { w.orderOut(nil) }
            shown.removeAll()
        }
        let w = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: width, height: height), styleMask: styleMask, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.hidesOnDeactivate = false
        w.canHide = false
        w.collectionBehavior = [.stationary, .ignoresCycle, .transient]
        return w
    }

    /// Puts the window on the window list behind all others (never in front, never key), as the hosted views need to lay out and draw.
    static func show(_ window: NSWindow) {
        window.orderBack(nil)
        shown.append(window)
    }
}
