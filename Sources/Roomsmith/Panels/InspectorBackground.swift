import SwiftUI
import RoomsmithCore

/// Inspector for one background image (scanned plan). The scale only changes through the Calibrate tool, which
/// uses the calibration command of the core; this form shows it read-only.
struct InspectorBackgroundView: View {
    @Environment(AppModel.self) private var model
    let id: UUID
    @State private var opacity = 0.5

    var body: some View {
        let p = model.project
        if let b = p.background(id) {
            Form {
                Section("Background image") {
                    LabeledContent("File") { Text(p.asset(b.assetId)?.originalName ?? "Missing image").lineLimit(1).truncationMode(.middle) }
                    LabeledContent("Level") { Text(p.level(b.levelId)?.name ?? "") }
                    Toggle("Visible", isOn: Binding(get: { b.visible }, set: { v in
                        model.perform(v ? "Show Background" : "Hide Background") { try $0.updateBackground(id) { $0.visible = v } }
                    }))
                    LabeledContent("Opacity") {
                        HStack {
                            Slider(value: $opacity, in: 0...1) { editing in if !editing { commitOpacity(b) } }
                            Text("\(Int((opacity * 100).rounded())) %").monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                    }
                    PointFields(title: "Top-left", point: b.origin, unit: model.unit) { v in
                        model.perform("Move Background") { try $0.updateBackground(id) { $0.origin = v } }
                    }
                }
                Section("Scale") {
                    LabeledContent("Millimetres per pixel") { Text(String(format: "%.4f mm/px", b.mmPerPixel)).monospacedDigit() }
                    LabeledContent("Pixels per metre") { Text(String(format: "%.2f px/m", 1000 / b.mmPerPixel)).monospacedDigit() }
                    LabeledContent("Reference") {
                        Text("\(model.unit.format(b.calibrationLength)) between (\(b.calibrationA.x), \(b.calibrationA.y)) and (\(b.calibrationB.x), \(b.calibrationB.y)) px")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                    Button("Calibrate…") {
                        model.selection = [id]
                        model.tool = .calibrate
                        model.statusMessage = "Click two points of known distance on the image"
                    }
                    .controlSize(.small)
                    .help("Pick two points on the image and enter their real distance")
                    Text("Position and scale are in whole millimetres; the image has no rotation.").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("Delete image", role: .destructive) { model.deleteObjects([id]) }
                        .controlSize(.small)
                }
            }
            .formStyle(.grouped)
            .onAppear { opacity = b.opacity }
            .onChange(of: b.opacity) { _, new in opacity = new }
        }
    }

    private func commitOpacity(_ b: BackgroundImage) {
        let v = (opacity * 100).rounded() / 100
        if v != b.opacity, !model.perform("Background Opacity", { try $0.updateBackground(id) { $0.opacity = v } }) { opacity = b.opacity }
    }
}

/// Nothing selected: the background images of the active level, to select one for editing or calibration.
struct InspectorBackgroundList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let p = model.project
        let list = p.backgrounds.filter { $0.levelId == model.activeLevelId }
        if !list.isEmpty {
            Section("Background images") {
                ForEach(list) { b in
                    HStack {
                        Image(systemName: b.visible ? "photo" : "eye.slash").foregroundStyle(.secondary)
                        Text(p.asset(b.assetId)?.originalName ?? "Background image").lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Edit") { model.selection = [b.id] }.controlSize(.small)
                        Button("Calibrate…") { model.selection = [b.id]; model.tool = .calibrate }.controlSize(.small)
                    }
                }
            }
        }
    }
}
