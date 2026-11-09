import SwiftUI
import RoomsmithCore

// MARK: Wall

struct InspectorWallView: View {
    @Environment(AppModel.self) private var model
    let id: UUID

    var body: some View {
        let p = model.project
        if let w = p.wall(id) {
            let u = model.unit
            let locked = p.isLocked(id)
            let length = MM(p.wallLength(w).rounded())
            Form {
                Section("Wall") {
                    Group {
                        PointFields(title: "Start", point: w.start, unit: u) { v in
                            model.perform("Move Wall Start") { try $0.updateWall(id, start: v) }
                        }
                        PointFields(title: "End", point: w.end, unit: u) { v in
                            model.perform("Move Wall End") { try $0.updateWall(id, end: v) }
                        }
                        LabeledContent("Length") {
                            LengthField(title: "Wall length", value: length, unit: u, range: sizeLimit) { v in setLength(w, v) }
                        }
                        LabeledContent("Thickness") {
                            LengthField(title: "Wall thickness", value: w.thickness, unit: u, range: sizeLimit) { v in
                                model.perform("Set Wall Thickness") { try $0.updateWall(id, thickness: v) }
                            }
                        }
                        LabeledContent("Height") {
                            LengthField(title: "Wall height", value: w.height, unit: u, range: sizeLimit) { v in
                                model.perform("Set Wall Height") { try $0.updateWall(id, height: v) }
                            }
                        }
                    }
                    .disabled(locked)
                    LockToggle(id: id, locked: w.locked)
                }
                Section("Materials") {
                    MaterialPicker(title: "Left face", materials: p.materials, selection: w.leftMaterialId) { m in
                        model.perform("Set Wall Material") { try $0.setMaterial([id], slot: .wallLeft, materialId: m) }
                    }
                    MaterialPicker(title: "Right face", materials: p.materials, selection: w.rightMaterialId) { m in
                        model.perform("Set Wall Material") { try $0.setMaterial([id], slot: .wallRight, materialId: m) }
                    }
                }
                .disabled(locked)
                Section {
                    Button("Split at middle") { split(w) }
                        .controlSize(.small)
                        .disabled(locked || length < 2)
                        .help("Cut the wall into two walls of equal length")
                }
            }
            .formStyle(.grouped)
        }
    }

    /// Changing the length moves the end point along the wall direction.
    private func setLength(_ w: Wall, _ len: MM) -> Bool {
        let dir = Geo.axis(w.start, w.end).dir
        let d = (dir.x == 0 && dir.y == 0) ? V2(1, 0) : dir
        let end = P2(rounding: w.start.v + d * Double(len))
        return model.perform("Set Wall Length") { try $0.updateWall(id, end: end) }
    }

    private func split(_ w: Wall) {
        let mid = P2(rounding: (w.start.v + w.end.v) / 2)
        var first: UUID?
        if model.perform("Split Wall", { first = try $0.splitWall(id, at: mid).0 }), let first { model.selection = [first] }
    }
}

// MARK: Room

struct InspectorRoomView: View {
    @Environment(AppModel.self) private var model
    let id: UUID

    var body: some View {
        let p = model.project
        if let r = p.room(id) {
            let u = model.unit
            Form {
                Section("Room") {
                    LabeledContent("Name") { NameField(title: "Room name", value: r.name) { model.rename(id, to: $0) } }
                    LabeledContent("Area") { Text(LengthUnit.areaText(Geo.area(r.points))).monospacedDigit() }
                    LabeledContent("Perimeter") { Text(u.format(MM(Geo.perimeter(r.points).rounded()))).monospacedDigit() }
                    Toggle("Show floor", isOn: Binding(get: { r.showFloor }, set: { v in model.perform("Show Floor") { try $0.updateRoom(id, showFloor: v) } }))
                    Toggle("Show ceiling", isOn: Binding(get: { r.showCeiling }, set: { v in model.perform("Show Ceiling") { try $0.updateRoom(id, showCeiling: v) } }))
                }
                Section("Materials") {
                    MaterialPicker(title: "Floor", materials: p.materials, selection: r.floorMaterialId) { m in
                        model.perform("Set Floor Material") { try $0.setMaterial([id], slot: .roomFloor, materialId: m) }
                    }
                    MaterialPicker(title: "Ceiling", materials: p.materials, selection: r.ceilingMaterialId) { m in
                        model.perform("Set Ceiling Material") { try $0.setMaterial([id], slot: .roomCeiling, materialId: m) }
                    }
                }
                Section("Points") {
                    ForEach(Array(r.points.enumerated()), id: \.offset) { index, pt in
                        HStack(spacing: 4) {
                            Text("\(index + 1)").font(.caption).foregroundStyle(.secondary).frame(width: 18)
                            LengthField(title: "Point \(index + 1) x", value: pt.x, unit: u, compact: true) { setPoint(r, index, P2($0, pt.y)) }
                            LengthField(title: "Point \(index + 1) y", value: pt.y, unit: u, compact: true) { setPoint(r, index, P2(pt.x, $0)) }
                            Button { removePoint(r, index) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .disabled(r.points.count <= 3)
                                .help("Remove this corner")
                                .accessibilityLabel("Remove corner \(index + 1)")
                        }
                    }
                    Button { addPoint(r) } label: { Label("Add corner", systemImage: "plus") }
                        .controlSize(.small)
                        .help("Insert a corner in the middle of the closing edge")
                }
            }
            .formStyle(.grouped)
        }
    }

    private func setPoint(_ r: Room, _ i: Int, _ pt: P2) -> Bool {
        var pts = r.points; pts[i] = pt
        return model.perform("Move Room Corner") { try $0.updateRoom(id, points: pts) }
    }
    private func removePoint(_ r: Room, _ i: Int) {
        var pts = r.points; pts.remove(at: i)
        model.perform("Remove Room Corner") { try $0.updateRoom(id, points: pts) }
    }
    private func addPoint(_ r: Room) {
        guard let last = r.points.last, let first = r.points.first else { return }
        var pts = r.points
        pts.append(P2(rounding: (last.v + first.v) / 2))
        model.perform("Add Room Corner") { try $0.updateRoom(id, points: pts) }
    }
}

// MARK: Opening

struct InspectorOpeningView: View {
    @Environment(AppModel.self) private var model
    let id: UUID

    var body: some View {
        let p = model.project
        if let o = p.opening(id) {
            let u = model.unit
            let locked = p.isLocked(id)
            let hasGlass = o.kind == .window || o.style == .glass || o.style == .sliding
            Form {
                Section("Opening") {
                    Group {
                        Picker("Kind", selection: Binding(get: { o.kind }, set: { k in model.perform("Set Opening Kind") { try $0.updateOpening(id, kind: k) } })) {
                            ForEach(OpeningKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                        }
                        LabeledContent("Name") { NameField(title: "Opening name", value: o.name, allowEmpty: true) { model.rename(id, to: $0) } }
                        field("Offset", o.offset, u, nil) { v in model.perform("Set Opening Offset") { try $0.updateOpening(id, offset: v) } }
                        field("Width", o.width, u, sizeLimit) { v in model.perform("Set Opening Width") { try $0.updateOpening(id, width: v) } }
                        field("Height", o.height, u, sizeLimit) { v in model.perform("Set Opening Height") { try $0.updateOpening(id, height: v) } }
                        field("Sill", o.sill, u, 0 ... sizeLimit.upperBound) { v in model.perform("Set Opening Sill") { try $0.updateOpening(id, sill: v) } }
                        Toggle("Mirrored", isOn: Binding(get: { o.flipped }, set: { v in model.perform("Mirror Opening") { try $0.updateOpening(id, flipped: v) } }))
                        Toggle("Opens inward", isOn: Binding(get: { o.inward }, set: { v in model.perform("Set Opening Side") { try $0.updateOpening(id, inward: v) } }))
                    }
                    .disabled(locked)
                }
                if o.kind != .opening {
                Section("Detail") {
                    Group {
                        Picker("Style", selection: Binding(get: { o.style }, set: { v in model.perform("Set Opening Style") { try $0.updateOpening(id, style: v) } })) {
                            ForEach(OpeningStyle.styles(for: o.kind), id: \.self) { Text(styleTitle($0)).tag($0) }
                        }
                        .help("Look of the door leaf or window sash")
                        Picker("Handle", selection: Binding(get: { o.handle }, set: { v in model.perform("Set Opening Handle") { try $0.updateOpening(id, handle: v) } })) {
                            ForEach(OpeningHandle.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                        }
                        .help("Handle on both faces of the leaf, on the side opposite the hinge")
                        .disabled(o.kind == .window && o.style == .fixed)
                        Picker("Glass", selection: Binding(get: { o.glassType }, set: { v in model.perform("Set Opening Glass") { try $0.updateOpening(id, glassType: v) } })) {
                            ForEach(OpeningGlass.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                        }
                        .help("Glass type of windows and glazed doors")
                        .disabled(!hasGlass)
                        field("Frame width", o.frameWidth, u, 20 ... 150) { v in model.perform("Set Frame Width") { try $0.updateOpening(id, frameWidth: v) } }
                        Stepper("Vertical bars: \(o.mullionCols)", value: Binding(get: { o.mullionCols }, set: { v in model.perform("Set Opening Bars") { try $0.updateOpening(id, mullionCols: v) } }), in: 0 ... 6)
                            .help("Number of vertical glazing bars")
                            .disabled(!hasGlass)
                        Stepper("Horizontal bars: \(o.mullionRows)", value: Binding(get: { o.mullionRows }, set: { v in model.perform("Set Opening Bars") { try $0.updateOpening(id, mullionRows: v) } }), in: 0 ... 6)
                            .help("Number of horizontal glazing bars")
                            .disabled(!hasGlass)
                    }
                    .disabled(locked)
                }
                }
                Section("Frame") {
                    MaterialPicker(title: "Frame material", materials: p.materials, selection: o.frameMaterialId) { m in
                        model.perform("Set Frame Material") { try $0.setMaterial([id], slot: .openingFrame, materialId: m) }
                    }
                    .disabled(locked)
                }
                Section {
                    Button("Select Wall") { model.selection = [o.wallId] }.controlSize(.small).help("Select the wall that holds this opening")
                }
            }
            .formStyle(.grouped)
        }
    }

    private func styleTitle(_ s: OpeningStyle) -> String {
        switch s {
        case .smooth: "Smooth"
        case .panel2: "Two panels"
        case .panel4: "Four panels"
        case .glass: "Glazed"
        case .sliding: "Sliding"
        case .tiltTurn1: "Tilt and turn"
        case .tiltTurn2: "Two sashes"
        case .fixed: "Fixed"
        case .balconyDoor: "Balcony door"
        case .balconyDoor2: "Two-sash balcony door"
        }
    }

    private func field(_ title: String, _ v: MM, _ u: LengthUnit, _ range: ClosedRange<MM>?, _ commit: @escaping (MM) -> Bool) -> some View {
        LabeledContent(title) {
            LengthField(title: title, value: v, unit: u, range: range ?? (-coordinateLimit ... coordinateLimit), onCommit: commit)
        }
    }
}

// MARK: Dimension

struct InspectorDimensionView: View {
    @Environment(AppModel.self) private var model
    let id: UUID

    var body: some View {
        let p = model.project
        if let d = p.dimension(id) {
            let u = model.unit
            Form {
                Section("Dimension") {
                    PointFields(title: "From", point: d.a, unit: u) { v in model.perform("Move Dimension") { try $0.updateDimension(id, a: v) } }
                    PointFields(title: "To", point: d.b, unit: u) { v in model.perform("Move Dimension") { try $0.updateDimension(id, b: v) } }
                    LabeledContent("Offset") {
                        LengthField(title: "Dimension offset", value: d.offset, unit: u) { v in
                            model.perform("Set Dimension Offset") { try $0.updateDimension(id, offset: v) }
                        }
                    }
                    LabeledContent("Measured") { Text(u.format(MM(Geo.distance(d.a, d.b).rounded()))).monospacedDigit() }
                }
            }
            .formStyle(.grouped)
        }
    }
}
