import SwiftUI
import RoomsmithCore

/// A large 3D view of one library entry or built-in piece that can be turned around with the mouse.
/// It shows a scratch project, so nothing here touches the open project.
struct LibraryPreviewSheet: View {
    let target: LibraryPreviewTarget
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var host
    @State private var scratch: AppModel?
    @State private var scratchPackage: URL?
    @State private var ui = SceneUIState()
    @State private var failure: String?
    private let library = LibraryModel.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline).lineLimit(1)
                Spacer()
                if let id = entryId {
                    Button("Place on \(host.activeLevel?.name ?? "level")") { _ = host.dropLibrary(id, at: host.placementPoint()); dismiss() }
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            ZStack {
                if let scratch {
                    SceneCanvas(model: scratch, ui: ui, options: SceneOptions(showCeilings: false, onlyActiveLevel: true, wallOpacity: 1, showLamps: true))
                        .accessibilityIdentifier("libraryPreview3D")
                } else if let failure {
                    Text(failure).foregroundStyle(.secondary).padding()
                } else {
                    ProgressView()
                }
            }
            Text("Drag to turn, scroll to zoom").font(.caption).foregroundStyle(.secondary).padding(6)
        }
        .frame(minWidth: 560, idealWidth: 720, minHeight: 460, idealHeight: 560)
        .task { await build() }
        .onDisappear {
            if let scratchPackage { try? FileManager.default.removeItem(at: scratchPackage) }
            scratchPackage = nil
        }
    }

    private var entryId: UUID? { if case .entry(let id) = target { id } else { nil } }

    private var title: String {
        switch target {
        case .entry(let id): library.entry(id)?.name ?? "Furniture"
        case .catalog(let key): BuiltinCatalog.search("").first { $0.key == key }?.name ?? "Standard furniture"
        }
    }

    private func build() async {
        do {
            let m = AppModel(project: Project.empty(name: "Preview"))
            guard let level = m.project.levels.first else { throw LibraryError.invalid("no level") }
            switch target {
            case .catalog(let key):
                try m.store.run("Preview") { p in _ = try p.placeDragged(.catalog(key), levelId: level.id, at: P2(0, 0)) }
            case .entry(let id):
                let t = try library.store.transfer(for: id)
                var dir: URL?
                if !t.assets.isEmpty {
                    let d = FileManager.default.temporaryDirectory.appendingPathComponent("rs-preview-\(UUID().uuidString).roomsmith", isDirectory: true)
                    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
                    dir = d; scratchPackage = d; m.fileURL = d
                }
                var offset = P2(0, 0)
                if let c = t.center { offset = P2(-c.x, -c.y) }
                try FurnitureTransferService.importTransfer(t, into: m.store, targetPackage: dir, levelId: level.id, offset: offset)
            }
            scratch = m
        } catch {
            failure = userMessage(for: error)
        }
    }
}
