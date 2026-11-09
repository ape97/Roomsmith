import Foundation

// MARK: - export.*

/// Exports the plan (SVG/PDF) and the 3D scene (OBJ + MTL) to files chosen by the agent. Uses the same layout and
/// writer functions as the Export dialog (`PlanExport.layout`, `PlanFit`, `SceneExport`); nothing is re-computed here.
enum ExportTools {
    static let unsupported = "UNSUPPORTED"

    // MARK: Path safety

    /// A validated target. `url` is absolute, standardised, has the expected extension and an existing parent folder.
    struct Target {
        var url: URL
    }

    static func target(_ raw: String, ext allowed: String, project: URL?, field: String = "path") throws -> Target {
        guard !raw.isEmpty, !raw.contains("\0") else { throw ToolError.invalid(field, "must be a non-empty path") }
        guard raw.hasPrefix("/") else { throw ToolError.invalid(field, "must be an absolute path (starting with /)") }
        let url = URL(fileURLWithPath: raw).standardizedFileURL
        guard url.pathExtension.lowercased() == allowed else {
            throw ToolError.invalid(field, "must end in .\(allowed) for this export (got '\(url.pathExtension)')")
        }
        guard !url.lastPathComponent.hasPrefix(".") || url.deletingPathExtension().lastPathComponent.count > 0 else {
            throw ToolError.invalid(field, "needs a file name")
        }
        let parent = url.deletingLastPathComponent()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDir), isDir.boolValue else {
            throw ToolError.invalid(field, "the folder \(parent.path) does not exist; create it first")
        }
        // Compare with symlinks resolved so a link cannot lead into the project package.
        let real = parent.resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent)
        var packages: [String] = []
        if let project { packages.append(project.resolvingSymlinksInPath().path); packages.append(project.standardizedFileURL.path) }
        for pkg in packages where real.path == pkg || real.path.hasPrefix(pkg + "/") {
            throw ToolError.invalid(field, "must not point into the open project package")
        }
        if real.pathComponents.dropLast().contains(where: { $0.lowercased().hasSuffix(".roomsmith") }) {
            throw ToolError.invalid(field, "must not point into a .roomsmith project package")
        }
        return Target(url: real)
    }

    static func requireFree(_ urls: [URL], overwrite: Bool) throws {
        guard !overwrite else { return }
        let taken = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !taken.isEmpty {
            throw AgentError(code: AgentError.invalidArgument,
                             message: "\(taken.map(\.lastPathComponent).joined(separator: ", ")) already exists; pass overwrite: true to replace it",
                             details: .object(["existing": .array(taken.map { .string($0.path) })]))
        }
    }

    // MARK: Plan helpers

    /// Same rule as the Export dialog: `name-<level>.ext` next to the chosen file.
    static func siblingURL(_ url: URL, levelName: String) -> URL {
        let t = String(levelName.map { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" ? $0 : "_" })
            .trimmingCharacters(in: .whitespaces)
        let suffix = t.isEmpty ? "level" : t
        return url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-" + suffix)
            .appendingPathExtension(url.pathExtension)
    }

    static func parseScale(_ a: Args) throws -> ScaleChoice {
        guard let v = a.raw("scale"), !v.isNull else { return .ratio(100) }
        if let n = v.int64Value {
            guard (1...100_000).contains(n) else { throw ToolError.invalid("scale", "ratio must be 1...100000 (50 means 1:50)") }
            return .ratio(Int(n))
        }
        guard var s = v.stringValue?.trimmingCharacters(in: .whitespaces).lowercased() else {
            throw ToolError.invalid("scale", "must be a ratio like 50 (= 1:50), \"1:50\" or \"fit\"")
        }
        if s == "fit" { return .fit }
        if s.hasPrefix("1:") { s.removeFirst(2) }
        guard let n = Int(s), (1...100_000).contains(n) else {
            throw ToolError.invalid("scale", "must be a ratio like 50 (= 1:50), \"1:50\" or \"fit\"")
        }
        return .ratio(n)
    }

    static func parsePaper(_ a: Args) throws -> PaperFormat {
        guard let s = try a.string("paper") else { return .a3 }
        guard let f = PaperFormat.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(s) == .orderedSame }) else {
            throw ToolError.invalid("paper", "must be one of: \(PaperFormat.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return f
    }

    static func parseOrientation(_ a: Args) throws -> PaperOrientation {
        guard let s = try a.string("orientation") else { return .auto }
        switch s.lowercased() {
        case "auto", "automatic": return .auto
        case "landscape": return .landscape
        case "portrait": return .portrait
        default: throw ToolError.invalid("orientation", "must be one of: auto, landscape, portrait")
        }
    }

    /// Throws OUT_OF_RANGE (with a paper suggestion) when a layout does not fit its sheet.
    static func requireFits(_ layouts: [PlanLayout], paper: PaperFormat, orientation: PaperOrientation) throws {
        if let bad = layouts.first(where: { !$0.fits }) {
            let bigger = PlanFit.smallestPaper(fitting: layouts.map(\.required), preferred: orientation, larger: paper)
            var d: [String: JSONValue] = [
                "paper": .string(paper.rawValue), "scale": .int(Int64(bad.scale)),
                "requiredWidthMm": .int(Int64(bad.required.width.rounded(.up))),
                "requiredHeightMm": .int(Int64(bad.required.height.rounded(.up))),
                "sheetWidthMm": .number(bad.sheet.width), "sheetHeightMm": .number(bad.sheet.height),
            ]
            if let bigger { d["suggestedPaper"] = .string(bigger.rawValue) }
            let hint = bigger.map { "Use paper \($0.rawValue)" } ?? "Choose a coarser scale (or \"fit\")"
            throw AgentError(code: AgentError.outOfRange,
                             message: "The plan does not fit on \(paper.rawValue) at 1:\(bad.scale): it needs \(Int(bad.required.width.rounded(.up))) x \(Int(bad.required.height.rounded(.up))) mm. \(hint) or a larger paper; the plan is never shrunk silently.",
                             details: .object(d))
        }
    }

    @MainActor
    private static func requireWrite(_ env: ToolEnv) throws {
        guard env.store.agentWriteEnabled else {
            throw AgentError(code: AgentError.writeLocked, message: "Agent write access is switched off in Roomsmith (Agents panel); exports write files.")
        }
    }

    // MARK: Specs

    @MainActor
    static func specs() -> [ToolSpec] {
        [
            .action("export.plan",
                    "Exports the floor plan as true-to-scale SVG or PDF, laid out exactly like the Export dialog. Needs write access. `path` must be absolute, end in .svg/.pdf, lie in an existing folder outside the project package, and not exist unless overwrite is true. Several levels (allLevels) are written as <name>-<level>.<ext> next to `path`. If the plan does not fit the paper at the scale, the call fails with OUT_OF_RANGE and the needed size; nothing is shrunk silently. For PNG use render.plan_image.",
                    ["format": S.str("File format.", values: ["svg", "pdf"]),
                     "path": S.str("Absolute target file path."),
                     "levelId": S.uuid("Level to export; default the active level."),
                     "allLevels": S.bool("Export every level, one file each."),
                     "paper": S.str("Sheet (default A3).", values: PaperFormat.allCases.map(\.rawValue)),
                     "orientation": S.str("Default auto.", values: ["auto", "landscape", "portrait"]),
                     "scale": .object(["description": "Drawing scale: whole number N for 1:N (default 100), or \"fit\" for the largest scale that fits the paper."]),
                     "overwrite": S.bool("Replace existing files (default false).")],
                    required: ["format", "path"]) { env, a in
                try requireWrite(env)
                let p = env.project
                let formatName = try a.requireString("format").lowercased()
                if formatName == "png" {
                    throw ToolError.invalid("format", "png is not written by export.plan; use render.plan_image (with `path`) for a PNG")
                }
                guard formatName == "svg" || formatName == "pdf" else { throw ToolError.invalid("format", "must be svg or pdf") }
                let base = try target(try a.requireString("path"), ext: formatName, project: env.context.fileURL)
                let overwrite = try a.bool("overwrite") ?? false
                let all = try a.bool("allLevels") ?? false
                if all && a.present("levelId") { throw ToolError.invalid("levelId", "cannot be combined with allLevels") }
                let levels: [Level]
                if all { levels = p.levels } else {
                    let id = try env.level(a, in: p)
                    levels = [p.level(id)!]
                }
                guard !levels.isEmpty else { throw ToolError.invalid(nil, "The project has no level to export") }
                let targets: [(Level, URL)] = levels.map { l in (l, levels.count == 1 ? base.url : siblingURL(base.url, levelName: l.name)) }
                guard Set(targets.map(\.1.path)).count == targets.count else {
                    throw ToolError.invalid("allLevels", "level names give the same file name; rename a level or export them one by one")
                }
                try requireFree(targets.map(\.1), overwrite: overwrite)
                let paper = try parsePaper(a), orientation = try parseOrientation(a), scale = try parseScale(a)
                let unit = p.settings.displayUnit
                let layouts = levels.map { PlanExport.layout(p, levelId: $0.id, unit: unit, scale: scale, paper: paper, orientation: orientation) }
                try requireFits(layouts, paper: paper, orientation: orientation)
                var files: [JSONValue] = []
                for ((level, url), layout) in zip(targets, layouts) {
                    let opts = PlanExport.options(for: layout, paper: paper, levelId: level.id, unit: unit)
                    do {
                        if formatName == "svg" { try Data(PlanExport.svg(p, options: opts).utf8).write(to: url, options: .atomic) }
                        else { try PlanExport.pdf(p, options: opts).write(to: url, options: .atomic) }
                    } catch {
                        throw AgentError(code: AgentError.internal, message: "Could not write \(url.path): \(error.localizedDescription)")
                    }
                    files.append(.object([
                        "path": .string(url.path), "levelId": J.id(level.id), "level": .string(level.name),
                        "scale": .int(Int64(layout.scale)), "paper": .string(paper.rawValue), "landscape": .bool(layout.landscape),
                        "pageWidthMm": .number(layout.sheet.width), "pageHeightMm": .number(layout.sheet.height),
                    ]))
                }
                var o: [String: JSONValue] = ["files": .array(files), "format": .string(formatName)]
                if case .object(let first)? = files.first {
                    for k in ["path", "scale", "pageWidthMm", "pageHeightMm"] { o[k] = first[k] }
                }
                return .object(o)
            },
            .action("export.obj",
                    "Exports the 3D scene as Wavefront OBJ plus a .mtl material file next to it (Y up, metres). Needs write access. `path` must be absolute, end in .obj, lie in an existing folder outside the project package; neither the .obj nor the .mtl may exist unless overwrite is true. Exports the level `levelId` (default the active level) or, with allVisible, every visible level.",
                    ["path": S.str("Absolute target file path ending in .obj."),
                     "levelId": S.uuid("Level to export; default the active level."),
                     "allVisible": S.bool("Export all visible levels instead of one."),
                     "overwrite": S.bool("Replace existing files (default false).")],
                    required: ["path"]) { env, a in
                try requireWrite(env)
                let p = env.project
                let t = try target(try a.requireString("path"), ext: "obj", project: env.context.fileURL)
                let mtlURL = t.url.deletingPathExtension().appendingPathExtension("mtl")
                _ = try target(mtlURL.path, ext: "mtl", project: env.context.fileURL)
                try requireFree([t.url, mtlURL], overwrite: try a.bool("overwrite") ?? false)
                let allVisible = try a.bool("allVisible") ?? false
                if allVisible && a.present("levelId") { throw ToolError.invalid("levelId", "cannot be combined with allVisible") }
                var levelId: UUID?
                if !allVisible { levelId = try env.level(a, in: p) }
                else if !p.levels.contains(where: \.visible) { throw ToolError.invalid("allVisible", "no level is visible") }
                let result = SceneExport.obj(p, levelId: levelId)
                let base = t.url.deletingPathExtension().lastPathComponent
                // The generated file references "scene.mtl"; point it at the file written next to it (as the Export dialog does).
                let obj = result.obj.replacingOccurrences(of: "mtllib scene.mtl", with: "mtllib \(base).mtl")
                do {
                    try Data(obj.utf8).write(to: t.url, options: .atomic)
                    try Data(result.mtl.utf8).write(to: mtlURL, options: .atomic)
                } catch {
                    throw AgentError(code: AgentError.internal, message: "Could not write the export: \(error.localizedDescription)")
                }
                return .object(["path": .string(t.url.path), "mtlPath": .string(mtlURL.path),
                                "levelId": levelId.map(J.id) ?? .null, "allVisible": .bool(allVisible)])
            },
        ]
    }
}
