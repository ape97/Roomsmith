import AppKit
import RoomsmithCore
import SwiftUI

/// Saved camera views of the document (`Project.cameras`): save the current 3D view under a name, jump to a view,
/// rename and delete. The same commands as the agent tools `camera.save`, `camera.apply`, `scene.rename_object`
/// and `scene.delete_objects`, so both sides stay in step.
extension AppModel {
    /// Saves `state` (the live 3D camera) under `name`; an existing view with the same name is overwritten.
    @discardableResult
    func saveView(name raw: String, state: CameraState) -> UUID? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { lastError = "Give the view a name"; NSSound.beep(); return nil }
        var id: UUID?
        perform("Save View") { id = $0.saveCamera(name: name, state: state) }
        return id
    }

    /// Moves the 3D camera to a saved view. Like any camera move it is not an undo step.
    func applyView(_ id: UUID) {
        guard let saved = project.cameras.first(where: { $0.id == id }) else { return }
        perform("Apply View", options: CommandOptions(recordUndo: false)) { $0.setCamera(saved.state) }
    }

    func renameView(_ id: UUID, to name: String) {
        perform("Rename View") { try $0.renameObject(id, to: name) }
    }

    func deleteView(_ id: UUID) {
        perform("Delete View") { _ = try $0.deleteObjects([id]) }
    }
}

/// The "Views" button of the 3D overlay and its popover. A popover instead of a `Menu` (see `SceneView.displayMenu`).
struct SavedViewsButton: View {
    @Environment(AppModel.self) private var model
    let ui: SceneUIState
    @State private var shown = false
    @State private var newName = ""
    @State private var editing: UUID?
    @State private var editName = ""

    var body: some View {
        Button { shown.toggle() } label: {
            Label("Saved views", systemImage: "camera.viewfinder")
        }
        .help("Saved views: save the current view, jump back to it")
        .accessibilityIdentifier("sceneView.savedViews")
        .popover(isPresented: $shown, arrowEdge: .bottom) { content }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Saved Views").font(.headline)
            if model.project.cameras.isEmpty {
                Text("No saved views yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.project.cameras) { row($0) }
                    }
                }
                .frame(maxHeight: 260)
            }
            Divider()
            HStack(spacing: 6) {
                TextField("View name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                    .accessibilityIdentifier("sceneView.savedViews.name")
                Button("Save", action: save)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("sceneView.savedViews.save")
            }
            Text("Saving under an existing name replaces that view.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 280)
        .onAppear { if newName.isEmpty { newName = suggestedName } }
    }

    @ViewBuilder
    private func row(_ c: SavedCamera) -> some View {
        HStack(spacing: 4) {
            if editing == c.id {
                TextField("Name", text: $editName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitRename(c.id) }
                    .onExitCommand { editing = nil }
                    .accessibilityIdentifier("sceneView.savedViews.renameField")
                Button { commitRename(c.id) } label: { Label("Done", systemImage: "checkmark") }
                    .help("Rename")
            } else {
                Button { model.applyView(c.id) } label: {
                    Text(c.name).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Go to this view")
                .accessibilityIdentifier("sceneView.savedViews.apply")
                Button { editName = c.name; editing = c.id } label: { Label("Rename", systemImage: "pencil") }
                    .help("Rename")
                    .accessibilityIdentifier("sceneView.savedViews.rename")
                Button(role: .destructive) { model.deleteView(c.id) } label: { Label("Delete", systemImage: "trash") }
                    .help("Delete (undo with ⌘Z)")
                    .accessibilityIdentifier("sceneView.savedViews.delete")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(isCurrent(c) ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
    }

    /// The live view matches this saved view (after jumping to it, until the camera moves).
    private func isCurrent(_ c: SavedCamera) -> Bool { model.project.camera == c.state }

    private var suggestedName: String {
        let names = Set(model.project.cameras.map(\.name))
        var n = model.project.cameras.count + 1
        while names.contains("View \(n)") { n += 1 }
        return "View \(n)"
    }

    private func save() {
        // The live rig can be ahead of the stored camera (persisting is debounced): save what is on screen.
        ui.renderer?.flushCameraPersistence()
        let state = ui.renderer?.camera.rig.state ?? model.project.camera
        guard model.saveView(name: newName, state: state) != nil else { return }
        newName = suggestedName
    }

    private func commitRename(_ id: UUID) {
        if let current = model.project.cameras.first(where: { $0.id == id })?.name, editName != current {
            model.renameView(id, to: editName)
        }
        editing = nil
    }
}
