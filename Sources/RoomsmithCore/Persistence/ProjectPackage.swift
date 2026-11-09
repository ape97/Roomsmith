import CryptoKit
import Foundation

/// A project on disk: the folder `Name.roomsmith/` with `project.md`, `assets/` and `backups/`.
public enum ProjectPackage {
    public static let fileExtension = "roomsmith"
    public static let projectFileName = "project.md"
    public static let maxBackups = 10

    // MARK: Paths

    static func projectFile(_ pkg: URL) -> URL { pkg.appendingPathComponent(projectFileName) }
    static func backupsDir(_ pkg: URL) -> URL { pkg.appendingPathComponent("backups", isDirectory: true) }
    static func assetsDir(_ pkg: URL) -> URL { pkg.appendingPathComponent("assets", isDirectory: true) }

    public static func assetURL(_ a: ProjectAsset, in packageURL: URL) -> URL {
        // storedName comes from a file anyone can edit: never let it leave assets/.
        assetsDir(packageURL).appendingPathComponent((a.storedName as NSString).lastPathComponent)
    }

    /// Backups, newest first.
    public static func listBackups(in packageURL: URL) -> [URL] {
        let dir = backupsDir(packageURL)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix("project-") && $0.hasSuffix(".md") }
            .sorted(by: >)
            .map { dir.appendingPathComponent($0) }
    }

    // MARK: Load

    /// Reads `project.md`. Leftover `project.md.tmp-*` files from an interrupted save are ignored.
    public static func load(from packageURL: URL) throws -> (project: Project, warnings: [String]) {
        let file = projectFile(packageURL)
        let data: Data
        do { data = try Data(contentsOf: file) } catch {
            throw PersistenceError("cannot read project file: \(error.localizedDescription)", path: file.path)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw PersistenceError("project file is not valid UTF-8", path: file.path)
        }
        do {
            let result = try RoomsmithMarkdown.decode(text)
            try checkRanges(result.project)
            return result
        } catch var e as PersistenceError {
            e.path = file.path
            throw e
        }
    }

    /// Rejects values beyond ±`coordinateLimit` (a hand-edited file could carry huge numbers into the wrapping
    /// geometry arithmetic). The message names the object and field.
    static func checkRanges(_ p: Project) throws {
        func bad(_ what: String, _ field: String, _ value: Int64) -> PersistenceError {
            PersistenceError("value out of range in \(what), field '\(field)': \(value) mm (allowed: ±\(coordinateLimit) mm)")
        }
        func mm(_ v: MM, _ what: String, _ field: String) throws {
            if v.magnitude > coordinateLimit.magnitude { throw bad(what, field, v) }
        }
        func p2(_ v: P2, _ what: String, _ field: String) throws {
            try mm(v.x, what, field + ".x"); try mm(v.y, what, field + ".y")
        }
        func p3(_ v: P3, _ what: String, _ field: String) throws {
            try mm(v.x, what, field + ".x"); try mm(v.y, what, field + ".y"); try mm(v.z, what, field + ".z")
        }
        func size(_ v: Size3, _ what: String, _ field: String) throws {
            try mm(v.width, what, field + ".width"); try mm(v.depth, what, field + ".depth"); try mm(v.height, what, field + ".height")
        }
        let revLimit: Int64 = 1_000_000_000_000_000
        func rev(_ v: Int64, _ what: String) throws {
            if !(0...revLimit).contains(v) {
                throw PersistenceError("value out of range in \(what), field 'rev': \(v) (allowed: 0...\(revLimit))")
            }
        }
        if !(0...revLimit).contains(p.revision) {
            throw PersistenceError("value out of range in project, field 'revision': \(p.revision) (allowed: 0...\(revLimit))")
        }
        for x in p.levels { try rev(x.rev, "level \(x.id.uuidString.lowercased())") }
        for x in p.walls { try rev(x.rev, "wall \(x.id.uuidString.lowercased())") }
        for x in p.rooms { try rev(x.rev, "room \(x.id.uuidString.lowercased())") }
        for x in p.openings { try rev(x.rev, "opening \(x.id.uuidString.lowercased())") }
        for x in p.dimensions { try rev(x.rev, "dimension \(x.id.uuidString.lowercased())") }
        for x in p.materials { try rev(x.rev, "material \(x.id.uuidString.lowercased())") }
        for x in p.definitions { try rev(x.rev, "definition \(x.id.uuidString.lowercased())") }
        for x in p.instances { try rev(x.rev, "instance \(x.id.uuidString.lowercased())") }
        for x in p.groups { try rev(x.rev, "group \(x.id.uuidString.lowercased())") }
        for x in p.products { try rev(x.rev, "product \(x.id.uuidString.lowercased())") }
        for x in p.assets { try rev(x.rev, "asset \(x.id.uuidString.lowercased())") }
        for x in p.backgrounds { try rev(x.rev, "background \(x.id.uuidString.lowercased())") }
        for x in p.cameras { try rev(x.rev, "camera \(x.id.uuidString.lowercased())") }
        for l in p.levels {
            let w = "level \(l.id.uuidString.lowercased())"
            try mm(l.elevation, w, "elevation"); try mm(l.height, w, "height")
        }
        for x in p.walls {
            let w = "wall \(x.id.uuidString.lowercased())"
            try p2(x.start, w, "start"); try p2(x.end, w, "end"); try mm(x.thickness, w, "thickness"); try mm(x.height, w, "height")
        }
        for x in p.rooms {
            for (i, pt) in x.points.enumerated() { try p2(pt, "room \(x.id.uuidString.lowercased())", "points[\(i)]") }
        }
        for x in p.openings {
            let w = "opening \(x.id.uuidString.lowercased())"
            try mm(x.offset, w, "offset"); try mm(x.width, w, "width"); try mm(x.height, w, "height"); try mm(x.sill, w, "sill")
        }
        for x in p.dimensions {
            let w = "dimension \(x.id.uuidString.lowercased())"
            try p2(x.a, w, "a"); try p2(x.b, w, "b"); try mm(x.offset, w, "offset")
        }
        for x in p.materials { try mm(x.textureTile, "material \(x.id.uuidString.lowercased())", "textureTile") }
        for x in p.assets { if let s = x.measuredSize { try size(s, "asset \(x.id.uuidString.lowercased())", "measuredSize") } }
        for x in p.backgrounds {
            let w = "background \(x.id.uuidString.lowercased())"
            try p2(x.calibrationA, w, "calibrationA"); try p2(x.calibrationB, w, "calibrationB")
            try mm(x.calibrationLength, w, "calibrationLength"); try p2(x.origin, w, "origin")
        }
        for d in p.definitions {
            let w = "definition \(d.id.uuidString.lowercased())"
            try size(d.size, w, "size")
            func pose(_ q: ComponentPose, _ pw: String) throws {
                if let v = q.position { try p3(v, pw, "position") }
                if let v = q.size { try size(v, pw, "size") }
            }
            for st in d.states {
                let sw = "state \(st.id.uuidString.lowercased()) of \(w)"
                if let v = st.size { try size(v, sw, "size") }
                for (cid, q) in st.poses { try pose(q, "\(sw), pose of component \(cid.uuidString.lowercased())") }
            }
            for tr in d.tracks {
                for (i, kf) in tr.keyframes.enumerated() {
                    for (cid, q) in kf.poses { try pose(q, "track \(tr.id.uuidString.lowercased()) keyframe[\(i)], pose of component \(cid.uuidString.lowercased())") }
                }
            }
            for c in d.components {
                let cw = "component \(c.id.uuidString.lowercased())"
                try p3(c.position, cw, "position"); try size(c.size, cw, "size")
                if let pv = c.pivot { try p3(pv, cw, "pivot") }
            }
        }
        for x in p.instances {
            let w = "instance \(x.id.uuidString.lowercased())"
            try p3(x.position, w, "position")
            if let s = x.size { try size(s, w, "size") }
        }
        for g in p.groups {
            let w = "group \(g.id.uuidString.lowercased())"
            try p3(g.origin, w, "origin")
            for cfg in g.configurations {
                for (mid, mp) in cfg.poses { try p3(mp.local, "configuration \(cfg.id.uuidString.lowercased()) of \(w), member \(mid.uuidString.lowercased())", "local") }
            }
        }
        for x in p.products { if let s = x.dimensions { try size(s, "product \(x.id.uuidString.lowercased())", "dimensions") } }
        try p3(p.camera.target, "camera", "target"); try mm(p.camera.distance, "camera", "distance")
        for x in p.cameras {
            let w = "saved camera \(x.id.uuidString.lowercased())"
            try p3(x.state.target, w, "target"); try mm(x.state.distance, w, "distance")
        }
        try mm(p.settings.snap.grid, "settings", "snap.grid"); try mm(p.settings.snap.tolerance, "settings", "snap.tolerance")
        try mm(p.settings.defaultWallThickness, "settings", "defaultWallThickness")
        try mm(p.settings.defaultWallHeight, "settings", "defaultWallHeight")
    }

    // MARK: Save

    /// Atomic save: write `project.md.tmp-<uuid>`, fsync, copy the old file into `backups/`, then `rename(2)` over
    /// `project.md`. A crash at any point leaves the previous `project.md` intact. Unchanged content is not rewritten.
    public static func save(_ p: Project, to packageURL: URL) throws {
        try save(p, to: packageURL, copyingAssetsFrom: nil, afterTempWrite: nil)
    }

    /// Save As: like `save(_:to:)`, but first copies the project's asset files from the old package (see `copyAssets`),
    /// so meshes, backgrounds and textures survive the move. `oldPackageURL == nil` or the same package copies nothing.
    public static func save(_ p: Project, to packageURL: URL, copyingAssetsFrom oldPackageURL: URL?) throws {
        try save(p, to: packageURL, copyingAssetsFrom: oldPackageURL, afterTempWrite: nil)
    }

    /// Copies every file named by `project.assets[].storedName` (meshes, background images, textures, product files)
    /// from `from/assets/` to `to/assets/`. Files already present in the target are kept, missing sources are skipped,
    /// nothing is ever deleted. Same package: no-op. Returns the stored names that were copied.
    @discardableResult
    public static func copyAssets(from oldPackageURL: URL, to newPackageURL: URL, project: Project) throws -> [String] {
        let fm = FileManager.default
        let src = assetsDir(oldPackageURL), dst = assetsDir(newPackageURL)
        if src.resolvingSymlinksInPath().standardizedFileURL == dst.resolvingSymlinksInPath().standardizedFileURL { return [] }
        var copied: [String] = []
        var seen = Set<String>()
        for a in project.assets {
            let from = assetURL(a, in: oldPackageURL), name = from.lastPathComponent
            guard seen.insert(name).inserted, fm.fileExists(atPath: from.path) else { continue }
            let to = assetURL(a, in: newPackageURL)
            if fm.fileExists(atPath: to.path) { continue }
            do {
                try fm.createDirectory(at: dst, withIntermediateDirectories: true)
                try fm.copyItem(at: from, to: to)
                copied.append(name)
            } catch {
                throw PersistenceError("cannot copy asset \(name): \(error.localizedDescription)", path: to.path)
            }
        }
        return copied
    }

    /// `afterTempWrite` runs after the temp file is on disk and before anything else changes (test hook for failures).
    static func save(_ p: Project, to packageURL: URL, copyingAssetsFrom oldPackageURL: URL? = nil,
                     afterTempWrite: (() throws -> Void)?) throws {
        try store(encoded(p), of: p, to: packageURL, copyingAssetsFrom: oldPackageURL, afterTempWrite: afterTempWrite)
    }

    /// The bytes `save` writes for `p`. Encoding is the cheap, document-bound half; callers that must keep the main
    /// thread free encode there and hand the bytes to `save(encoded:to:)` on a background task.
    public static func encoded(_ p: Project) -> Data { Data(RoomsmithMarkdown.encode(p).utf8) }

    /// Same file operations as `save(_:to:)` (temp file, fsync, backup, rename) for bytes made by `encoded(_:)`. It copies no
    /// assets, so it needs no project.
    public static func save(encoded data: Data, to packageURL: URL) throws {
        try store(data, of: nil, to: packageURL, copyingAssetsFrom: nil, afterTempWrite: nil)
    }

    private static func store(_ data: Data, of p: Project?, to packageURL: URL, copyingAssetsFrom oldPackageURL: URL?,
                              afterTempWrite: (() throws -> Void)?) throws {
        let fm = FileManager.default
        let target = projectFile(packageURL)
        do {
            try fm.createDirectory(at: backupsDir(packageURL), withIntermediateDirectories: true)
            try fm.createDirectory(at: assetsDir(packageURL), withIntermediateDirectories: true)
            if let oldPackageURL, let p { try copyAssets(from: oldPackageURL, to: packageURL, project: p) }
            let old: Data? = fm.fileExists(atPath: target.path) ? try Data(contentsOf: target) : nil
            if old == data { return }

            let tmp = packageURL.appendingPathComponent("\(projectFileName).tmp-\(UUID().uuidString.lowercased())")
            do {
                try writeSynced(data, to: tmp)
                try afterTempWrite?()
                if let old {
                    try old.write(to: nextBackupURL(in: packageURL), options: .atomic)  // never leave a half-written backup
                    pruneBackups(in: packageURL)
                }
                guard rename(tmp.path, target.path) == 0 else {
                    throw PersistenceError("rename failed: \(String(cString: strerror(errno)))", path: target.path)
                }
                syncDirectory(packageURL)
            } catch {
                try? fm.removeItem(at: tmp)
                throw error
            }
        } catch let e as PersistenceError {
            throw e
        } catch {
            throw PersistenceError("cannot save project: \(error.localizedDescription)", path: packageURL.path)
        }
    }

    private static func writeSynced(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else { throw PersistenceError("cannot create temp file: \(String(cString: strerror(errno)))", path: url.path) }
        defer { close(fd) }
        try data.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress! + off, buf.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw PersistenceError("write failed: \(String(cString: strerror(errno)))", path: url.path)
                }
                off += n
            }
        }
        guard fsync(fd) == 0 else { throw PersistenceError("fsync failed: \(String(cString: strerror(errno)))", path: url.path) }
    }

    private static func syncDirectory(_ url: URL) {
        let fd = open(url.path, O_RDONLY)
        if fd >= 0 { _ = fsync(fd); close(fd) }
    }

    /// `backups/project-yyyyMMdd-HHmmss-SSS.md` (UTC); always sorts after every existing backup.
    private static func nextBackupURL(in pkg: URL) -> URL {
        let newest = listBackups(in: pkg).first?.lastPathComponent ?? ""
        var ms = Int64(Date().timeIntervalSince1970 * 1000)
        var name = backupName(ms)
        while name <= newest { ms += 1; name = backupName(ms) }
        return backupsDir(pkg).appendingPathComponent(name)
    }

    private static func backupName(_ ms: Int64) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: Double(ms / 1000)))
        func p(_ v: Int?, _ w: Int) -> String { let s = String(v ?? 0); return String(repeating: "0", count: max(0, w - s.count)) + s }
        return "project-\(p(c.year, 4))\(p(c.month, 2))\(p(c.day, 2))-\(p(c.hour, 2))\(p(c.minute, 2))\(p(c.second, 2))-\(p(Int(ms % 1000), 3)).md"
    }

    private static func pruneBackups(in pkg: URL) {
        for url in listBackups(in: pkg).dropFirst(maxBackups) { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: Assets

    /// Copies `file` to `assets/<first 16 hex of sha256>.<ext>` (once per content) and returns the asset record.
    /// The caller adds it to the project.
    public static func importAsset(_ file: URL, kind: AssetKind, into packageURL: URL) throws -> ProjectAsset {
        let data: Data
        do { data = try Data(contentsOf: file, options: .mappedIfSafe) } catch {
            throw PersistenceError("cannot read asset: \(error.localizedDescription)", path: file.path)
        }
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let ext = file.pathExtension.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let stored = ext.isEmpty ? String(hex.prefix(16)) : "\(hex.prefix(16)).\(ext)"
        let asset = ProjectAsset(kind: kind, storedName: stored, originalName: file.lastPathComponent, sha256: hex, byteCount: Int64(data.count))
        do {
            try FileManager.default.createDirectory(at: assetsDir(packageURL), withIntermediateDirectories: true)
            let dest = assetURL(asset, in: packageURL)
            if !FileManager.default.fileExists(atPath: dest.path) { try data.write(to: dest, options: .atomic) }
        } catch {
            throw PersistenceError("cannot store asset: \(error.localizedDescription)", path: packageURL.path)
        }
        return asset
    }
}
