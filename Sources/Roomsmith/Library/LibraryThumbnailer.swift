import AppKit
import RoomsmithCore

/// Renders the pictures of library entries offscreen: the furniture alone in a scratch project, framed like the 3D view.
/// One render at a time (the renderer is shared); results are cached on disk by `LibraryStore`.
@MainActor
enum LibraryThumbnailer {
    private static var busy = false
    private static var waiters: [CheckedContinuation<Void, Never>] = []

    /// Serial queue without polling: a caller waits until the previous render hands the slot over.
    private static func acquire() async {
        if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true }
    }

    private static func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    /// PNG of stored furniture. Entries with models or textures get a scratch package so the meshes load.
    static func render(_ transfer: FurnitureTransfer, size: Int) async throws -> Data {
        let model = AppModel(project: Project.empty(name: "Thumbnail"))
        guard let level = model.project.levels.first else { throw SceneSnapshot.Failure.renderFailed("no level") }
        var scratch: URL?
        defer { if let scratch { try? FileManager.default.removeItem(at: scratch) } }
        if !transfer.assets.isEmpty {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rs-thumb-\(UUID().uuidString).roomsmith", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            scratch = dir
            model.fileURL = dir
        }
        var offset = P2(0, 0)
        if let c = transfer.center { offset = P2(-c.x, -c.y) }
        try FurnitureTransferService.importTransfer(transfer, into: model.store, targetPackage: scratch, levelId: level.id, offset: offset)
        return try await png(of: model, size: size)
    }

    /// PNG of a built-in piece.
    static func render(catalogKey: String, size: Int) async throws -> Data {
        let model = AppModel(project: Project.empty(name: "Thumbnail"))
        guard let level = model.project.levels.first else { throw SceneSnapshot.Failure.renderFailed("no level") }
        try model.store.run("Thumbnail") { p in _ = try p.placeDragged(.catalog(catalogKey), levelId: level.id, at: P2(0, 0)) }
        return try await png(of: model, size: size)
    }

    private static func png(of model: AppModel, size: Int) async throws -> Data {
        await acquire()
        defer { release() }
        let image = try await SceneSnapshot.render(model: model, size: CGSize(width: size, height: size))
        guard let png = SceneSnapshot.png(from: image) else { throw SceneSnapshot.Failure.renderFailed("could not encode the image") }
        return png
    }
}

/// Lets `library.thumbnail` render without the sidebar.
@MainActor
final class LibraryThumbnailBridge: AgentLibraryBridge {
    static let shared = LibraryThumbnailBridge()
    func renderLibraryThumbnail(_ transfer: FurnitureTransfer, size: Int) async throws -> Data {
        do { return try await LibraryThumbnailer.render(transfer, size: size) } catch {
            throw AgentError(code: AgentError.internal, message: error.localizedDescription)
        }
    }
}
