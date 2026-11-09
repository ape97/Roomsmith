import AppKit
import Foundation
import SwiftUI

/// Environment hooks for checks without simulated input. They only act under `ROOMSMITH_TEST_MODE`.
///
/// - `ROOMSMITH_HIDE=sidebar,inspector,statusbar`: start with these panels hidden (seeded in `AppDefaults.store`, so they
///   are hidden from the first frame).
/// - `ROOMSMITH_SIDEBAR_TAB=levels|objects|catalog`: open the sidebar on this tab (seeded in `AppDefaults.store`).
/// - `ROOMSMITH_APPEARANCE=dark|light`: force the app appearance (this process only).
/// - `ROOMSMITH_WINDOW_SIZE=1000x700`: content size of the main window in points.
/// - `ROOMSMITH_SNAPSHOT=/path/name`: after `ROOMSMITH_SNAPSHOT_AFTER` seconds (default 9) write this process's own windows
///   as `<name>-<n>.png` and quit. Needed where `screencapture` has no screen-recording permission; own windows need none.
///   The selected segment of the toolbar tool picker is drawn wrongly in these pictures (a plain pill).
/// - `ROOMSMITH_SNAPSHOT_SETTINGS=general|appearance|walk`: together with `ROOMSMITH_SNAPSHOT`, also draws the Settings view on
///   this tab into `<name>-settings-<tab>.png` (an offscreen window; the real Settings window is never opened).
/// - `ROOMSMITH_SNAPSHOT_PANE=inspector,agent,presenter`: together with `ROOMSMITH_SNAPSHOT`, also draws these panes offscreen
///   (`<path>-pane-<name>.png`); the inspector shows the current selection (set `ROOMSMITH_SELECT`).
/// - `ROOMSMITH_SNAPSHOT_SHEET=photo`: together with `ROOMSMITH_SNAPSHOT`, also draws the empty "Furniture from photos"
///   sheet into `<name>-sheet-photo.png` (offscreen, like the Settings picture).
/// - `ROOMSMITH_SNAPSHOT_SHEET=preview`: draws the library preview sheet of the first My Furniture entry into
///   `<name>-sheet-preview.png`. The 3D area stays empty in this picture (Metal layers are not drawn offscreen).
/// - `ROOMSMITH_LIBRARY_COLLAPSE=<category name>[,...]`: starts with these categories (or "My furniture") folded;
/// - `ROOMSMITH_SELECT=first|<name>`: shortly after launch select the first object of the active level (furniture
///   preferred) or the first one whose title contains `<name>`, so the inspector shows in pictures.
/// - `ROOMSMITH_SHOW_PRESENTER=1`: open the presenter sheet; `=start` also starts presenting plan + 3D side by side
///   (loopback only under test mode) and opens the sheet once the preview runs.
@MainActor
enum TestHooks {
    private static var ran = false

    static func apply(model: AppModel, hide: (String) -> Void) {
        guard AppDefaults.isTestMode, !ran else { return }
        ran = true
        let env = ProcessInfo.processInfo.environment
        // Normally already hidden by the seeded defaults; this keeps the window state in step.
        for item in (env["ROOMSMITH_HIDE"] ?? "").split(separator: ",") { hide(item.trimmingCharacters(in: .whitespaces)) }
        switch env["ROOMSMITH_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        if let spec = env["ROOMSMITH_WINDOW_SIZE"] {
            let parts = spec.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(600))
                    let window = NSApp.windows.first {
                        ($0.isVisible || NSApp.isHidden) && $0.styleMask.contains(.titled) && !$0.title.hasSuffix("3D")
                    }
                    window?.setContentSize(NSSize(width: parts[0], height: parts[1]))
                }
            }
        }
        for name in (env["ROOMSMITH_LIBRARY_COLLAPSE"] ?? "").split(separator: ",").map(String.init) {
            if name == "My furniture" { AppDefaults.store.set(false, forKey: "library.open.mine") }
            else if let c = LibraryModel.shared.categories.first(where: { $0.name == name }) {
                AppDefaults.store.set(false, forKey: "library.open.cat.\(c.id.uuidString)")
            }
        }
        if let wanted = env["ROOMSMITH_SELECT"], !wanted.isEmpty {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2.5))
                select(wanted, in: model)
            }
        }
        if let base = env["ROOMSMITH_SNAPSHOT"], !base.isEmpty {
            let after = Double(env["ROOMSMITH_SNAPSHOT_AFTER"] ?? "") ?? 9
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(after))
                await snapshotWindows(to: base)
                if let tab = env["ROOMSMITH_SNAPSHOT_SETTINGS"].flatMap(SettingsTab.init(rawValue:)) {
                    snapshotSettings(tab, model: model, to: "\(base)-settings-\(tab.rawValue).png")
                }
                if env["ROOMSMITH_SNAPSHOT_SHEET"] == "photo" {
                    snapshotOffscreen(PhotoToFurnitureSheet(improveEntryId: nil).environment(model), minSize: NSSize(width: 560, height: 520),
                                      to: "\(base)-sheet-photo.png")
                }
                if env["ROOMSMITH_SNAPSHOT_SHEET"] == "preview", let first = LibraryModel.shared.entries.first {
                    snapshotOffscreen(LibraryPreviewSheet(target: .entry(first.id)).environment(model), minSize: NSSize(width: 720, height: 560),
                                      to: "\(base)-sheet-preview.png")
                }
                for pane in (env["ROOMSMITH_SNAPSHOT_PANE"] ?? "").split(separator: ",").map(String.init) {
                    switch pane {
                    case "inspector":
                        snapshotOffscreen(InspectorView().environment(model), minSize: NSSize(width: 340, height: 760),
                                          to: "\(base)-pane-inspector.png")
                    case "agent":
                        snapshotOffscreen(AgentPanel().environment(model).frame(minWidth: 560, minHeight: 420),
                                          minSize: NSSize(width: 560, height: 420), to: "\(base)-pane-agent.png")
                    case "presenter":
                        if let engine = model.presenter {
                            snapshotOffscreen(PresenterPanel(engine: engine).environment(model).padding(14),
                                              minSize: NSSize(width: 360, height: 300), to: "\(base)-pane-presenter.png")
                        }
                    default: break
                    }
                }
                NSApp.terminate(nil)
            }
        }
        if let mode = env["ROOMSMITH_SHOW_PRESENTER"], !mode.isEmpty {
            Task { @MainActor in
                if mode == "start", let engine = model.presenter {
                    engine.layout = .sideBySide
                    engine.start()
                    try? await Task.sleep(for: .seconds(6))
                } else {
                    try? await Task.sleep(for: .seconds(1))
                }
                model.showPresenter = true
            }
        }
    }

    private static func select(_ wanted: String, in model: AppModel) {
        let sections = ObjectTree.build(model.project, levelId: model.activeLevelId, search: wanted == "first" ? "" : wanted, collapsed: [])
        let rows = sections.flatMap(\.1)
        let pick = wanted == "first" ? (sections.first { $0.0 == .furniture }?.1.first ?? rows.first) : rows.first
        if let pick { model.selection = [pick.id] }
    }

    /// Draws the Settings view into a PNG through an offscreen window.
    private static func snapshotSettings(_ tab: SettingsTab, model: AppModel, to path: String) {
        snapshotOffscreen(SettingsView(initialTab: tab).environment(model), minSize: NSSize(width: 480, height: 680), to: path)
    }

    /// Draws any view into a PNG through an offscreen window (used for Settings and sheets, which have no own window here).
    private static func snapshotOffscreen(_ root: some View, minSize: NSSize, to path: String) {
        let host = NSHostingView(rootView: root)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: NSSize(width: max(size.width, minSize.width), height: max(size.height, minSize.height)))
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSApp.appearance
        host.layoutSubtreeIfNeeded()
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: path)) }
    }

    /// Writes every visible window of this process to PNG by drawing its view hierarchy (no screen-recording permission,
    /// no focus change). `cacheDisplay` leaves Metal layers empty, so each 3D view is rendered offscreen with its live
    /// camera and keyed into its frame (see `composite3D`). Glass is drawn flat in this mode (`GlassMode`), and the
    /// selected segment of a segmented control may come out blank.
    private static func snapshotWindows(to base: String) async {
        var n = 0
        // A hidden app (`open -j`) has no visible windows; its titled windows still draw into a bitmap.
        let hidden = NSApp.isHidden
        for window in NSApp.windows where window.frame.width > 100
            && (window.isVisible || (hidden && window.styleMask.contains(.titled) && !window.isMiniaturized)) {
            guard let view = window.contentView?.superview ?? window.contentView else { continue }
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let out = await composite3D(rep, root: view) ?? rep
            if let data = out.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: "\(base)-\(n).png"))
                n += 1
            }
        }
    }

    /// The window picture with its 3D views filled in, or nil when the window has none (or rendering failed).
    private static func composite3D(_ rep: NSBitmapImageRep, root: NSView) async -> NSBitmapImageRep? {
        let scenes = SceneSnapshot.liveViews(in: root.window)
        guard !scenes.isEmpty, let cached = rep.cgImage, root.bounds.width > 0 else { return nil }
        let scale = CGFloat(rep.pixelsWide) / root.bounds.width
        var layers: [(CGImage, CGRect)] = []
        for v in scenes {
            let r = v.convert(v.bounds, to: root)
            let px = CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale).integral
            guard px.width >= 16, px.height >= 16 else { continue }
            let dark = v.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            guard let img = try? await SceneSnapshot.render(model: v.renderer.model, camera: v.renderer.camera.rig.state,
                                                         size: px.size, dark: dark) else { continue }
            layers.append((img, px))
        }
        guard !layers.isEmpty,
              let ctx = CGContext(data: nil, width: rep.pixelsWide, height: rep.pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let under = CGContext(data: nil, width: rep.pixelsWide, height: rep.pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let full = CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
        ctx.draw(cached, in: full)
        // Root coordinates grow upwards unless the root view is flipped; the bitmap context always grows upwards.
        var rects: [CGRect] = []
        for (img, px) in layers {
            let r = CGRect(x: px.minX, y: root.isFlipped ? full.height - px.maxY : px.minY, width: px.width, height: px.height)
            under.draw(img, in: r)
            rects.append(r)
        }
        // The 3D area of the cached picture is a flat fill with the overlay controls on top: replace the fill (its most
        // common colour) by the render and keep everything else.
        guard let top = ctx.data?.assumingMemoryBound(to: UInt8.self),
              let bottom = under.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let row = ctx.bytesPerRow, rowU = under.bytesPerRow, h = ctx.height
        for r in rects {
            let x0 = max(0, Int(r.minX)), x1 = min(ctx.width, Int(r.maxX))
            // Context memory starts at the top row.
            let y0 = max(0, h - Int(r.maxY)), y1 = min(h, h - Int(r.minY))
            guard x1 > x0, y1 > y0 else { continue }
            var counts: [UInt32: Int] = [:]
            for y in stride(from: y0, to: y1, by: 7) {
                for x in stride(from: x0, to: x1, by: 7) {
                    let i = y * row + x * 4
                    counts[UInt32(top[i]) << 16 | UInt32(top[i + 1]) << 8 | UInt32(top[i + 2]), default: 0] += 1
                }
            }
            guard let key = counts.max(by: { $0.value < $1.value })?.key else { continue }
            let kr = Int(key >> 16 & 0xFF), kg = Int(key >> 8 & 0xFF), kb = Int(key & 0xFF)
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let i = y * row + x * 4, j = y * rowU + x * 4
                    if abs(Int(top[i]) - kr) <= 3, abs(Int(top[i + 1]) - kg) <= 3, abs(Int(top[i + 2]) - kb) <= 3 {
                        top[i] = bottom[j]; top[i + 1] = bottom[j + 1]; top[i + 2] = bottom[j + 2]; top[i + 3] = 255
                    }
                }
            }
        }
        return ctx.makeImage().map { NSBitmapImageRep(cgImage: $0) }
    }
}
