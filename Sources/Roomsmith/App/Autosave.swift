import AppKit
import Foundation
import RoomsmithCore

/// Crash protection: while a project has unsaved changes, a recovery copy is written every `interval` seconds to its
/// own folder `Application Support/Roomsmith/Autosave/<model id>/Recovery.roomsmith` (never into the user's own
/// file). Every open project (tab) has its own folder, so one tab saving or closing never removes another tab's copy.
/// A normal save, "Don't Save", closing the tab or a clean quit removes the project's own copy; on the next launch
/// every copy left behind is offered for restore.
@MainActor
final class Autosave {
    static let interval: TimeInterval = 30

    private weak var model: AppModel?
    private var timer: Timer?
    private var lastWrittenRevision: Int64?
    /// The running background write. At most one at a time (so copies are never written twice in parallel and the
    /// order is kept); a tick that finds one running does nothing, the next tick picks up newer changes.
    private var writing: Task<Void, Never>?
    /// Bumped by `discard()`: a write that finishes after it cleans up after itself instead of resurrecting the copy.
    private var generation = 0

    init(model: AppModel) { self.model = model }

    static var root: URL { AgentPaths.supportDirectory.appendingPathComponent("Autosave", isDirectory: true) }
    /// Folder of one project's copy.
    static func folder(for modelId: UUID) -> URL { root.appendingPathComponent(modelId.uuidString, isDirectory: true) }
    private var directory: URL { Self.folder(for: model?.id ?? UUID()) }
    private var recoveryURL: URL { directory.appendingPathComponent("Recovery.\(ProjectPackage.fileExtension)") }
    private var infoURL: URL { directory.appendingPathComponent("recovery.json") }

    struct Info: Codable { var originalPath: String?; var revision: Int64; var date: Date }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// Writes the recovery copy if the project is dirty and changed since the last copy.
    func tick() {
        guard let model else { return }
        // Only remove a copy this instance wrote: a copy left by a crash (not offered on this launch) or by another
        // instance with the same support folder must survive until a human decides.
        guard model.store.isDirty else { if lastWrittenRevision != nil { discard() }; return }
        guard writing == nil else { return }
        let rev = model.store.contentRevision
        guard rev != lastWrittenRevision else { return }
        // Encoding stays on the main actor (it reads the live document); the file work (temp file, fsync, backup,
        // rename) runs in the background.
        let data = ProjectPackage.encoded(model.project)
        let info = Info(originalPath: model.fileURL?.path, revision: rev, date: Date())
        let dir = directory, package = recoveryURL, infoFile = infoURL
        let gen = generation
        // Strong self on purpose: the task is finite and must always reach `finishWrite`, or a discard that ran
        // meanwhile (tab closed) could not clean up the copy this write created.
        writing = Task {
            let failure: String? = await Task.detached(priority: .utility) {
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])
                    try ProjectPackage.save(encoded: data, to: package)
                    try JSONEncoder().encode(info).write(to: infoFile, options: .atomic)
                    return nil
                } catch {
                    return userMessage(for: error)
                }
            }.value
            self.finishWrite(revision: rev, generation: gen, failure: failure, directory: dir)
        }
    }

    private func finishWrite(revision: Int64, generation gen: Int, failure: String?, directory dir: URL) {
        writing = nil
        guard gen == generation else {
            // `discard()` ran while this write was in flight: the copy it just wrote must not outlive it.
            try? FileManager.default.removeItem(at: dir)
            return
        }
        if let failure { model?.lastError = "Autosave failed: \(failure)"; return }
        lastWrittenRevision = revision
    }

    /// Removes this project's own recovery copy (after a save, discard, closing the tab or a clean quit).
    func discard() {
        lastWrittenRevision = nil
        generation &+= 1
        guard model != nil else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.path) { try? fm.removeItem(at: directory) }
    }

    // MARK: Recovery at launch

    /// A recovery copy left behind by an earlier run.
    struct Leftover: Identifiable {
        let folder: URL
        let info: Info
        var id: URL { folder }
        var package: URL { folder.appendingPathComponent("Recovery.\(ProjectPackage.fileExtension)") }
        var name: String { info.originalPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "an untitled project" }
    }

    /// Every copy on disk, oldest first. Includes the single copy older versions kept directly in `Autosave/`.
    static func leftovers() -> [Leftover] {
        let fm = FileManager.default
        var folders = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        folders.append(root)  // legacy location
        let found: [Leftover] = folders.compactMap { folder in
            let info = folder.appendingPathComponent("recovery.json")
            let pkg = folder.appendingPathComponent("Recovery.\(ProjectPackage.fileExtension)")
            guard let data = try? Data(contentsOf: info), let decoded = try? JSONDecoder().decode(Info.self, from: data),
                  fm.fileExists(atPath: pkg.path) else { return nil }
            return Leftover(folder: folder, info: decoded)
        }
        return found.sorted { $0.info.date < $1.info.date }
    }

    /// Removes one leftover copy (the legacy one only its two files, never the folder that holds the others).
    static func remove(_ item: Leftover) {
        let fm = FileManager.default
        if item.folder.standardizedFileURL == root.standardizedFileURL {
            try? fm.removeItem(at: item.package)
            try? fm.removeItem(at: item.folder.appendingPathComponent("recovery.json"))
        } else {
            try? fm.removeItem(at: item.folder)
        }
    }

    /// Asks (or, in test mode, follows `ROOMSMITH_RECOVERY=restore|discard`) which copies to restore; returns the
    /// chosen ones as loaded projects. Unreadable copies are moved aside and reported in `problems`.
    static func offerRecovery(problems: inout [String]) -> [(project: Project, originalURL: URL?)] {
        let env = ProcessInfo.processInfo.environment
        // `ROOMSMITH_RECOVERY=restore|discard` only counts in test mode, so a stray variable never decides for the user.
        let auto = AppDefaults.isTestMode ? env["ROOMSMITH_RECOVERY"] : nil
        // Automated runs never block on a dialog; they keep the copies for a human launch.
        if auto == nil && AppDefaults.isTestMode { return [] }
        var restored: [(project: Project, originalURL: URL?)] = []
        for item in leftovers() {
            let restore: Bool
            if let auto { restore = auto == "restore" } else {
                let a = NSAlert()
                a.messageText = "Restore unsaved changes?"
                a.informativeText = "Roomsmith quit unexpectedly while \(item.name) had unsaved changes. The recovery copy is from \(item.info.date.formatted(date: .abbreviated, time: .shortened))."
                a.addButton(withTitle: "Restore"); a.addButton(withTitle: "Discard")
                restore = a.runModal() == .alertFirstButtonReturn
            }
            guard restore else { remove(item); continue }
            do {
                let (p, _) = try ProjectPackage.load(from: item.package)
                let original = item.info.originalPath.map { URL(fileURLWithPath: $0) }
                restored.append((p, original.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }))
                remove(item)
            } catch {
                // Keep the unreadable copy aside so a later tick or launch never deletes it silently.
                let aside = root.appendingPathComponent("Recovery-failed-\(Int(Date().timeIntervalSince1970))-\(item.id.lastPathComponent).\(ProjectPackage.fileExtension)")
                try? FileManager.default.moveItem(at: item.package, to: aside)
                remove(item)
                problems.append("Could not restore the recovery copy of \(item.name) (kept at \(aside.path)): \(userMessage(for: error))")
            }
        }
        return restored
    }
}
