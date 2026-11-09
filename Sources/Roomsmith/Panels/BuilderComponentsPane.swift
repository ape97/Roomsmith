import SwiftUI
import RoomsmithCore

// MARK: Small numeric fields

/// Length in millimetres. Accepts "1200", "120 cm", "1.2 m" and `+` / `-` sums; out-of-range input turns red and is not stored.
struct MMField: View {
    let label: String
    @Binding var value: MM
    /// Positions use the coordinate range; sizes pass `sizeLimit`.
    var range: ClosedRange<MM> = -coordinateLimit ... coordinateLimit
    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 14, alignment: .trailing)
            LengthField(title: label, value: value, unit: .mm, range: range, compact: true) { value = $0; return true }
                .frame(minWidth: 52)
        }
    }
}

struct DegField: View {
    let label: String
    @Binding var value: Double
    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 14, alignment: .trailing)
            TextField(label, value: $value, format: .number.precision(.fractionLength(0...2)).grouping(.never))
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(minWidth: 52)
        }
    }
}

struct P3Fields: View {
    let title: String
    @Binding var value: P3
    var body: some View {
        LabeledContent(title) {
            HStack {
                MMField(label: "X", value: $value.x)
                MMField(label: "Y", value: $value.y)
                MMField(label: "Z", value: $value.z)
            }
        }
    }
}

struct R3Fields: View {
    let title: String
    @Binding var value: R3
    var body: some View {
        LabeledContent(title) {
            HStack {
                DegField(label: "X", value: $value.x)
                DegField(label: "Y", value: $value.y)
                DegField(label: "Z", value: $value.z)
            }
        }
    }
}

// MARK: Component list and editor

struct BuilderComponentsPane: View {
    @Binding var def: FurnitureDefinition
    @Binding var selected: UUID?
    let materials: [RoomsmithCore.Material]
    let assets: [ProjectAsset]
    var onGeometryChange: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selected) {
                ForEach(def.components) { c in
                    HStack {
                        Image(systemName: icon(c.shape)).frame(width: 18).foregroundStyle(.secondary)
                        Text(c.name.isEmpty ? "Unnamed" : c.name).lineLimit(1)
                        Spacer()
                        if !c.visible { Image(systemName: "eye.slash").foregroundStyle(.secondary) }
                    }
                    .tag(c.id)
                }
            }
            .frame(minHeight: 120, idealHeight: 180)
            .accessibilityIdentifier("builderComponentList")
            HStack {
                Button { add() } label: { Image(systemName: "plus") }.help("Add component")
                    .accessibilityLabel("Add component")
                Button { duplicate() } label: { Image(systemName: "plus.square.on.square") }
                    .help("Duplicate component").accessibilityLabel("Duplicate component").disabled(selected == nil)
                Button { remove() } label: { Image(systemName: "minus") }
                    .help("Delete component").accessibilityLabel("Delete component").disabled(selected == nil)
                Spacer()
                Text("\(def.components.count) components").font(.caption).foregroundStyle(.secondary)
            }
            .padding(6)
            Divider()
            if let id = selected, def.components.contains(where: { $0.id == id }) {
                ScrollView { editor(id).padding(10) }
            } else {
                Text("Select a component to edit it.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func icon(_ s: PrimitiveShape) -> String {
        switch s {
        case .box: "cube"; case .cushion: "square.fill.on.square"; case .cylinder: "cylinder"
        case .sphere: "circle"; case .panel: "rectangle"; case .mesh: "shippingbox"
        case .rounded: "square.on.square"; case .taper: "cone"
        }
    }

    private func binding(_ id: UUID) -> Binding<Component> {
        Binding(
            get: { def.components.first { $0.id == id } ?? Component(id: id, name: "", shape: .box, position: .zero, size: Size3(1, 1, 1)) },
            set: { new in
                guard let i = def.components.firstIndex(where: { $0.id == id }) else { return }
                def.components[i] = new
                onGeometryChange()
            })
    }

    @ViewBuilder private func editor(_ id: UUID) -> some View {
        let c = binding(id)
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name", text: c.name).textFieldStyle(.roundedBorder)
            Picker("Shape", selection: c.shape) {
                ForEach(PrimitiveShape.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            if c.wrappedValue.shape == .mesh {
                Picker("Mesh asset", selection: c.meshAssetId) {
                    Text("None").tag(UUID?.none)
                    ForEach(assets.filter { $0.kind == .mesh }) { Text($0.originalName).tag(UUID?.some($0.id)) }
                }
            }
            P3Fields(title: "Position (mm)", value: c.position)
            LabeledContent("Size (mm)") {
                HStack {
                    MMField(label: "W", value: c.size.width, range: sizeLimit)
                    MMField(label: "D", value: c.size.depth, range: sizeLimit)
                    MMField(label: "H", value: c.size.height, range: sizeLimit)
                }
            }
            R3Fields(title: "Rotation (°)", value: c.rotation)
            Toggle("Custom pivot", isOn: Binding(
                get: { c.wrappedValue.pivot != nil },
                set: { c.wrappedValue.pivot = $0 ? c.wrappedValue.position : nil }))
            if c.wrappedValue.pivot != nil {
                P3Fields(title: "Pivot (mm)", value: Binding(get: { c.wrappedValue.pivot ?? .zero }, set: { c.wrappedValue.pivot = $0 }))
            }
            Picker("Material", selection: c.materialId) {
                Text("None").tag(UUID?.none)
                ForEach(materials) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            Toggle("Visible", isOn: c.visible)
        }
    }

    private func add() {
        var c = Component(name: "Part \(def.components.count + 1)", shape: .box, position: P3(0, 0, 50), size: Size3(100, 100, 100))
        c.materialId = def.components.last?.materialId
        def.components.append(c)
        selected = c.id
        onGeometryChange()
    }

    private func duplicate() {
        guard let id = selected, let src = def.components.first(where: { $0.id == id }) else { return }
        var c = src
        c.id = UUID()
        c.name = src.name + " copy"
        c.position.x += 50
        def.components.append(c)
        for i in def.states.indices {
            if let pose = def.states[i].poses[id] { def.states[i].poses[c.id] = pose }
        }
        selected = c.id
        onGeometryChange()
    }

    private func remove() {
        guard let id = selected else { return }
        def.components.removeAll { $0.id == id }
        for i in def.states.indices { def.states[i].poses[id] = nil }
        for g in def.optionGroups.indices { for c in def.optionGroups[g].choices.indices { def.optionGroups[g].choices[c].effects[id] = nil } }
        selected = nil
        onGeometryChange()
    }
}
