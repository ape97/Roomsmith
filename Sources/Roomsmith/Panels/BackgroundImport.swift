import AppKit
import ImageIO
import RoomsmithCore
import UniformTypeIdentifiers

/// File > Import Background Image…: stores the image in the project package and places it on the active level.
/// The scale starts at 1 mm per pixel; the Calibrate tool then sets the real size.
@MainActor
enum BackgroundImport {
    static func canRun(_ model: AppModel) -> Bool { model.activeLevel != nil }

    static func run(_ model: AppModel) {
        guard model.activeLevel != nil else { return }
        if model.fileURL == nil {
            let a = NSAlert()
            a.messageText = "Save the project first"
            a.informativeText = "Background images are stored inside the project package, so the project needs a file."
            a.addButton(withTitle: "Save…")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn, model.saveAs(), model.fileURL != nil else { return }
        }
        guard let package = model.fileURL else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a scanned plan or sketch"
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importImage(url, into: model, package: package)
    }

    static func importImage(_ url: URL, into model: AppModel, package: URL) {
        guard let levelId = model.activeLevel?.id else { return }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 1, h > 1 else {
            model.lastError = "Could not read \(url.lastPathComponent) as an image"
            return
        }
        // Assets are content-addressed: only remove the copy on failure if this import created it.
        let assetsDir = package.appendingPathComponent("assets", isDirectory: true)
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: assetsDir.path)) ?? [])
        var imported: ProjectAsset?
        do {
            let asset = try ProjectPackage.importAsset(url, kind: .background, into: package)
            imported = asset
            let ok = model.perform("Import Background Image") { p in
                let assetId = p.addAsset(asset)
                let b = BackgroundImage(levelId: levelId, assetId: assetId, calibrationA: P2(0, 0), calibrationB: P2(MM(w), 0),
                                        calibrationLength: MM(w), origin: P2(0, 0))
                try p.addBackground(b)
            }
            guard ok else { discardNewAsset(imported, before: before, package: package); return }
            model.tool = .calibrate
            model.statusMessage = "Imported \(url.lastPathComponent) (\(w) × \(h) px). Click two points of known distance to set the scale"
        } catch {
            discardNewAsset(imported, before: before, package: package)
            model.lastError = "Could not import \(url.lastPathComponent): \(userMessage(for: error))"
        }
    }

    private static func discardNewAsset(_ asset: ProjectAsset?, before: Set<String>, package: URL) {
        guard let asset, !before.contains(asset.storedName) else { return }
        try? FileManager.default.removeItem(at: ProjectPackage.assetURL(asset, in: package))
    }
}
