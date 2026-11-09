import CryptoKit
import Foundation

public extension Notification.Name {
    /// Posted on the main thread after the library changed on disk through this process (UI refreshes its list).
    static let roomsmithLibraryChanged = Notification.Name("roomsmith.library.changed")
    /// Posted on the main thread when an AI agent added a library entry; `object` is the entry's `UUID` (UI shows a "New" badge).
    static let roomsmithLibraryAgentAdded = Notification.Name("roomsmith.library.agentAdded")
}

public enum LibraryError: Error, Equatable, CustomStringConvertible {
    case notFound(UUID)
    case invalid(String)
    case io(String)
    public var description: String {
        switch self {
        case .notFound(let id): "No library entry \(id.uuidString.lowercased())"
        case .invalid(let m), .io(let m): m
        }
    }
}

/// Result of loading the index: a damaged file is moved aside and an empty index is used.
public struct LibraryLoad: Sendable {
    public var index: LibraryIndex
    /// Set when the index file was unreadable; names the backup copy.
    public var warning: String?
}

/// The global furniture library on disk: `library.json` (index), `entries/<id>.json` (furniture), `assets/<hash>.<ext>`
/// (photos), `thumbs/<id>-<rev>.png`. Not part of any project. The root is a parameter, so tests use a temp folder.
public struct LibraryStore: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }

    /// `<support directory>/Library` (honours `ROOMSMITH_SUPPORT_DIR`).
    public static var defaultRoot: URL { AgentPaths.supportDirectory.appendingPathComponent("Library", isDirectory: true) }
    public static var standard: LibraryStore { LibraryStore(root: defaultRoot) }

    var indexURL: URL { root.appendingPathComponent("library.json") }
    func transferURL(_ e: LibraryEntry) -> URL { root.appendingPathComponent(e.transferFile) }
    var assetsDir: URL { root.appendingPathComponent("assets", isDirectory: true) }
    var thumbsDir: URL { root.appendingPathComponent("thumbs", isDirectory: true) }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: Index

    /// Reads the index for display. A missing file is an empty library; a file with damaged single items keeps the readable ones, is
    /// copied to `library.json.broken-<n>` and reports a warning; a wholly damaged or too new one is renamed to
    /// `library.json.broken-<n>`. When the file exists but cannot be read (or moved aside) nothing is touched: the result is an
    /// empty index plus a warning, and every writing operation fails with `LibraryError.io` instead of overwriting the file.
    public func load() -> LibraryLoad {
        do { return try readIndex() } catch {
            return LibraryLoad(index: LibraryIndex(), warning: "The library index cannot be read: \(error)")
        }
    }

    /// Like `load()`, but throws when the index exists and could not be read or kept; writers use it so they never replace
    /// an unreadable index with an empty one.
    func readIndex() throws -> LibraryLoad {
        let data: Data
        do { data = try Data(contentsOf: indexURL) } catch let e as CocoaError where e.code == .fileReadNoSuchFile || e.code == .fileNoSuchFile {
            return LibraryLoad(index: LibraryIndex(), warning: nil)
        } catch {
            throw LibraryError.io("The library index exists but cannot be read (\(error.localizedDescription)); nothing was changed")
        }
        do {
            let idx = try Self.decoder().decode(LibraryIndex.self, from: data)
            guard idx.version <= LibraryIndex.currentVersion else {
                return try backUp(reason: "was written by a newer Roomsmith (format \(idx.version))")
            }
            let skipped = Self.skippedCount(in: data, kept: idx)
            guard skipped > 0 else { return LibraryLoad(index: idx, warning: nil) }
            // Damaged single entries or categories are left out of the result, and the next `save` would drop their metadata
            // for good. So the raw file is COPIED aside first (the index itself stays where it is).
            let kept = try keepCopy(of: data)
            return LibraryLoad(index: idx, warning: "\(skipped) damaged library item(s) could not be read and are not shown; the original index was kept as \(kept.lastPathComponent).")
        } catch let e as LibraryError {
            throw e
        } catch {
            return try backUp(reason: "could not be read")
        }
    }

    /// How many entries and categories the file lists that did not survive decoding.
    private static func skippedCount(in data: Data, kept idx: LibraryIndex) -> Int {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return 0 }
        let listed = (obj["entries"] as? [Any])?.count ?? 0
        let listedCategories = (obj["categories"] as? [Any])?.count ?? 0
        // A categories value of the wrong type (neither a list nor null) is dropped as a whole by the decoder.
        let wrongType = obj["categories"].map { !($0 is [Any]) && !($0 is NSNull) } ?? false
        return max(0, listed - idx.entries.count) + max(0, listedCategories - idx.categories.count) + (wrongType ? 1 : 0)
    }

    /// Copies the raw index to `library.json.broken-<n>` (an identical earlier copy is reused, so repeated loads of the same
    /// damaged file do not pile up copies). Throws when the copy cannot be made: nothing may be dropped without a copy.
    private func keepCopy(of data: Data) throws -> URL {
        let fm = FileManager.default
        var n = 1
        var dest = root.appendingPathComponent("library.json.broken-\(n)")
        while fm.fileExists(atPath: dest.path) {
            if let existing = try? Data(contentsOf: dest), existing == data { return dest }
            n += 1; dest = root.appendingPathComponent("library.json.broken-\(n)")
        }
        do { try data.write(to: dest, options: .atomic) } catch {
            throw LibraryError.io("The library index has damaged items and could not be copied aside (\(error.localizedDescription)); nothing was changed")
        }
        return dest
    }

    private func backUp(reason: String) throws -> LibraryLoad {
        let fm = FileManager.default
        var n = 1
        var dest = root.appendingPathComponent("library.json.broken-\(n)")
        while fm.fileExists(atPath: dest.path) { n += 1; dest = root.appendingPathComponent("library.json.broken-\(n)") }
        do { try fm.moveItem(at: indexURL, to: dest) } catch {
            throw LibraryError.io("The library index \(reason) and could not be kept aside (\(error.localizedDescription)); nothing was changed")
        }
        return LibraryLoad(index: LibraryIndex(), warning: "The library index \(reason); it was kept as \(dest.lastPathComponent) and an empty library is used.")
    }

    /// Photo file names are `<hex hash>.<extension>`; anything else (path parts, hidden files) is never read, written or deleted.
    public static func isSafeAssetName(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
        let hex = Set("0123456789abcdef"), ext = Set("abcdefghijklmnopqrstuvwxyz0123456789")
        return parts[0].allSatisfy(hex.contains) && parts[1].allSatisfy(ext.contains)
    }

    private static func sanitized(_ e: LibraryEntry) -> LibraryEntry {
        var c = e
        c.photoAssetNames = e.photoAssetNames.filter(isSafeAssetName)
        return c
    }

    /// Writes the index atomically (temporary file, then rename).
    public func save(_ index: LibraryIndex) throws {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Self.encoder().encode(index).write(to: indexURL, options: .atomic)
        } catch { throw LibraryError.io("Could not write the library: \(error.localizedDescription)") }
    }

    /// Runs `body` while holding an exclusive `flock` on `library.json.lock` in the library folder, so two processes (or two
    /// stores) never interleave a read-modify-write of the index. The lock is not re-entrant: `body` must not call another
    /// locking method. Notifications are posted by the callers after the lock is released.
    private func locked<T>(_ body: () throws -> T) throws -> T {
        let fd: Int32
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            fd = open(root.appendingPathComponent("library.json.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        } catch { throw LibraryError.io("Could not lock the library: \(error.localizedDescription)") }
        guard fd >= 0 else { throw LibraryError.io("Could not lock the library: \(String(cString: strerror(errno)))") }
        defer { flock(fd, LOCK_UN); close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw LibraryError.io("Could not lock the library: \(String(cString: strerror(errno)))")
        }
        return try body()
    }

    private func changed() {
        if Thread.isMainThread { NotificationCenter.default.post(name: .roomsmithLibraryChanged, object: nil) }
        else { DispatchQueue.main.async { NotificationCenter.default.post(name: .roomsmithLibraryChanged, object: nil) } }
    }

    // MARK: Entries

    public func entries() -> [LibraryEntry] { load().index.entries }
    public func entry(_ id: UUID) -> LibraryEntry? { entries().first { $0.id == id } }

    public func search(query: String = "", section: LibrarySection? = nil, status: PurchaseStatus? = nil,
                       category: LibrarySearch.CategoryFilter = .any) -> [LibraryEntry] {
        let idx = load().index
        return LibrarySearch.filter(idx.entries, query: query, section: section, status: status, categories: idx.categories, category: category)
    }

    // MARK: Categories

    /// Categories in display order.
    public func categories() -> [LibraryCategory] { load().index.sortedCategories }

    /// A category name is trimmed, not empty and unique (ignoring case) among the other categories.
    private static func validName(_ raw: String, in categories: [LibraryCategory], excluding: UUID? = nil) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw LibraryError.invalid("A category name must not be empty") }
        if categories.contains(where: { $0.id != excluding && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw LibraryError.invalid("A category named \"\(name)\" exists already")
        }
        return name
    }

    /// Adds a category at the end of the list.
    @discardableResult
    public func createCategory(name: String) throws -> LibraryCategory {
        let c: LibraryCategory = try locked {
            var idx = try readIndex().index
            let clean = try Self.validName(name, in: idx.categories)
            let c = LibraryCategory(name: clean, order: (idx.categories.map(\.order).max() ?? -1) + 1)
            idx.categories.append(c)
            try save(idx)
            return c
        }
        changed()
        return c
    }

    @discardableResult
    public func renameCategory(_ id: UUID, to name: String) throws -> LibraryCategory {
        let renamed: LibraryCategory = try locked {
            var idx = try readIndex().index
            guard let i = idx.categories.firstIndex(where: { $0.id == id }) else { throw LibraryError.notFound(id) }
            idx.categories[i].name = try Self.validName(name, in: idx.categories, excluding: id)
            try save(idx)
            return idx.categories[i]
        }
        changed()
        return renamed
    }

    /// Sets the display order. `ids` must list every category exactly once.
    @discardableResult
    public func reorderCategories(_ ids: [UUID]) throws -> [LibraryCategory] {
        let sorted: [LibraryCategory] = try locked {
            var idx = try readIndex().index
            guard ids.count == idx.categories.count, Set(ids) == Set(idx.categories.map(\.id)) else {
                throw LibraryError.invalid("The order must list every category exactly once")
            }
            for (n, id) in ids.enumerated() { if let i = idx.categories.firstIndex(where: { $0.id == id }) { idx.categories[i].order = n } }
            try save(idx)
            return idx.sortedCategories
        }
        changed()
        return sorted
    }

    /// Moves a category one place up or down (no-op at the ends).
    @discardableResult
    public func moveCategory(_ id: UUID, by delta: Int) throws -> [LibraryCategory] {
        var ids = categories().map(\.id)
        guard let i = ids.firstIndex(of: id) else { throw LibraryError.notFound(id) }
        let j = i + delta
        guard ids.indices.contains(j) else { return categories() }
        ids.swapAt(i, j)
        return try reorderCategories(ids)
    }

    /// Deletes a category. Its entries go to `moveTo`, or to "Unsorted" when that is nil. `moveTo` must be another, existing category.
    public func deleteCategory(_ id: UUID, moveTo: UUID? = nil) throws {
        try locked {
            var idx = try readIndex().index
            guard idx.categories.contains(where: { $0.id == id }) else { throw LibraryError.notFound(id) }
            if let moveTo, moveTo == id || !idx.categories.contains(where: { $0.id == moveTo }) {
                throw LibraryError.invalid("moveTo must be another existing category")
            }
            idx.categories.removeAll { $0.id == id }
            for (n, c) in idx.sortedCategories.enumerated() { if let i = idx.categories.firstIndex(where: { $0.id == c.id }) { idx.categories[i].order = n } }
            for i in idx.entries.indices where idx.entries[i].categoryId == id { idx.entries[i].categoryId = moveTo }
            try save(idx)
        }
        changed()
    }

    /// Puts an entry into a category (nil: "Unsorted"). The category must exist.
    @discardableResult
    public func move(_ id: UUID, toCategory categoryId: UUID?) throws -> LibraryEntry {
        try update(id) { $0.categoryId = categoryId }
    }

    private static func checkCategory(_ id: UUID?, in idx: LibraryIndex) throws {
        if let id, !idx.categories.contains(where: { $0.id == id }) { throw LibraryError.invalid("Unknown category \(id.uuidString.lowercased())") }
    }

    /// Copies an entry as "<name> 2" (or the next free number): new id, rev 1, the same category, its own copy of the
    /// furniture file and of the current thumbnail. Photo files are shared (they are reference counted by name).
    @discardableResult
    public func duplicate(_ id: UUID) throws -> LibraryEntry {
        let (copy, src): (LibraryEntry, LibraryEntry) = try locked {
            var idx = try readIndex().index
            guard let src = idx.entries.first(where: { $0.id == id }) else { throw LibraryError.notFound(id) }
            var copy = src
            copy.id = UUID(); copy.rev = 1; copy.createdAt = Date()
            // "Shelf" -> "Shelf 2"; "Shelf 3" -> the next free "Shelf 4" (the trailing number is part of the name).
            var base = src.name
            var n = 2
            if let r = base.range(of: #" \d{1,2}$"#, options: .regularExpression), let k = Int(base[r].trimmingCharacters(in: .whitespaces)) {
                base = String(base[..<r.lowerBound]); n = k + 1
            }
            let taken = Set(idx.entries.map { $0.name.lowercased() })
            while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
            copy.name = "\(base) \(n)"
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: transferURL(copy).deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: transferURL(src), to: transferURL(copy))
            } catch { throw LibraryError.io("Could not copy the furniture: \(error.localizedDescription)") }
            idx.entries.append(copy)
            do { try save(idx) } catch { try? fm.removeItem(at: transferURL(copy)); throw error }
            return (copy, src)
        }
        if let png = thumbnail(src) { try? storeThumbnail(png, for: copy) }
        changed()
        return copy
    }

    /// Stores a new entry with its furniture. The entry id is kept; `rev` starts at 1.
    @discardableResult
    public func add(_ entry: LibraryEntry, transfer: FurnitureTransfer) throws -> LibraryEntry {
        guard !transfer.isEmpty else { throw LibraryError.invalid("Nothing to save: the furniture is empty") }
        var e = Self.sanitized(entry)
        e.rev = max(e.rev, 1)
        try locked {
            var idx = try readIndex().index
            guard !idx.entries.contains(where: { $0.id == e.id }) else { throw LibraryError.invalid("Entry \(e.id.uuidString.lowercased()) exists already") }
            try Self.checkCategory(e.categoryId, in: idx)
            try writeTransfer(transfer, for: e)
            idx.entries.append(e)
            do { try save(idx) } catch { try? FileManager.default.removeItem(at: transferURL(e)); throw error }
        }
        changed()
        return e
    }

    /// Changes the metadata of an entry (not the furniture; `rev` stays).
    @discardableResult
    public func update(_ id: UUID, _ edit: (inout LibraryEntry) throws -> Void) throws -> LibraryEntry {
        let e: LibraryEntry = try locked {
            var idx = try readIndex().index
            guard let i = idx.entries.firstIndex(where: { $0.id == id }) else { throw LibraryError.notFound(id) }
            var e = idx.entries[i]
            try edit(&e)
            e = Self.sanitized(e)
            e.id = id
            // A category that is set must exist; an old dangling id on an unrelated edit is left alone.
            if e.categoryId != idx.entries[i].categoryId { try Self.checkCategory(e.categoryId, in: idx) }
            idx.entries[i] = e
            try save(idx)
            return e
        }
        changed()
        return e
    }

    /// Used by `library.update` (`fromObjectId`) and the detail view ("Update from selection").
    /// Replaces the stored furniture of an entry and counts `rev` up (the cached thumbnail becomes stale).
    /// `spec` is the builder recipe of the new furniture; nil drops the old recipe (it described the replaced piece).
    @discardableResult
    public func replaceTransfer(_ id: UUID, with transfer: FurnitureTransfer, spec: ParametricSpec? = nil) throws -> LibraryEntry {
        guard !transfer.isEmpty else { throw LibraryError.invalid("Nothing to save: the furniture is empty") }
        let e: LibraryEntry = try locked {
            var idx = try readIndex().index
            guard let i = idx.entries.firstIndex(where: { $0.id == id }) else { throw LibraryError.notFound(id) }
            var e = idx.entries[i]
            // The old furniture comes back when the index cannot be written, so file and index never disagree.
            let oldFurniture = try? Data(contentsOf: transferURL(e))
            try writeTransfer(transfer, for: e)
            let sum = LibraryContent.summary(of: transfer)
            e.size = sum.size; e.materialNames = sum.materialNames; e.definitionId = sum.definitionId
            e.spec = spec
            e.rev += 1
            idx.entries[i] = e
            do { try save(idx) } catch {
                if let oldFurniture { try? oldFurniture.write(to: transferURL(e), options: .atomic) }
                else { try? FileManager.default.removeItem(at: transferURL(e)) }
                throw error
            }
            return e
        }
        changed()
        return e
    }

    /// Removes the entry, its furniture file, its thumbnails and photos no other entry uses.
    public func remove(_ id: UUID) throws {
        try locked {
            var idx = try readIndex().index
            guard let i = idx.entries.firstIndex(where: { $0.id == id }) else { throw LibraryError.notFound(id) }
            let e = idx.entries.remove(at: i)
            try save(idx)
            let fm = FileManager.default
            try? fm.removeItem(at: transferURL(e))
            for url in thumbnailFiles(for: id) { try? fm.removeItem(at: url) }
            let stillUsed = Set(idx.entries.flatMap(\.photoAssetNames))
            for name in e.photoAssetNames where Self.isSafeAssetName(name) && !stillUsed.contains(name) { try? fm.removeItem(at: assetsDir.appendingPathComponent(name)) }
        }
        changed()
    }

    // MARK: Furniture

    private func writeTransfer(_ t: FurnitureTransfer, for e: LibraryEntry) throws {
        do {
            try FileManager.default.createDirectory(at: transferURL(e).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder().encode(t).write(to: transferURL(e), options: .atomic)
        } catch { throw LibraryError.io("Could not write the furniture: \(error.localizedDescription)") }
    }

    /// The stored furniture of an entry.
    public func transfer(for id: UUID) throws -> FurnitureTransfer {
        guard let e = entry(id) else { throw LibraryError.notFound(id) }
        do { return try Self.decoder().decode(FurnitureTransfer.self, from: Data(contentsOf: transferURL(e))) }
        catch { throw LibraryError.io("The furniture of \"\(e.name)\" cannot be read: \(error.localizedDescription)") }
    }

    // MARK: Photos

    /// Not used by the app yet: the photo-to-furniture package (P5) stores reference photos through it.
    /// Stores photo bytes under their content hash (equal bytes share one file) and returns the file name.
    public func storeAsset(_ data: Data, ext: String) throws -> String {
        let clean = String(ext.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(8))
        guard !clean.isEmpty else { throw LibraryError.invalid("A file extension is required") }
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let name = "\(hex).\(clean)"
        let url = assetsDir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch { throw LibraryError.io("Could not store the file: \(error.localizedDescription)") }
        }
        return name
    }

    public func assetURL(_ name: String) -> URL? {
        guard Self.isSafeAssetName(name) else { return nil }
        let url = assetsDir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Thumbnails

    public func thumbnailURL(_ e: LibraryEntry) -> URL {
        thumbsDir.appendingPathComponent("\(e.id.uuidString.lowercased())-\(e.rev).png")
    }

    private func thumbnailFiles(for id: UUID) -> [URL] {
        let prefix = id.uuidString.lowercased() + "-"
        let list = (try? FileManager.default.contentsOfDirectory(at: thumbsDir, includingPropertiesForKeys: nil)) ?? []
        return list.filter { $0.lastPathComponent.hasPrefix(prefix) }
    }

    /// Cached thumbnail of the current `rev`, nil when none was rendered yet.
    public func thumbnail(_ e: LibraryEntry) -> Data? { try? Data(contentsOf: thumbnailURL(e)) }

    /// Pixel size of cached thumbnails (the cache keeps this one size).
    public static let thumbnailPixels = 384

    /// Stores a thumbnail for the entry's current `rev` and drops older ones.
    public func storeThumbnail(_ png: Data, for e: LibraryEntry) throws {
        do {
            try FileManager.default.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
            // Only older revisions go; a newer picture (a racing render of a later rev) stays.
            let prefix = e.id.uuidString.lowercased() + "-"
            for old in thumbnailFiles(for: e.id) {
                let tail = old.deletingPathExtension().lastPathComponent.dropFirst(prefix.count)
                if let r = Int64(tail), r < e.rev { try? FileManager.default.removeItem(at: old) }
            }
            try png.write(to: thumbnailURL(e), options: .atomic)
        } catch { throw LibraryError.io("Could not store the thumbnail: \(error.localizedDescription)") }
    }

    // MARK: Thumbnails of the built-in catalog (Standard section)

    /// Cached picture of a built-in piece; `tag` (the app version) retires pictures of older designs.
    public func standardThumbnailURL(key: String, tag: String) -> URL {
        let safe = String((key + "-" + tag).map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
        return thumbsDir.appendingPathComponent("standard-\(safe).png")
    }

    public func standardThumbnail(key: String, tag: String) -> Data? { try? Data(contentsOf: standardThumbnailURL(key: key, tag: tag)) }

    public func storeStandardThumbnail(_ png: Data, key: String, tag: String) {
        try? FileManager.default.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
        try? png.write(to: standardThumbnailURL(key: key, tag: tag), options: .atomic)
    }
}
