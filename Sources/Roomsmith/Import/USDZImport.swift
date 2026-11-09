import AppKit
import RealityKit
import RoomsmithCore
import UniformTypeIdentifiers

/// File > Import 3D Model…: copies a USD/USDZ file into the project package and creates a furniture definition
/// with one `.mesh` component plus an instance on the active level.
///
/// Units and axes: verified with a USDA probe: RealityKit applies `metersPerUnit` and rotates Z-up to Y-up, so
/// `visualBounds` are in metres and Y-up. If the size still looks swapped, the status message hints to check the file.
/// Roomsmith is Z-up with the front at -Y. The size is therefore mapped
/// width = X extent, depth = Z extent, height = Y extent (all in mm).
///
/// Placement needs no offset here: the mesh component sits on the footprint centre at floor height
/// (position z = height / 2, size = bounds), and `MeshAssetCache.fit` shifts the model by the centre of its bounds
/// and scales it into the component box. A model whose origin is not at the bounds centre therefore still ends up
/// with its underside on z = 0 and the bounds centre in the middle of the footprint.
///
/// The asset file is copied into the package before the command runs; if the command fails, a file that was new is
/// removed again so no orphan is left behind.
@MainActor
enum USDZImport {
    /// Sizes outside this range (largest side, mm) trigger a "check the scale" hint but are still imported.
    static let plausibleLargestSide: ClosedRange<MM> = 20...20_000

    struct ImportError: Error, CustomStringConvertible, LocalizedError {
        var description: String
        var errorDescription: String? { description }
        init(_ d: String) { description = d }
    }

    static var allowedTypes: [UTType] {
        [UTType.usdz] + ["usd", "usda", "usdc"].compactMap { UTType(filenameExtension: $0) }
    }

    static func run(_ model: AppModel) {
        if model.fileURL == nil {
            let a = NSAlert()
            a.messageText = "Save the project first"
            a.informativeText = "Imported 3D models are stored inside the project package, so the project needs a file."
            a.addButton(withTitle: "Save…")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn, model.saveAs(), model.fileURL != nil else { return }
        }
        guard let package = model.fileURL else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = allowedTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a USDZ or USD model"
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await importModel(url, into: model, package: package) }
    }

    static func importModel(_ url: URL, into model: AppModel, package: URL) async {
        do {
            let size = try await measure(url)
            // Measuring takes a while: the document may have been saved elsewhere or closed meanwhile.
            guard model.fileURL == package else { throw ImportError("the project was saved or closed while the model was being read") }
            let assetsDir = package.appendingPathComponent("assets", isDirectory: true)
            let (asset, wasNew) = try await Task.detached(priority: .userInitiated) {
                let before = Set((try? FileManager.default.contentsOfDirectory(atPath: assetsDir.path)) ?? [])
                let asset = try ProjectPackage.importAsset(url, kind: .mesh, into: package)
                return (asset, !before.contains(ProjectPackage.assetURL(asset, in: package).lastPathComponent))
            }.value
            // The copy ran in the background: if the document no longer lives in this package, the file would land in a
            // package the project does not reference. Remove what this import created and stop.
            guard model.fileURL == package else {
                if wasNew { try? FileManager.default.removeItem(at: ProjectPackage.assetURL(asset, in: package)) }
                throw ImportError("the project was saved or closed while the model was being copied")
            }
            let name = url.deletingPathExtension().lastPathComponent
            let levelId = model.activeLevelId
            let centre = BuilderSupport.contentCentre(model.project, levelId: levelId)
            var placed: UUID?
            let ok = model.perform("Import 3D Model") { p in
                var a = asset
                a.measuredSize = size
                let assetId = p.addAsset(a)
                var part = Component(name: "Model", shape: .mesh, position: P3(0, 0, size.height / 2), size: size)
                part.meshAssetId = assetId
                var def = FurnitureDefinition(name: name, category: "Imported", size: size, components: [part])
                def.tags = ["imported"]
                _ = p.addDefinition(def)
                placed = try p.addInstance(definitionId: def.id, levelId: levelId, position: P3(centre.x, centre.y, 0))
            }
            guard ok else {
                // Same content may already be referenced by an earlier import; only remove a file this import created.
                if wasNew, !model.project.assets.contains(where: { $0.storedName == asset.storedName }) {
                    try? FileManager.default.removeItem(at: ProjectPackage.assetURL(asset, in: package))
                }
                return
            }
            if let placed { model.selection = [placed] }
            var msg = "Imported \(url.lastPathComponent): \(size.width) × \(size.depth) × \(size.height) mm"
            let largest = max(size.width, size.depth, size.height)
            if !plausibleLargestSide.contains(largest) { msg += ". Check the scale: the file may use unexpected units" }
            model.statusMessage = msg
        } catch {
            model.lastError = "Could not import \(url.lastPathComponent): \(userMessage(for: error))"
        }
    }

    /// Loads the model (RealityKit loads asynchronously, the main thread stays free) and returns its bounds in mm.
    static func measure(_ url: URL) async throws -> Size3 {
        let entity: Entity
        do { entity = try await Entity(contentsOf: url) } catch {
            throw ImportError("the file is not a readable USD/USDZ model (\(error.localizedDescription))")
        }
        let e = entity.visualBounds(relativeTo: nil).extents
        guard e.x.isFinite, e.y.isFinite, e.z.isFinite, e.x > 0 || e.y > 0 || e.z > 0 else {
            throw ImportError("the model has no visible geometry")
        }
        func mm(_ metres: Float) -> MM { max(1, MM((Double(metres) * 1000).rounded())) }
        let size = Size3(mm(e.x), mm(e.z), mm(e.y))
        guard size.isValid else {
            throw ImportError("the model measures \(size.width) × \(size.depth) × \(size.height) mm, above the 100 m limit. Check the units of the file")
        }
        return size
    }
}
