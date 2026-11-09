import SwiftUI
import AppKit
import RoomsmithCore

/// Whether the material editor sheet is open and which material it shows. Lives here (not in `AppModel`) and is
/// injected with `.environment`; the sheet itself is attached by `MaterialEditorHost`.
@MainActor @Observable
final class MaterialEditorState {
    var isPresented = false
    var selectedId: UUID?

    func open(selecting id: UUID? = nil) {
        if let id { selectedId = id }
        isPresented = true
    }
}

/// Attaches the editor sheet. Apply it inside the `.environment(model)` of the window content.
struct MaterialEditorHost: ViewModifier {
    @Bindable var state: MaterialEditorState

    func body(content: Content) -> some View {
        content.sheet(isPresented: $state.isPresented) {
            MaterialEditorSheet(state: state).frame(minWidth: 640, minHeight: 420)
        }
    }
}

/// View > Material Editor…
struct MaterialCommands: Commands {
    let state: MaterialEditorState

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button("Material Editor…") { state.open() }
            Divider()
        }
    }
}

// MARK: - Sheet

struct MaterialEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Bindable var state: MaterialEditorState

    var body: some View {
        let p = model.project
        VStack(spacing: 0) {
            HSplitView {
                VStack(spacing: 0) {
                    List(selection: $state.selectedId) {
                        ForEach(p.materials) { m in
                            HStack(spacing: 6) {
                                Image(systemName: "circle.fill").foregroundStyle(swatch(m.color))
                                Text(m.name).lineLimit(1)
                            }
                            .tag(m.id)
                        }
                    }
                    .overlay { if p.materials.isEmpty { ContentUnavailableView("No materials", systemImage: "paintpalette",
                                                                         description: Text("Click New material below to create one.")) } }
                    Divider()
                    HStack {
                        Button { addMaterial() } label: { Label("New material", systemImage: "plus") }
                            .help("Create a material")
                        Spacer()
                    }
                    .padding(8)
                }
                .frame(minWidth: 200, idealWidth: 220, maxWidth: 300)
                Group {
                    if let id = state.selectedId, p.material(id) != nil {
                        MaterialDetailView(id: id, state: state).id(id)
                    } else {
                        ContentUnavailableView("Select a material", systemImage: "paintpalette")
                    }
                }
                .frame(minWidth: 340)
            }
            Divider()
            HStack {
                if let e = model.lastError { Text(e).font(.callout).foregroundStyle(.red).lineLimit(2) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .onAppear {
            // An older error (e.g. from deleting in the sidebar) must not show up in a freshly opened editor.
            model.lastError = nil
            if state.selectedId.map({ model.project.material($0) == nil }) ?? true { state.selectedId = model.project.materials.first?.id }
        }
    }

    private func addMaterial() {
        let names = Set(model.project.materials.map { $0.name.lowercased() })
        var n = model.project.materials.count + 1
        while names.contains("material \(n)") { n += 1 }
        let m = RoomsmithCore.Material(name: "Material \(n)", color: RoomsmithCore.RGBColor(180, 180, 180))
        if model.perform("New Material", { _ = $0.addMaterial(m) }) { state.selectedId = m.id }
    }
}

private func swatch(_ c: RoomsmithCore.RGBColor) -> Color {
    Color(.sRGB, red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
}

// MARK: - Detail

private struct MaterialDetailView: View {
    @Environment(AppModel.self) private var model
    let id: UUID
    @Bindable var state: MaterialEditorState
    @State private var color = Color.gray
    @State private var color2 = Color.gray
    /// Second colour as last set by the model (not by the user); only a deviation from it is committed.
    @State private var color2Synced = RoomsmithCore.RGBColor(0, 0, 0)

    var body: some View {
        let p = model.project
        if let m = p.material(id) {
            let users = Set(p.references(to: id).map(\.id)).count
            Form {
                Section {
                    LabeledContent("Name") {
                        NameField(title: "Material name", value: m.name) { v in rename(v) }
                    }
                    LabeledContent("Colour") {
                        ColorPicker("Colour", selection: $color, supportsOpacity: false).labelsHidden()
                    }
                    UnitSliderRow(title: "Roughness", value: m.roughness, hint: "0 mirror, 1 matte") { v in set("Material Roughness") { $0.roughness = v } }
                    UnitSliderRow(title: "Metallic", value: m.metallic, hint: "") { v in set("Material Metallic") { $0.metallic = v } }
                    UnitSliderRow(title: "Opacity", value: m.opacity, hint: "0 invisible, 1 solid") { v in set("Material Opacity") { $0.opacity = v } }
                    LabeledContent("Texture tile") {
                        LengthField(title: "Texture tile", value: m.textureTile, unit: model.unit, range: sizeLimit) { v in
                            set("Material Texture Tile") { $0.textureTile = v }
                        }
                    }
                    if m.textureAssetId != nil {
                        LabeledContent("Texture") { Text("Image texture (set by import)").foregroundStyle(.secondary) }
                    }
                }
                Section("Surface") {
                    LabeledContent("Preset") {
                        Menu(presetTitle(m)) {
                            ForEach(presetGroups, id: \.self) { g in
                                Menu(g) {
                                    ForEach(MaterialPresets.all.filter { $0.group == g }) { pr in
                                        Button(pr.name) { model.perform("Apply Material Preset") { try $0.applyMaterialPreset(id, preset: pr.id) } }
                                    }
                                }
                            }
                        }
                        .help("Replace finish, pattern and gloss with a built-in preset")
                    }
                    Picker("Finish", selection: Binding(get: { m.finish }, set: { v in set("Material Finish") { $0.finish = v } })) {
                        ForEach(MaterialFinish.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    .help("Brushed metal shows stretched highlights")
                    Picker("Pattern", selection: Binding(get: { m.pattern }, set: { v in set("Material Pattern") { $0.pattern = v } })) {
                        ForEach(MaterialPattern.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    .help("Procedural pattern made from the two colours; an imported image texture takes precedence")
                    if m.pattern != .none {
                        LabeledContent("Second colour") {
                            HStack {
                                ColorPicker("Second colour", selection: $color2, supportsOpacity: false).labelsHidden()
                                Button("Auto") { set("Material Second Colour") { $0.color2 = nil } }
                                    .disabled(m.color2 == nil)
                                    .help("Derive the second colour from the main colour")
                            }
                        }
                        LabeledContent("Pattern size") {
                            LengthField(title: "Pattern size", value: m.patternSize, unit: model.unit, range: sizeLimit) { v in
                                set("Material Pattern Size") { $0.patternSize = v }
                            }
                        }
                        if m.pattern == .grid || m.pattern == .tiles || m.pattern == .wood {
                            LabeledContent("Joint width") {
                                LengthField(title: "Joint width", value: m.grout, unit: model.unit, range: 0 ... 100) { v in
                                    set("Material Joint Width") { $0.grout = v }
                                }
                            }
                        }
                        LabeledContent("Preview") { PatternPreview(material: m) }
                    }
                    if m.pattern != .none || m.finish == .brushed {
                        AngleSliderRow(title: m.pattern == .none ? "Brush direction" : "Grain direction", value: m.patternAngleDeg,
                                       hint: "Rotation of the pattern or brushing in degrees") { v in set("Material Pattern Angle") { $0.patternAngleDeg = v } }
                    }
                    UnitSliderRow(title: "Clear coat", value: m.clearcoat, hint: "Lacquer layer, 0 none, 1 full") { v in set("Material Clear Coat") { $0.clearcoat = v } }
                    UnitSliderRow(title: "Specular", value: m.specular, hint: "Strength of highlights") { v in set("Material Specular") { $0.specular = v } }
                }
                Section {
                    LabeledContent("Used by") { Text(users == 0 ? "Nothing" : "\(users) object(s)") }
                    HStack {
                        Spacer()
                        Button("Delete", role: .destructive) { if model.deleteCatalogEntry(id) { state.selectedId = nil } }
                            .help(users == 0 ? "Delete this material" : "Only unused materials can be deleted")
                            .disabled(users > 0)
                    }
                }
            }
            .formStyle(.grouped)
            .onAppear { color = swatch(m.color); syncColor2(m) }
            .onChange(of: m.color2) { _, _ in if let m = model.project.material(id) { syncColor2(m) } }
            .onChange(of: m.color) { _, _ in if let m = model.project.material(id), m.color2 == nil { syncColor2(m) } }
            .task(id: ColorKey(rgb: rgb(of: color2))) {
                try? await Task.sleep(for: .milliseconds(400))
                if !Task.isCancelled { commitColor2() }
            }
            // Undo / redo / agent edits: follow the stored colour unless it is what the picker already shows.
            .onChange(of: m.color) { _, new in if rgb(of: color) != new { color = swatch(new) } }
            // Debounce: the picker streams values while dragging; one undo step after the colour rests for a moment.
            .task(id: ColorKey(rgb: rgb(of: color))) {
                try? await Task.sleep(for: .milliseconds(400))
                if !Task.isCancelled { commitColor() }
            }
            .onDisappear { commitColor(); commitColor2() }
        }
    }

    private var presetGroups: [String] {
        var seen: [String] = []
        for p in MaterialPresets.all where !seen.contains(p.group) { seen.append(p.group) }
        return seen
    }

    private func presetTitle(_ m: RoomsmithCore.Material) -> String {
        m.preset.flatMap { MaterialPresets.preset($0)?.name } ?? "Choose…"
    }

    private struct ColorKey: Hashable { var rgb: RoomsmithCore.RGBColor }

    private func rgb(of c: Color) -> RoomsmithCore.RGBColor {
        let ns = NSColor(c).usingColorSpace(.sRGB) ?? .gray
        func byte(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        return RoomsmithCore.RGBColor(byte(ns.redComponent), byte(ns.greenComponent), byte(ns.blueComponent))
    }

    private func syncColor2(_ m: RoomsmithCore.Material) {
        let shown = m.color2 ?? ProceduralTexture.defaultSecondColor(m.color)
        color2Synced = shown
        color2 = swatch(shown)
    }

    private func commitColor2() {
        guard let m = model.project.material(id) else { return }
        let new = rgb(of: color2)
        guard new != color2Synced, new != m.color2 else { return }
        color2Synced = new
        set("Material Second Colour") { $0.color2 = new }
    }

    private func commitColor() {
        guard let m = model.project.material(id) else { return }
        let new = rgb(of: color)
        if new != m.color { set("Material Colour") { $0.color = new } }
    }

    @discardableResult
    private func set(_ name: String, _ change: @escaping (inout RoomsmithCore.Material) -> Void) -> Bool {
        model.perform(name) { p in try p.updateMaterial(id) { change(&$0) } }
    }

    private func rename(_ raw: String) -> Bool {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.project.materials.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            model.lastError = "A material named '\(name)' already exists"
            return false
        }
        return set("Rename Material") { $0.name = name }
    }
}

/// 0...1 slider that commits once when the drag ends (one undo step), with the value shown beside it.
private struct UnitSliderRow: View {
    let title: String
    let value: Double
    let hint: String
    let onCommit: (Double) -> Bool
    @State private var draft = 0.0

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $draft, in: 0...1) { editing in
                    if !editing { commit() }
                }
                .help(hint)
                Text(String(format: "%.2f", draft)).monospacedDigit().frame(width: 36, alignment: .trailing)
            }
        }
        .onAppear { draft = value }
        .onChange(of: value) { _, new in draft = new }
    }

    private func commit() {
        let v = (draft * 100).rounded() / 100
        if v != value, !onCommit(v) { draft = value }
    }
}

/// 0...359 degree slider that commits once when the drag ends (one undo step).
private struct AngleSliderRow: View {
    let title: String
    let value: Double
    let hint: String
    let onCommit: (Double) -> Bool
    @State private var draft = 0.0

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $draft, in: 0...359) { editing in
                    if !editing { commit() }
                }
                .help(hint)
                Text("\(Int(draft.rounded()))°").monospacedDigit().frame(width: 40, alignment: .trailing)
            }
        }
        .onAppear { draft = value }
        .onChange(of: value) { _, new in draft = new }
    }

    private func commit() {
        let v = draft.rounded()
        if v != value, !onCommit(v) { draft = value }
    }
}

/// Preview tile: one repeat of the procedural pattern (128 px, rendered off the main thread), rotated like in the 3D view and shown 2 x 2 times.
private struct PatternPreview: View {
    let material: RoomsmithCore.Material
    @State private var image: CGImage?

    var body: some View {
        let params = ProceduralTexture.params(for: material)
        ZStack {
            if let image {
                Canvas { ctx, size in
                    let img = Image(decorative: image, scale: 1)
                    let tile = size.width / 2
                    ctx.rotate(by: .degrees(-material.patternAngleDeg))
                    for x in -2...3 {
                        for y in -2...3 {
                            ctx.draw(img, in: CGRect(x: CGFloat(x) * tile, y: CGFloat(y) * tile, width: tile, height: tile))
                        }
                    }
                }
            } else {
                Color.clear
            }
        }
        .frame(width: 96, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
        .accessibilityLabel("Pattern preview")
        .task(id: params) {
            guard let params else { image = nil; return }
            let pixels = await Task.detached(priority: .utility) { ProceduralTexture.render(params, side: 128) }.value
            if !Task.isCancelled { image = ProceduralTexture.cgImage(pixels) }
        }
    }
}
