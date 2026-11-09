import AppKit
import CoreGraphics
import ImageIO
import Observation
import RoomsmithCore
import SwiftUI
import UniformTypeIdentifiers

enum ExportFormat: Sendable {
    case pdf, svg, png, obj

    var fileExtension: String {
        switch self { case .pdf: "pdf"; case .svg: "svg"; case .png: "png"; case .obj: "obj" }
    }
    var contentType: UTType {
        switch self {
        case .pdf: .pdf
        case .svg: .svg
        case .png: .png
        case .obj: UTType(filenameExtension: "obj") ?? .data
        }
    }
    var isPlan: Bool { self != .obj }
}

/// Choices shown as accessory of the save panel. Paper, orientation and scale types live in RoomsmithCore (`PlanFit`).
@MainActor @Observable
final class ExportOptions {
    /// US and Canada print on Letter, everywhere else on A4.
    var paper: PaperFormat = ["US", "CA"].contains(Locale.current.region?.identifier ?? "") ? .letter : .a4
    var orientation: PaperOrientation = .auto
    var scale: ScaleChoice = .fit
    var allLevels = false
}

struct ExportOptionsView: View {
    @Bindable var options: ExportOptions
    let format: ExportFormat
    let levelName: String

    var body: some View {
        Form {
            if format.isPlan {
                Picker("Paper", selection: $options.paper) {
                    ForEach(PaperFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Orientation", selection: $options.orientation) {
                    Text("Automatic").tag(PaperOrientation.auto)
                    Text("Landscape").tag(PaperOrientation.landscape)
                    Text("Portrait").tag(PaperOrientation.portrait)
                }
                Picker("Scale", selection: $options.scale) {
                    ForEach(ScaleChoice.all) { Text($0.title).tag($0) }
                }
            }
            Picker("Levels", selection: $options.allLevels) {
                Text("Active level only (\(levelName))").tag(false)
                Text(format.isPlan ? "All levels (one file each)" : "All visible levels").tag(true)
            }
        }
        .padding(12)
        .frame(width: 360)
    }
}

/// Plan and 3D exports behind File > Export. Files are written through NSSavePanel (test mode: `ROOMSMITH_EXPORT_DIR`, no dialog); results go to the status bar.
@MainActor
enum ExportActions {
    static func canExport(_ p: Project) -> Bool {
        !p.walls.isEmpty || !p.rooms.isEmpty || !p.instances.isEmpty
    }

    /// Where to write `name`: the save panel, or under test mode `$ROOMSMITH_EXPORT_DIR/name` (no dialog).
    static func destination(name: String, type: UTType, message: String, model: AppModel) -> URL? {
        if AppDefaults.isTestMode {
            guard let dir = ProcessInfo.processInfo.environment["ROOMSMITH_EXPORT_DIR"], !dir.isEmpty else {
                model.lastError = "Test mode: set ROOMSMITH_EXPORT_DIR to export"
                return nil
            }
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            // The project name is part of `name`: keep path separators and `..` out of the file name.
            let ns = name as NSString
            let safe = sanitize(ns.deletingPathExtension) + (ns.pathExtension.isEmpty ? "" : "." + sanitize(ns.pathExtension))
            return URL(fileURLWithPath: dir).appendingPathComponent(safe)
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = name
        panel.message = message
        guard panel.runModal() == .OK, var url = panel.url else { return nil }
        let ext = (name as NSString).pathExtension
        if url.pathExtension.lowercased() != ext { url.appendPathExtension(ext) }
        return url
    }

    /// Renders the 3D view with the current camera and writes a PNG.
    static func export3DImage(width: Int, height: Int, model: AppModel) {
        guard canExport(model.project) else { return }
        let base = model.fileURL?.deletingPathExtension().lastPathComponent ?? model.project.name
        guard let url = destination(name: "\(base)-3d-\(width)x\(height).png", type: .png, message: "Export the 3D view as an image", model: model) else { return }
        model.statusMessage = "Rendering 3D view…"
        let camera = SceneSnapshot.liveView(for: model)?.renderer.camera.rig.state
        Task { @MainActor in
            do {
                let image = try await SceneSnapshot.render(model: model, camera: camera, size: CGSize(width: width, height: height))
                guard let data = SceneSnapshot.png(from: image) else { throw ExportFailure("PNG encoding failed") }
                try data.write(to: url, options: .atomic)
                model.lastError = nil
                model.statusMessage = "Exported \(url.lastPathComponent) (\(width) × \(height))"
            } catch {
                model.lastError = "3D image export failed: \(userMessage(for: error))"
            }
        }
    }

    static func run(_ format: ExportFormat, model: AppModel) {
        let project = model.project
        guard canExport(project) else { return }
        let options = ExportOptions()
        let name = (model.fileURL?.deletingPathExtension().lastPathComponent ?? project.name) + "." + format.fileExtension
        let message = format.isPlan ? "Export the floor plan" : "Export the 3D model (writes .obj and .mtl)"
        let url: URL
        if AppDefaults.isTestMode {
            // No dialog under test mode: default options, file in $ROOMSMITH_EXPORT_DIR.
            guard let dest = destination(name: name, type: format.contentType, message: message, model: model) else { return }
            url = dest
        } else {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [format.contentType]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = name
            panel.message = message
            let accessory = NSHostingView(rootView: ExportOptionsView(options: options, format: format, levelName: model.activeLevel?.name ?? "—"))
            accessory.frame = NSRect(origin: .zero, size: accessory.fittingSize)
            panel.accessoryView = accessory
            guard panel.runModal() == .OK, var chosen = panel.url else { return }
            if chosen.pathExtension.lowercased() != format.fileExtension { chosen.appendPathExtension(format.fileExtension) }
            url = chosen
        }
        do {
            if format.isPlan {
                let result = try exportPlan(format, project: project, active: model.activeLevel, to: url, options: options)
                guard let result else { model.lastError = nil; model.statusMessage = "Export cancelled"; return }
                if result.jobs.isEmpty {
                    model.lastError = nil
                    model.statusMessage = result.note
                } else {
                    model.lastError = nil
                    model.statusMessage = "Rendering PNG…"
                    let jobs = result.jobs, prefix = result.note
                    Task { @MainActor in
                        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<[String], Error> in
                            var extras: [String] = []
                            for job in jobs {
                                do { extras.append(try job.run()) } catch {
                                    let done = extras.count
                                    let saved = done == 0 ? "" : "Saved \(done) of \(jobs.count), then failed: "
                                    return .failure(ExportFailure(saved + userMessage(for: error)))
                                }
                            }
                            return .success(extras)
                        }.value
                        switch outcome {
                        case .success(let extras):
                            model.lastError = nil
                            model.statusMessage = prefix + extras.joined()
                        case .failure(let error):
                            model.lastError = "Export failed: \(userMessage(for: error))"
                        }
                    }
                }
            } else {
                let note = try exportOBJ(project: project, active: model.activeLevel, to: url, options: options)
                model.lastError = nil
                model.statusMessage = note
            }
        } catch {
            model.lastError = "Export failed: \(userMessage(for: error))"
        }
    }

    // MARK: Plan

    struct ExportFailure: Error, CustomStringConvertible, LocalizedError {
        var description: String
        var errorDescription: String? { description }
        init(_ d: String) { description = d }
    }

    /// One PNG to rasterise and write off the main thread; `run` returns the note to append to the status line.
    struct PNGJob: Sendable {
        let pdf: Data
        let target: URL
        func run() throws -> String {
            let (data, dpi) = try PlanRaster.pngData(fromPDF: pdf, dpi: 300)
            try data.write(to: target, options: .atomic)
            // The pixel cap lowers the resolution of big sheets; say so instead of pretending 300 dpi.
            return dpi < 299.5 ? " [\(target.lastPathComponent): PNG at \(Int(dpi.rounded())) dpi (limited to 100 million pixels)]" : ""
        }
    }

    private static func exportPlan(_ format: ExportFormat, project: Project, active: Level?, to url: URL, options o: ExportOptions) throws -> (note: String, jobs: [PNGJob])? {
        let levels = o.allLevels ? project.levels : (active.map { [$0] } ?? [])
        guard !levels.isEmpty else { throw ExportFailure("there is no level to export") }
        let targets: [(Level, URL)] = levels.map { l in
            levels.count == 1 ? (l, url) : (l, siblingURL(url, suffix: sanitize(l.name)))
        }
        for (_, t) in targets.dropFirst() where FileManager.default.fileExists(atPath: t.path) {
            throw ExportFailure("\(t.lastPathComponent) already exists; choose another file name")
        }
        let unit = project.settings.displayUnit
        func layouts(_ paper: PaperFormat, _ scale: ScaleChoice) -> [PlanLayout] {
            levels.map { PlanExport.layout(project, levelId: $0.id, unit: unit, scale: scale, paper: paper, orientation: o.orientation) }
        }
        var paper = o.paper
        var scale = o.scale
        var plan = layouts(paper, scale)
        if let bad = plan.first(where: { !$0.fits }) {
            // Never shrink silently: the user decides between a bigger sheet, another scale, or a larger custom page.
            let bigger = PlanFit.smallestPaper(fitting: plan.map(\.required), preferred: o.orientation, larger: paper)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "The plan does not fit on \(paper.rawValue) at 1:\(bad.scale)"
            alert.informativeText = "At 1:\(bad.scale) the drawing with margin, legend and scale bar needs \(Int(bad.required.width.rounded())) × \(Int(bad.required.height.rounded())) mm."
            var actions: [String] = []
            if let bigger { alert.addButton(withTitle: "Use \(bigger.rawValue)"); actions.append("paper") }
            if scale != .fit { alert.addButton(withTitle: "Fit to Page"); actions.append("fit") }
            alert.addButton(withTitle: "Export Anyway (larger page)"); actions.append("anyway")
            alert.addButton(withTitle: "Cancel"); actions.append("cancel")
            let idx = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            switch idx >= 0 && idx < actions.count ? actions[idx] : "cancel" {
            case "paper": if let bigger { paper = bigger; plan = layouts(paper, scale) }
            case "fit":
                scale = .fit; plan = layouts(paper, scale)
                if let still = plan.first(where: { !$0.fits }) {
                    let a = NSAlert()
                    a.alertStyle = .warning
                    a.messageText = "The plan does not fit on \(paper.rawValue) even at 1:\(still.scale)"
                    a.informativeText = "At the coarsest scale the drawing needs \(Int(still.required.width.rounded())) × \(Int(still.required.height.rounded())) mm. Choose a larger paper and export again."
                    a.addButton(withTitle: "OK")
                    a.runModal()
                    return nil
                }
            case "anyway": break
            default: return nil
            }
        }
        var notes: [String] = []
        var jobs: [PNGJob] = []
        for ((level, target), layout) in zip(targets, plan) {
            let opts = PlanExport.options(for: layout, paper: paper, levelId: level.id, unit: unit)
            var s = "1:\(layout.scale) on \(layout.fits ? paper.rawValue : "a custom page")"
            switch format {
            case .svg: try Data(PlanExport.svg(project, options: opts).utf8).write(to: target, options: .atomic)
            case .pdf: try PlanExport.pdf(project, options: opts).write(to: target, options: .atomic)
            case .png:
                jobs.append(PNGJob(pdf: PlanExport.pdf(project, options: opts), target: target))
            case .obj: break
            }
            if !layout.fits { s += " (\(Int(layout.required.width.rounded())) × \(Int(layout.required.height.rounded())) mm)" }
            notes.append(s)
        }
        let name = targets.count == 1 ? url.lastPathComponent : "\(targets.count) files like \(url.lastPathComponent)"
        return ("Exported \(name): " + (notes.count == 1 ? notes[0] : notes.joined(separator: "; ")), jobs)
    }

    // MARK: OBJ

    private static func exportOBJ(project: Project, active: Level?, to url: URL, options o: ExportOptions) throws -> String? {
        if !o.allLevels && active == nil { throw ExportFailure("there is no level to export") }
        let result = SceneExport.obj(project, levelId: o.allLevels ? nil : active?.id)
        let base = url.deletingPathExtension().lastPathComponent
        let mtlURL = url.deletingPathExtension().appendingPathExtension("mtl")
        // The generated file references "scene.mtl"; point it at the file written next to it.
        let obj = result.obj.replacingOccurrences(of: "mtllib scene.mtl", with: "mtllib \(base).mtl")
        try Data(obj.utf8).write(to: url, options: .atomic)
        try Data(result.mtl.utf8).write(to: mtlURL, options: .atomic)
        return "Exported \(url.lastPathComponent) and \(mtlURL.lastPathComponent) (Y up, metres)"
    }

    // MARK: Helpers

    private static func siblingURL(_ url: URL, suffix: String) -> URL {
        let ext = url.pathExtension
        return url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-" + suffix)
            .appendingPathExtension(ext)
    }

    private static func sanitize(_ s: String) -> String {
        let t = String(s.map { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" ? $0 : "_" })
            .trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "level" : t
    }
}
