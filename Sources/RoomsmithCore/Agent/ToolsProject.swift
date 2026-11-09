import Foundation

// MARK: - project.*

enum ProjectTools {
    static func settingsJSON(_ s: ProjectSettings) -> JSONValue {
        .object([
            "displayUnit": .string(s.displayUnit.rawValue),
            "snapEnabled": .bool(s.snap.enabled),
            "snapToWalls": .bool(s.snap.toWalls),
            "snapToObjects": .bool(s.snap.toObjects),
            "snapToGrid": .bool(s.snap.toGrid),
            "gridMm": .int(s.snap.grid),
            "snapToleranceMm": .int(s.snap.tolerance),
            "angleStepDeg": .number(s.snap.angleStep),
            "collisionWarnings": .bool(s.collisionWarnings),
            "defaultWallThicknessMm": .int(s.defaultWallThickness),
            "defaultWallHeightMm": .int(s.defaultWallHeight),
        ])
    }

    /// Bounding box (mm) of walls, rooms and furniture, nil for an empty project.
    static func bounds(_ p: Project) -> JSONValue {
        var pts: [V2] = []
        for w in p.walls { pts.append(w.start.v); pts.append(w.end.v) }
        for r in p.rooms { pts.append(contentsOf: r.points.map(\.v)) }
        for i in p.instances {
            if let d = p.definition(i.definitionId) {
                let b = FurnitureResolver.footprint(of: i, definition: d).bounds
                pts.append(b.min); pts.append(b.max)
            }
        }
        guard let first = pts.first else { return .null }
        var lo = first, hi = first
        for q in pts { lo = V2(min(lo.x, q.x), min(lo.y, q.y)); hi = V2(max(hi.x, q.x), max(hi.y, q.y)) }
        return .object(["min": J.v2(lo), "max": J.v2(hi), "widthMm": J.mm(hi.x - lo.x), "depthMm": J.mm(hi.y - lo.y)])
    }

    /// CONFLICT while the open project has unsaved changes and the caller did not accept losing them.
    @MainActor
    static func requireNoUnsaved(_ env: ToolEnv, discard: Bool, action: String) throws {
        guard env.store.isDirty, !discard else { return }
        throw AgentError(code: AgentError.conflict,
                         message: "The open project has unsaved changes; save it first (project.save or project.save_as) or pass discard: true to drop them before \(action).",
                         details: .object(["dirty": true]))
    }

    /// An existing `.roomsmith` package folder with a `project.md`.
    static func existingPackage(_ raw: String) throws -> URL {
        guard !raw.isEmpty, !raw.contains("\0"), raw.hasPrefix("/") else { throw ToolError.invalid("path", "must be an absolute path (starting with /)") }
        let url = URL(fileURLWithPath: raw).standardizedFileURL
        guard url.pathExtension.lowercased() == ProjectPackage.fileExtension else {
            throw ToolError.invalid("path", "must be a .\(ProjectPackage.fileExtension) package folder")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
              FileManager.default.fileExists(atPath: url.appendingPathComponent("project.md").path) else {
            throw ToolError.notFoundText("No Roomsmith project package at \(url.path)")
        }
        return url
    }

    /// Answer of project.new / project.open: the project that is open now.
    @MainActor
    static func openedJSON(_ env: ToolEnv, warnings: [String]) -> JSONValue {
        let p = env.project
        return .object(["name": .string(p.name), "id": J.id(p.id), "path": env.context.fileURL.map { .string($0.path) } ?? .null,
                        "revision": .int(p.revision), "dirty": .bool(env.store.isDirty),
                        "activeLevelId": J.id(env.context.activeLevelId),
                        "levels": .array(p.levels.map { .object(["id": J.id($0.id), "name": .string($0.name)]) }),
                        "warnings": .array(warnings.map { .string($0) })])
    }

    @MainActor
    static func specs() -> [ToolSpec] {
        [
            .read("project.get_summary", "Overview of the open project: counts per object kind, bounds, levels, settings, camera, revision, undo state.") { env, _ in
                let p = env.project
                let counts: [String: JSONValue] = [
                    "levels": .int(Int64(p.levels.count)), "walls": .int(Int64(p.walls.count)), "rooms": .int(Int64(p.rooms.count)),
                    "openings": .int(Int64(p.openings.count)), "dimensions": .int(Int64(p.dimensions.count)),
                    "furniture": .int(Int64(p.instances.count)), "groups": .int(Int64(p.groups.count)),
                    "materials": .int(Int64(p.materials.count)), "definitions": .int(Int64(p.definitions.count)),
                    "products": .int(Int64(p.products.count)), "savedCameras": .int(Int64(p.cameras.count)),
                ]
                return .object([
                    "name": .string(p.name), "id": J.id(p.id),
                    "path": env.context.fileURL.map { .string($0.path) } ?? .null,
                    "revision": .int(p.revision), "dirty": .bool(env.store.isDirty),
                    "writeEnabled": .bool(env.store.agentWriteEnabled),
                    "counts": .object(counts), "bounds": bounds(p),
                    "levels": .array(p.levels.map {
                        .object(["id": J.id($0.id), "name": .string($0.name), "elevationMm": .int($0.elevation),
                                 "heightMm": .int($0.height), "rev": .int($0.rev)])
                    }),
                    "activeLevelId": J.id(env.context.activeLevelId),
                    "settings": settingsJSON(p.settings),
                    "camera": CameraTools.json(p.camera),
                    "undoName": env.store.undoName.map { .string($0) } ?? .null,
                    "redoName": env.store.redoName.map { .string($0) } ?? .null,
                ])
            },
            .action("project.save", "Saves the open project to its own file. Fails with NO_FILE while the project has never been saved by the user (agents cannot choose a path). Needs write access.") { env, _ in
                guard env.store.agentWriteEnabled else {
                    throw AgentError(code: AgentError.writeLocked, message: "Agent write access is switched off in Roomsmith (Agents panel).")
                }
                let path = try env.context.saveForAgent()
                return .object(["saved": true, "path": .string(path), "revision": .int(env.project.revision), "dirty": .bool(env.store.isDirty)])
            },
            .action("project.new",
                    "Replaces the open project by a new empty one (untitled, default level). Needs write access. Unsaved changes are never dropped silently: while the project is dirty the call fails with CONFLICT unless `discard` is true. Clears the undo history. No dialog is shown.",
                    ["discard": S.bool("Drop unsaved changes of the open project (default false).")]) { env, a in
                try env.requireWriteAccess("project.new replaces the open project")
                try requireNoUnsaved(env, discard: try a.bool("discard") ?? false, action: "creating a new project")
                try env.context.newProjectForAgent()
                return openedJSON(env, warnings: [])
            },
            .action("project.open",
                    "Opens an existing `.roomsmith` project package (absolute path to the folder) in place of the open project. Needs write access. Fails with CONFLICT while the open project has unsaved changes unless `discard` is true. Clears the undo history. No dialog is shown.",
                    ["path": S.str("Absolute path of an existing .roomsmith package folder."),
                     "discard": S.bool("Drop unsaved changes of the open project (default false).")],
                    required: ["path"]) { env, a in
                try env.requireWriteAccess("project.open replaces the open project")
                let url = try existingPackage(try a.requireString("path"))
                try requireNoUnsaved(env, discard: try a.bool("discard") ?? false, action: "opening another project")
                let warnings = try env.context.openProjectForAgent(url)
                return openedJSON(env, warnings: warnings)
            },
            .action("project.save_as",
                    "Saves the open project as a new `.roomsmith` package at `path` and makes that package the project's file (later project.save writes there). Needs write access. `path` must be absolute, end in .roomsmith, lie in an existing folder and not be the open package; an existing package is replaced only with `overwrite`. No dialog is shown.",
                    ["path": S.str("Absolute target path ending in .roomsmith."),
                     "overwrite": S.bool("Replace an existing package at that path (default false).")],
                    required: ["path"]) { env, a in
                try env.requireWriteAccess("project.save_as writes a project package")
                let t = try ExportTools.target(try a.requireString("path"), ext: ProjectPackage.fileExtension, project: env.context.fileURL)
                let fm = FileManager.default
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: t.url.path, isDirectory: &isDir) {
                    guard try a.bool("overwrite") ?? false else {
                        throw AgentError(code: AgentError.invalidArgument,
                                         message: "\(t.url.lastPathComponent) already exists; pass overwrite: true to replace it",
                                         details: .object(["existing": .array([.string(t.url.path)])]))
                    }
                    guard isDir.boolValue, fm.fileExists(atPath: t.url.appendingPathComponent("project.md").path) else {
                        throw ToolError.invalid("path", "exists but is not a Roomsmith project package; it is not overwritten")
                    }
                }
                try env.context.saveProjectAsForAgent(t.url)
                return .object(["saved": true, "path": .string(t.url.path), "revision": .int(env.project.revision),
                                "dirty": .bool(env.store.isDirty)])
            },
            .read("project.get_scene_snapshot",
                  "Compact overview of the whole scene as text (one line per object with full ids) or JSON rows, paginated. Good first call to orient yourself.",
                  ["format": S.str("`text` (default) or `json`.", values: ["text", "json"]),
                   "levelId": S.uuid("Only this level."), "limit": S.limit, "cursor": S.cursor]) { env, a in
                let p = env.project
                let format = try a.string("format") ?? "text"
                guard format == "text" || format == "json" else { throw ToolError.invalid("format", "must be text or json") }
                let level = try a.uuid("levelId")
                if let level, p.level(level) == nil { throw ToolError.notFound("Level", level) }
                let page = try PageRequest(a, defaultLimit: 200)
                let entries = Rows.entries(p, kinds: Rows.snapshotKinds, levelId: level)
                if format == "json" {
                    return page.result(entries, revision: p.revision) { Rows.row(p, $0) }
                }
                let end = min(entries.count, page.offset + page.limit)
                let slice = page.offset < entries.count ? Array(entries[page.offset..<end]) : []
                var lines: [String] = []
                if page.offset == 0 {
                    lines.append("Project \"\(p.name)\" revision \(p.revision); lengths in mm, angles in degrees; ids are full UUIDs.")
                }
                lines.append(contentsOf: slice.map { Rows.line(Rows.row(p, $0)) })
                var o: [String: JSONValue] = ["text": .string(lines.joined(separator: "\n")), "total": .int(Int64(entries.count)),
                                              "revision": .int(p.revision)]
                if end < entries.count { o["nextCursor"] = .string(String(end)) }
                return .object(o)
            },
            .write("project.update_settings",
                   "Changes the project name and settings; only the given keys change. Returns the name and the full settings.",
                   ["name": S.str("Project name."), "snapEnabled": S.bool("Master switch for snapping."),
                    "snapToWalls": S.bool("Snap to walls."), "snapToObjects": S.bool("Snap to other objects."),
                    "snapToGrid": S.bool("Snap to the grid."), "gridMm": S.int("Grid size in mm (1...10000)."),
                    "snapToleranceMm": S.int("Snap distance in mm (0...10000)."),
                    "angleStepDeg": S.num("Rotation snap step in degrees (>0, <=180)."),
                    "collisionWarnings": S.bool("Show collision warnings."),
                    "displayUnit": S.str("Unit shown in the UI.", values: ["mm", "cm", "m"]),
                    "defaultWallThicknessMm": S.int("Thickness of new walls."), "defaultWallHeightMm": S.int("Height of new walls.")]) { p, _, a in
                let keys = ["name", "snapEnabled", "snapToWalls", "snapToObjects", "snapToGrid", "gridMm", "snapToleranceMm", "angleStepDeg",
                            "collisionWarnings", "displayUnit", "defaultWallThicknessMm", "defaultWallHeightMm"]
                guard keys.contains(where: a.has) else {
                    throw ToolError.invalid(nil, "Give at least one setting: \(keys.joined(separator: ", "))")
                }
                let newName = try a.nonEmptyString("name")
                let snapEnabled = try a.bool("snapEnabled"), toWalls = try a.bool("snapToWalls")
                let toObjects = try a.bool("snapToObjects"), toGrid = try a.bool("snapToGrid")
                let grid = try a.mm("gridMm"), tolerance = try a.mm("snapToleranceMm"), step = try a.double("angleStepDeg")
                let warnings = try a.bool("collisionWarnings"), unit = try a.enumValue("displayUnit", LengthUnit.self)
                let thickness = try a.mm("defaultWallThicknessMm"), height = try a.mm("defaultWallHeightMm")
                if let newName { p.name = newName.trimmingCharacters(in: .whitespacesAndNewlines) }
                p.updateSettings { s in
                    if let snapEnabled { s.snap.enabled = snapEnabled }
                    if let toWalls { s.snap.toWalls = toWalls }
                    if let toObjects { s.snap.toObjects = toObjects }
                    if let toGrid { s.snap.toGrid = toGrid }
                    if let grid { s.snap.grid = grid }
                    if let tolerance { s.snap.tolerance = tolerance }
                    if let step { s.snap.angleStep = step }
                    if let warnings { s.collisionWarnings = warnings }
                    if let unit { s.displayUnit = unit }
                    if let thickness { s.defaultWallThickness = thickness }
                    if let height { s.defaultWallHeight = height }
                }
                return .object(["name": .string(p.name), "settings": settingsJSON(p.settings)])
            },
        ]
    }
}

// MARK: - camera.*

enum CameraTools {
    static func json(_ c: CameraState) -> JSONValue {
        .object(["mode": .string(c.mode.rawValue), "target": J.p3(c.target), "distanceMm": .int(c.distance),
                 "yawDeg": .number(c.yawDeg), "pitchDeg": .number(c.pitchDeg), "fovDeg": .number(c.fovDeg)])
    }

    /// Applies the optional camera keys of `a` to `c`.
    static func apply(_ a: Args, to c: inout CameraState) throws {
        if let m = try a.enumValue("mode", CameraModeArg.self) { c.mode = m.mode }
        if let t = try a.p3("target") { c.target = t }
        if let d = try a.mm("distanceMm") { c.distance = d }
        if let y = try a.double("yawDeg") { c.yawDeg = y }
        if let pitch = try a.double("pitchDeg") { c.pitchDeg = pitch }
        if let f = try a.double("fovDeg") { c.fovDeg = f }
    }

    /// Enum wrapper so `Args.enumValue` can parse the model's camera mode.
    enum CameraModeArg: String, CaseIterable {
        case orbit, firstPerson, top, free
        var mode: CameraMode {
            switch self { case .orbit: .orbit; case .firstPerson: .firstPerson; case .top: .top; case .free: .free }
        }
    }

    static let properties: [String: JSONValue] = [
        "mode": S.str("Camera mode.", values: ["orbit", "firstPerson", "top", "free"]),
        "target": S.p3("Orbit: point looked at. First person and free: eye position."),
        "distanceMm": S.int("Orbit distance in mm (10...1000000)."),
        "yawDeg": S.num("Heading in degrees, 0 = north (+Y), counter-clockwise."),
        "pitchDeg": S.num("Pitch in degrees, negative looks down (-90...90)."),
        "fovDeg": S.num("Field of view in degrees (10...120)."),
    ]

    @MainActor
    static func specs() -> [ToolSpec] {
        var setState = ToolSpec.write("camera.set_state",
                                      "Moves the 3D camera (partial update). Not recorded in undo history.", properties) { p, _, a in
            guard CameraTools.properties.keys.contains(where: a.has) else {
                throw ToolError.invalid(nil, "Give at least one camera key: \(CameraTools.properties.keys.sorted().joined(separator: ", "))")
            }
            var c = p.camera
            try CameraTools.apply(a, to: &c)
            p.setCamera(c)
            return .object(["camera": CameraTools.json(c)])
        }
        setState.recordUndo = false
        var applySaved = ToolSpec.write("camera.apply",
                                        "Moves the 3D camera to a saved view (give `id` or `name`). Not recorded in undo history.",
                                        ["id": S.uuid("Saved view id."), "name": S.str("Saved view name (case-insensitive; must be unique).")]) { p, _, a in
            guard a.has("id") != a.has("name") else { throw ToolError.invalid(nil, "Give exactly one of: id, name") }
            let saved: SavedCamera
            if let id = try a.uuid("id") {
                guard let c = p.cameras.first(where: { $0.id == id }) else { throw ToolError.notFound("Saved camera", id) }
                saved = c
            } else {
                let name = try a.requireNonEmptyString("name")
                let hits = p.cameras.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                guard let c = hits.first else { throw ToolError.notFoundText("No saved camera named '\(name)'") }
                guard hits.count == 1 else {
                    throw ToolError.invalid("name", "is ambiguous (\(hits.count) saved cameras); use `id`: \(hits.map { J.id($0.id).stringValue ?? "" }.joined(separator: ", "))")
                }
                saved = c
            }
            p.setCamera(saved.state)
            return .object(["id": J.id(saved.id), "name": .string(saved.name), "camera": CameraTools.json(saved.state)])
        }
        applySaved.recordUndo = false
        return [
            .read("camera.get_state", "Current 3D camera and the saved views.") { env, _ in
                let p = env.project
                return .object([
                    "camera": json(p.camera),
                    "savedCameras": .array(p.cameras.map {
                        .object(["id": J.id($0.id), "name": .string($0.name), "rev": .int($0.rev), "camera": json($0.state)])
                    }),
                    "revision": .int(p.revision),
                ])
            },
            setState,
            .action("camera.preset",
                    "Moves the 3D camera to a preset like the view buttons: `aerial` (default isometric-style overview), `reset` (reset view), `top` (view from above, fitted to the whole content) or `frame` (frame the content, or the objects in `ids`). Needs write access and the Roomsmith window. Stores the camera in the project without an undo step; returns it.",
                    ["preset": S.str("Camera preset.", values: AgentCameraPreset.allCases.map(\.rawValue)),
                     "ids": S.uuids("Only for `frame`: objects to frame (default the whole scene).")],
                    required: ["preset"]) { env, a in
                let bridge = try env.requireBridge("camera.preset")
                try env.requireWriteAccess("camera.preset moves the stored camera")
                guard let preset = try a.enumValue("preset", AgentCameraPreset.self) else { throw ToolError.missing("preset") }
                let ids = try a.uuidList("ids") ?? []
                if !ids.isEmpty {
                    guard preset == .frame else { throw ToolError.invalid("ids", "is only used with preset frame") }
                    try env.project.requireAll(ids)
                }
                let c = try bridge.cameraPreset(preset, ids: ids)
                return .object(["camera": json(c), "preset": .string(preset.rawValue)])
            },
            applySaved,
            .write("camera.save", "Saves the current camera (or the given camera keys on top of it) as a named view.",
                   CameraTools.properties.merging(["name": S.str("Name of the saved view.")]) { a, _ in a }, required: ["name"]) { p, _, a in
                let name = try a.requireNonEmptyString("name")
                var c = p.camera
                try CameraTools.apply(a, to: &c)
                let id = p.saveCamera(name: name, state: c)
                return .object(["id": J.id(id), "camera": json(c)])
            },
        ]
    }
}
