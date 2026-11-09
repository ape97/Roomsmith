import SwiftUI
import RoomsmithCore

/// Edit design: opens the furniture builder on a scratch project holding the entry's piece. A save writes the result
/// back to the library entry (revision +1, new picture); the open project is not touched.
struct LibraryDesignEditor: View {
    let entryId: UUID
    @Environment(AppModel.self) private var host
    @Environment(\.dismiss) private var dismiss
    @State private var scratch: AppModel?
    @State private var definitionId: UUID?
    @State private var package: URL?
    @State private var failure: String?
    private let library = LibraryModel.shared

    /// One furniture piece (one instance of one design) can be edited in the builder; groups and sets cannot.
    static func canEdit(_ e: LibraryEntry) -> Bool { e.definitionId != nil }

    var body: some View {
        Group {
            if let scratch, let definitionId {
                FurnitureBuilderView(definitionId: definitionId, onSaved: write)
                    .environment(scratch)
            } else if let failure {
                VStack(spacing: 10) {
                    Text(failure).foregroundStyle(.secondary)
                    Button("Close") { dismiss() }
                }.padding(24)
            } else {
                ProgressView().padding(40)
            }
        }
        .frame(minWidth: 780, minHeight: 480)
        .task { build() }
        .onDisappear {
            if let package { try? FileManager.default.removeItem(at: package) }
            package = nil
        }
    }

    private func build() {
        do {
            let t = try library.store.transfer(for: entryId)
            let m = AppModel(project: Project.empty(name: "Edit design"))
            guard let level = m.project.levels.first else { throw LibraryError.invalid("no level") }
            var dir: URL?
            if !t.assets.isEmpty {
                let d = FileManager.default.temporaryDirectory.appendingPathComponent("rs-design-\(UUID().uuidString).roomsmith", isDirectory: true)
                try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
                dir = d; package = d; m.fileURL = d
            }
            var offset = P2(0, 0)
            if let c = t.center { offset = P2(-c.x, -c.y) }
            try FurnitureTransferService.importTransfer(t, into: m.store, targetPackage: dir, levelId: level.id, offset: offset)
            guard m.project.instances.count == 1, let def = m.project.instances.first?.definitionId else {
                throw LibraryError.invalid("Only single furniture items can be edited in the builder")
            }
            scratch = m; definitionId = def
        } catch { failure = userMessage(for: error) }
    }

    /// The builder saved into the scratch project: pack it again and replace the entry.
    private func write(spec: ParametricSpec?) {
        guard let scratch else { return }
        do {
            let ids = scratch.project.instances.map(\.id)
            let t = try LibraryContent.pack(project: scratch.project, ids: ids, packageURL: scratch.fileURL)
            let e = try library.store.replaceTransfer(entryId, with: t, spec: spec)
            host.statusMessage = "Updated design of \"\(e.name)\""
        } catch { host.lastError = (error as? LibraryError)?.description ?? userMessage(for: error) }
    }
}
