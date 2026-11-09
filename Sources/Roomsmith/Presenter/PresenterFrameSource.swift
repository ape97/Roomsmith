import AppKit
import CoreGraphics
import RoomsmithCore

/// Supplies the images the presenter composes. Implementations run on the main actor.
/// To plug in the real 3D view, implement this protocol (or subclass `PresenterModelFrameSource`) and return the snapshot
/// from `sceneFrame(size:)`; bump `contentStamp` whenever the 3D content changes.
@MainActor
protocol PresenterFrameSource: AnyObject {
    /// The pointer drawn into plan frames; set by the engine.
    var pointer: PresenterPointer? { get set }
    /// Changes whenever any frame would look different. The engine renders only on change.
    var contentStamp: Int { get }
    func planFrame(size: CGSize) -> PresenterImage?
    func sceneFrame(size: CGSize) -> PresenterImage?
    /// Told by the engine which 3D pane size is needed (nil: none, or the engine is idle). Lets a source start or stop
    /// producing 3D images; the default does nothing.
    func setSceneSize(_ size: CGSize?)
}

extension PresenterFrameSource {
    func setSceneSize(_ size: CGSize?) {}
}

/// Plan frames from the document through an offscreen `PlanNSView`; the 3D frame comes from `PresenterSceneBridge`
/// (a placeholder until the first image exists).
@MainActor
final class PresenterModelFrameSource: PresenterFrameSource {
    var pointer: PresenterPointer?
    /// Bump to force a new frame, e.g. when the real 3D content changed.
    var externalStamp = 0

    /// Unowned: the model owns the presenter that owns this source.
    private unowned let model: AppModel
    private let view: PlanNSView
    private let bridge: PresenterSceneBridge
    private var fittedKey: Int?
    private var prunedRevision: Int64?

    init(model: AppModel) {
        self.model = model
        self.view = PlanNSView(model: model)
        self.bridge = PresenterSceneBridge(model: model)
    }

    func setSceneSize(_ size: CGSize?) { bridge.setWanted(size) }

    var contentStamp: Int {
        var h = Hasher()
        let p = model.project
        h.combine(p.id)
        h.combine(model.store.contentRevision)   // not the revision: the live camera's write must not re-compose every frame
        h.combine(model.activeLevelId)
        h.combine(externalStamp)
        h.combine(bridge.stamp)
        if let q = pointer?.visiblePosition { h.combine(q.x); h.combine(q.y) }
        return h.finalize()
    }

    func planFrame(size: CGSize) -> PresenterImage? {
        guard let ctx = Self.makeContext(size) else { return nil }
        view.frame = NSRect(origin: .zero, size: size)
        view.vp.size = size
        // This offscreen view is never synced by SwiftUI: forget pictures of removed backgrounds once per content change.
        if prunedRevision != model.store.contentRevision {
            prunedRevision = model.store.contentRevision
            view.pruneBackgroundImages()
        }
        var key = Hasher()
        key.combine(model.project.id)
        key.combine(model.activeLevelId)
        key.combine(model.store.contentRevision)   // the plan may have grown: fit the whole plan again
        key.combine(Int(size.width)); key.combine(Int(size.height))
        let fitKey = key.finalize()
        if fittedKey != fitKey {
            view.fit(selectionOnly: false)
            fittedKey = fitKey
        }
        let viewport = view.vp
        let marker = pointer?.visiblePosition
        view.drawOffscreen(in: ctx, viewport: viewport, scene: view.baseScene) { cg in
            if let marker { PresenterPointer.draw(in: cg, at: viewport.screen(marker)) }
        }
        return ctx.makeImage().map { .cgImage($0) }
    }

    func sceneFrame(size: CGSize) -> PresenterImage? {
        if let image = bridge.image { return image }
        guard let ctx = Self.makeContext(size) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 0.24, green: 0.25, blue: 0.27, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        let text = NSAttributedString(string: "Preparing 3D view…", attributes: [
            .font: NSFont.systemFont(ofSize: max(18, size.height / 14), weight: .medium),
            .foregroundColor: NSColor(white: 0.85, alpha: 1),
        ])
        let box = text.size()
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        text.draw(at: NSPoint(x: (size.width - box.width) / 2, y: (size.height - box.height) / 2))
        NSGraphicsContext.current = previous
        return ctx.makeImage().map { .cgImage($0) }
    }

    private static func makeContext(_ size: CGSize) -> CGContext? {
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                         bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }
}
