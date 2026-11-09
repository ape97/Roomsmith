import SwiftUI
import RoomsmithCore

/// States tab: states with per-component pose overrides, default state and animation tracks.
struct BuilderStatesPane: View {
    @Binding var def: FurnitureDefinition
    /// Selected state; nil = base pose. Shared with the preview.
    @Binding var stateId: UUID?
    @Binding var selectedComponent: UUID?

    @State private var trackFrom: UUID?
    @State private var trackTo: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                statesSection
                Divider()
                if let sid = stateId, let si = def.states.firstIndex(where: { $0.id == sid }) {
                    stateEditor(si)
                    Divider()
                }
                tracksSection
            }
            .padding(10)
        }
    }

    // MARK: States

    private var statesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("States").font(.headline)
            VStack(spacing: 0) {
                row(title: "Base pose", isDefault: def.defaultStateId == nil, id: nil)
                ForEach(def.states) { s in row(title: s.name, isDefault: def.defaultStateId == s.id, id: s.id) }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Button("Add State from Current Pose") { addState() }
                    .help("Creates a state that starts as a copy of the pose shown in the preview")
                Button("Delete") { deleteState() }.disabled(stateId == nil)
            }
        }
    }

    private func row(title: String, isDefault: Bool, id: UUID?) -> some View {
        HStack {
            Image(systemName: stateId == id ? "largecircle.fill.circle" : "circle")
            Text(title)
            Spacer()
            if isDefault { Text("Default").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(stateId == id ? Color.accentColor.opacity(0.15) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { stateId = id }
        .focusable()
        .onKeyPress(.space) { stateId = id; return .handled }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(stateId == id ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { stateId = id }
    }

    private func addState() {
        let base = stateId.flatMap { sid in def.states.first { $0.id == sid } }
        let s = FurnitureState(name: BuilderSupport.uniqueStateName("State", in: def), poses: base?.poses ?? [:], size: base?.size)
        def.states.append(s)
        if def.defaultStateId == nil && def.states.count == 1 { def.defaultStateId = s.id }
        stateId = s.id
    }

    private func deleteState() {
        guard let sid = stateId else { return }
        def.states.removeAll { $0.id == sid }
        def.tracks.removeAll { $0.toStateId == sid || $0.fromStateId == sid }
        if def.defaultStateId == sid { def.defaultStateId = def.states.first?.id }
        stateId = nil
    }

    // MARK: State editor

    @ViewBuilder private func stateEditor(_ si: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("State name", text: $def.states[si].name).textFieldStyle(.roundedBorder)
            Toggle("Default state of new instances", isOn: Binding(
                get: { def.defaultStateId == def.states[si].id },
                set: { def.defaultStateId = $0 ? def.states[si].id : nil }))
            Toggle("Override footprint size", isOn: Binding(
                get: { def.states[si].size != nil },
                set: { def.states[si].size = $0 ? def.size : nil }))
            if def.states[si].size != nil {
                LabeledContent("Size (mm)") {
                    HStack {
                        MMField(label: "W", value: sizeBinding(si).width, range: sizeLimit)
                        MMField(label: "D", value: sizeBinding(si).depth, range: sizeLimit)
                        MMField(label: "H", value: sizeBinding(si).height, range: sizeLimit)
                    }
                }
            }
            Text("Pose of component").font(.subheadline.weight(.semibold))
            Picker("Component", selection: $selectedComponent) {
                Text("Choose…").tag(UUID?.none)
                ForEach(def.components) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            if let cid = selectedComponent, let c = def.components.first(where: { $0.id == cid }) {
                poseEditor(si, c)
            }
        }
    }

    private func sizeBinding(_ si: Int) -> Binding<Size3> {
        Binding(get: { def.states[si].size ?? def.size }, set: { def.states[si].size = $0 })
    }

    @ViewBuilder private func poseEditor(_ si: Int, _ c: Component) -> some View {
        let pose = Binding<ComponentPose>(
            get: { def.states[si].poses[c.id] ?? ComponentPose() },
            set: { new in
                let empty = new.position == nil && new.rotation == nil && new.size == nil && new.visible == nil
                def.states[si].poses[c.id] = empty ? nil : new
            })
        Toggle("Override position", isOn: Binding(
            get: { pose.wrappedValue.position != nil },
            set: { pose.wrappedValue.position = $0 ? c.position : nil }))
        if pose.wrappedValue.position != nil {
            P3Fields(title: "Position (mm)", value: Binding(get: { pose.wrappedValue.position ?? c.position }, set: { pose.wrappedValue.position = $0 }))
        }
        Toggle("Override rotation", isOn: Binding(
            get: { pose.wrappedValue.rotation != nil },
            set: { pose.wrappedValue.rotation = $0 ? c.rotation : nil }))
        if pose.wrappedValue.rotation != nil {
            R3Fields(title: "Rotation (°)", value: Binding(get: { pose.wrappedValue.rotation ?? c.rotation }, set: { pose.wrappedValue.rotation = $0 }))
            Text(c.pivot == nil ? "Rotates around the component centre. Set a custom pivot in the Components tab to swing it around an edge."
                 : "Rotates around the component's custom pivot.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Picker("Visibility", selection: Binding(
            get: { pose.wrappedValue.visible },
            set: { pose.wrappedValue.visible = $0 })) {
            Text("Inherit").tag(Bool?.none)
            Text("Shown").tag(Bool?.some(true))
            Text("Hidden").tag(Bool?.some(false))
        }
        Button("Reset Pose of This Component") { pose.wrappedValue = ComponentPose() }
            .disabled(def.states[si].poses[c.id] == nil)
    }

    // MARK: Tracks

    private var tracksSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Animation").font(.headline)
            if def.states.count < 2 {
                Text("Add at least two states to define an animation between them.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach($def.tracks) { $t in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(name(t.fromStateId)) → \(name(t.toStateId))").lineLimit(1)
                        Spacer()
                        Button { def.tracks.removeAll { $0.id == t.id } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Delete animation")
                            .accessibilityLabel("Delete animation \(name(t.fromStateId)) to \(name(t.toStateId))")
                    }
                    HStack {
                        CommitField(title: "Duration in ms", value: t.durationMs, format: { String($0) },
                                    parse: { s in Int(s.trimmingCharacters(in: .whitespaces)).flatMap { (0...60_000).contains($0) ? $0 : nil } },
                                    onCommit: { $t.durationMs.wrappedValue = $0; return true })
                            .frame(width: 70)
                        Text("ms").font(.caption).foregroundStyle(.secondary)
                        Picker("Easing", selection: $t.easing) {
                            ForEach(Easing.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.labelsHidden()
                    }
                }
                .padding(6).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
            if def.states.count >= 2 {
                HStack {
                    Picker("From", selection: $trackFrom) {
                        ForEach(def.states) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    Picker("To", selection: $trackTo) {
                        ForEach(def.states) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                }
                Button("Add Animation") { addTrack() }
                    .disabled(trackFrom == nil || trackTo == nil || trackFrom == trackTo)
            }
        }
        .onAppear { seedTrackPickers() }
    }

    private func name(_ id: UUID?) -> String {
        guard let id else { return "Any" }
        return def.states.first { $0.id == id }?.name ?? "?"
    }

    private func seedTrackPickers() {
        if trackFrom == nil { trackFrom = def.states.first?.id }
        if trackTo == nil { trackTo = def.states.dropFirst().first?.id }
    }

    private func addTrack() {
        guard let f = trackFrom, let t = trackTo, f != t else { return }
        def.tracks.removeAll { $0.fromStateId == f && $0.toStateId == t }
        def.tracks.append(AnimationTrack(fromStateId: f, toStateId: t, durationMs: 800, easing: .easeInOut))
    }
}
