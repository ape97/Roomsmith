import AppKit
import Observation
import RoomsmithCore

/// The global furniture library as the sidebar sees it: entries, search text, pictures. One instance for all projects.
@MainActor @Observable
final class LibraryModel {
    static let shared = LibraryModel()

    private(set) var entries: [LibraryEntry] = []
    /// Categories in display order.
    private(set) var categories: [LibraryCategory] = []
    private var index = LibraryIndex()
    private(set) var warning: String?
    /// The text dialog (new category, rename) or confirmation the sidebar currently shows.
    var dialog: LibraryDialog?
    /// The last failed library action, shown under the sidebar sections.
    var actionError: String?
    /// Counts up whenever a picture arrived; views read it to redraw.
    private(set) var pictureTick = 0
    /// Entries an AI agent added while the app was open; their tiles show a "New" badge until clicked. Runtime only.
    private(set) var newEntries = NewItemTracker()

    let store: LibraryStore
    @ObservationIgnored private var pictures: [String: NSImage] = [:]
    @ObservationIgnored private var requested: Set<String> = []
    /// Keys whose disk cache was already looked at (a miss is remembered, so drawing does not read the disk again).
    @ObservationIgnored private var diskChecked: Set<String> = []
    @ObservationIgnored private var failures: [String: Int] = [:]
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var agentObserver: NSObjectProtocol?
    private static let maxAttempts = 3
    private static let retryDelay: Duration = .seconds(20)

    init(store: LibraryStore = .standard) {
        self.store = store
        reload()
        observer = NotificationCenter.default.addObserver(forName: .roomsmithLibraryChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        agentObserver = NotificationCenter.default.addObserver(forName: .roomsmithLibraryAgentAdded, object: nil, queue: .main) { [weak self] note in
            guard let id = note.object as? UUID else { return }
            MainActor.assumeIsolated { self?.newEntries.noteAdded([id], origin: .agent("library")) }
        }
    }

    func reload() {
        let load = store.load()
        index = load.index
        entries = load.index.entries
        categories = load.index.sortedCategories
        newEntries.prune(existing: Set(entries.map(\.id)))
        warning = load.warning
        // Forget pictures of deleted entries and of older revisions.
        let live = Set(entries.map(pictureKey))
        func keep(_ k: String) -> Bool { k.hasPrefix("standard-") || live.contains(k) }   // same rule as `isLive`
        pictures = pictures.filter { keep($0.key) }
        requested = requested.filter(keep)
        diskChecked = diskChecked.filter(keep)
        failures = failures.filter { keep($0.key) }
    }

    func entry(_ id: UUID) -> LibraryEntry? { entries.first { $0.id == id } }
    func category(_ id: UUID) -> LibraryCategory? { categories.first { $0.id == id } }

    /// Entries shown in a category (nil: Unsorted, which also takes entries whose category no longer exists).
    func entries(in category: UUID?, matching hits: [LibraryEntry]? = nil) -> [LibraryEntry] {
        LibrarySearch.sortedByName((hits ?? entries).filter { index.effectiveCategoryId($0) == category })
    }

    /// The user clicked, previewed or opened the entry: its "New" badge goes away.
    func markSeen(_ id: UUID) { newEntries.markSeen([id]) }

    // MARK: Pictures

    private func pictureKey(_ e: LibraryEntry) -> String { "\(e.id.uuidString)-\(e.rev)" }

    /// Looks the picture up in memory, then (once) on disk. Nil while it still has to be rendered.
    private func cached(_ key: String, disk: () -> Data?) -> NSImage? {
        if let img = pictures[key] { return img }
        guard diskChecked.insert(key).inserted else { return nil }
        if let data = disk(), let img = NSImage(data: data) { pictures[key] = img; return img }
        return nil
    }

    /// Built-in pieces always count; an entry picture only while that entry at that revision is still in the library.
    private func isLive(_ key: String) -> Bool {
        key.hasPrefix("standard-") || entries.contains { pictureKey($0) == key }
    }

    /// Starts one background render unless one runs or the last attempts failed recently. A failed render is retried later.
    private func startRender(_ key: String, render: @escaping () async throws -> Data, store done: @escaping (Data) -> Void) {
        if (failures[key] ?? 0) >= Self.maxAttempts { return }
        guard requested.insert(key).inserted else { return }
        Task { [weak self] in
            do {
                let png = try await render()
                guard let self else { return }
                // The entry may have been deleted or replaced by a newer revision while rendering: then neither keep nor store the picture.
                guard self.isLive(key) else { return }
                done(png)
                self.pictures[key] = NSImage(data: png)
                self.requested.remove(key)
                self.failures[key] = nil
                self.pictureTick += 1
            } catch {
                guard let self, self.isLive(key) else { return }
                self.failures[key, default: 0] += 1
                try? await Task.sleep(for: Self.retryDelay)   // key stays requested meanwhile: no early retry
                self.requested.remove(key)
                self.pictureTick += 1   // redraw: the row asks for the picture again
            }
        }
    }

    /// The picture of an entry; renders it in the background when it is not cached yet.
    func picture(for e: LibraryEntry) -> NSImage? {
        _ = pictureTick
        let key = pictureKey(e)
        if let img = cached(key, disk: { store.thumbnail(e) }) { return img }
        let store = store
        startRender(key, render: {
            let t = try store.transfer(for: e.id)
            return try await LibraryThumbnailer.render(t, size: LibraryStore.thumbnailPixels)
        }, store: { try? store.storeThumbnail($0, for: e) })
        return nil
    }

    /// The picture of a built-in piece.
    func picture(catalogKey key: String) -> NSImage? {
        _ = pictureTick
        let tag = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev"
        let id = "standard-\(key)"
        let store = store
        if let img = cached(id, disk: { store.standardThumbnail(key: key, tag: tag) }) { return img }
        startRender(id, render: { try await LibraryThumbnailer.render(catalogKey: key, size: LibraryStore.thumbnailPixels) },
                    store: { store.storeStandardThumbnail($0, key: key, tag: tag) })
        return nil
    }
}

/// What the sidebar asks the user in a dialog.
enum LibraryDialog: Identifiable, Equatable {
    case newCategory
    case renameCategory(UUID)
    case deleteCategory(UUID)
    case renameEntry(UUID)
    case deleteEntry(UUID)
    var id: String {
        switch self {
        case .newCategory: "new"
        case .renameCategory(let i): "rc-\(i)"
        case .deleteCategory(let i): "dc-\(i)"
        case .renameEntry(let i): "re-\(i)"
        case .deleteEntry(let i): "de-\(i)"
        }
    }
}

// MARK: - Saving into and placing from the library

extension AppModel {
    /// Saves the selected furniture (or groups) as one library entry. Returns false when nothing suitable is selected.
    @discardableResult
    func saveSelectionToLibrary(section: LibrarySection = .own, category: UUID? = nil) -> Bool {
        saveObjectsToLibrary(selectionIds, section: section, category: category)
    }

    /// Saves the given furniture (or groups) as one library entry; other objects among `ids` are ignored.
    @discardableResult
    func saveObjectsToLibrary(_ ids: [UUID], section: LibrarySection = .own, category: UUID? = nil) -> Bool {
        let ids = ids.filter { id in project.instance(id) != nil || project.group(id) != nil }
        guard !ids.isEmpty else { statusMessage = "Select furniture first"; return false }
        return saveToLibrary(section: section, category: category) { try LibraryContent.pack(project: $0, ids: ids, packageURL: self.fileURL) }
    }

    /// Saves one design of this project (without placing it) into the library.
    @discardableResult
    func saveDefinitionToLibrary(_ id: UUID, section: LibrarySection = .own) -> Bool {
        saveToLibrary(section: section) { try LibraryContent.pack(project: $0, definitionId: id, packageURL: self.fileURL) }
    }

    private func saveToLibrary(section: LibrarySection, category: UUID? = nil, pack: (Project) throws -> FurnitureTransfer) -> Bool {
        do {
            let t = try pack(project)
            let entry = try LibraryModel.shared.store.add(LibraryContent.makeEntry(from: t, section: section, categoryId: category), transfer: t)
            lastError = nil
            let where_ = category.flatMap { LibraryModel.shared.category($0)?.name } ?? "My Furniture"
            statusMessage = "Saved \"\(entry.name)\" to \(where_)"
            return true
        } catch {
            lastError = userMessage(for: error)
            return false
        }
    }

    /// Places a library entry on the active level with its middle at `at` (one undo step) and selects it.
    /// The point snaps to the grid like a standard-catalog drop, unless snapping is off or Option is held.
    @discardableResult
    func dropLibrary(_ entryId: UUID, at point: P2) -> Bool {
        guard let level = activeLevel else { return false }
        let at = DropPoint.snapped(point, settings: project.settings.snap, modifierOff: NSEvent.modifierFlags.contains(.option))
        do {
            let ids = try LibraryPlacement.place(entryId, from: LibraryModel.shared.store, into: store, targetPackage: fileURL,
                                                 levelId: level.id, at: at,
                                                 restOnFurniture: !NSEvent.modifierFlags.contains(.option))
            selection = Set(ids)
            lastError = nil
            return true
        } catch {
            lastError = userMessage(for: error)
            NSSound.beep()
            return false
        }
    }

    /// The library entry id carried by a drag pasteboard string, if it is a library token.
    static func libraryEntryId(_ text: String?) -> UUID? { text.flatMap(LibraryDragToken.init(payload:))?.entryId }
}

// MARK: - Library actions used by the sidebar

extension LibraryModel {
    /// Runs a store change; a failure is reported in `actionError` and returns false.
    @discardableResult
    private func perform(_ work: () throws -> Void) -> Bool {
        do { try work(); actionError = nil; reload(); return true }
        catch { actionError = userMessage(for: error); NSSound.beep(); return false }
    }

    @discardableResult func createCategory(_ name: String) -> Bool { perform { _ = try store.createCategory(name: name) } }
    @discardableResult func renameCategory(_ id: UUID, to name: String) -> Bool { perform { _ = try store.renameCategory(id, to: name) } }
    @discardableResult func moveCategory(_ id: UUID, by delta: Int) -> Bool { perform { try store.moveCategory(id, by: delta) } }
    @discardableResult func deleteCategory(_ id: UUID, moveTo: UUID?) -> Bool { perform { try store.deleteCategory(id, moveTo: moveTo) } }
    @discardableResult func move(_ entry: UUID, toCategory c: UUID?) -> Bool { perform { _ = try store.move(entry, toCategory: c) } }
    @discardableResult func rename(_ entry: UUID, to name: String) -> Bool {
        perform {
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !n.isEmpty else { throw LibraryError.invalid("Name must not be empty") }
            _ = try store.update(entry) { $0.name = n }
        }
    }
    @discardableResult func duplicate(_ entry: UUID) -> Bool { perform { _ = try store.duplicate(entry) } }
    @discardableResult func delete(_ entry: UUID) -> Bool { perform { try store.remove(entry) } }

    /// Copies a built-in piece into My furniture so it can be edited.
    @discardableResult
    func copyStandard(key: String, category: UUID?) -> Bool {
        perform {
            let t = try LibraryContent.transfer(fromCatalog: key)
            _ = try store.add(LibraryContent.makeEntry(from: t, categoryId: category), transfer: t)
        }
    }
}
