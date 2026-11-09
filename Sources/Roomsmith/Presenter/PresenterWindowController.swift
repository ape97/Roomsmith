import AppKit
import RoomsmithCore

/// Borderless window that fills one screen and shows the composed frames; the primary, real-time path when the TV is an extra
/// display (Apple TV as separate display). Esc closes it; it also closes when its display is disconnected.
@MainActor
final class PresenterWindowController: NSObject, NSWindowDelegate {
    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        var onEscape: (() -> Void)?
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
        }
        override func cancelOperation(_ sender: Any?) { onEscape?() }
    }

    private let window: KeyWindow
    private let contentView = NSView()
    private var screen: NSScreen
    private var screenID: CGDirectDisplayID?
    private var closed = false
    /// Called once when the window closes; the argument explains an involuntary close.
    var onClose: ((String?) -> Void)?

    init(screen: NSScreen) {
        self.screen = screen
        self.screenID = Self.displayID(screen)
        window = KeyWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        super.init()
        window.isReleasedWhenClosed = false
        Self.applyWindowPolicy(to: window)
        window.backgroundColor = .black
        window.hasShadow = false
        window.delegate = self
        window.onEscape = { [weak self] in self?.close() }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.black.cgColor
        contentView.layer?.contentsGravity = .resizeAspect
        contentView.layer?.magnificationFilter = .linear
        window.contentView = contentView
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    /// Space/level policy: the presenter belongs to one display's Space and never floats or follows the user across
    /// Spaces (`.canJoinAllSpaces` + `.floating` made it show on every desktop).
    static func applyWindowPolicy(to window: NSWindow) {
        window.level = .normal
        window.collectionBehavior = [.fullScreenAuxiliary]
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func present() {
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Shows a composed frame. Layer contents give the lowest latency; implicit animations are off.
    func show(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentView.layer?.contents = image
        CATransaction.commit()
    }

    func close() { finish(reason: nil) }

    func windowWillClose(_ notification: Notification) { finish(reason: nil) }

    @objc private func screensChanged() {
        guard !closed else { return }
        if let id = screenID, let current = NSScreen.screens.first(where: { Self.displayID($0) == id }) {
            screen = current
            window.setFrame(current.frame, display: true)   // resolution or arrangement changed
        } else {
            finish(reason: PresenterFailure.displayRemoved.message)
        }
    }

    private func finish(reason: String?) {
        guard !closed else { return }
        closed = true
        window.delegate = nil
        window.orderOut(nil)
        window.close()
        onClose?(reason)
    }

    private static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}
