import SwiftUI
import RoomsmithCore

struct InspectorGroupView: View {
    @Environment(AppModel.self) private var model
    @State private var productSheet = false
    @State private var newConfigName = ""
    @State private var renaming: GroupConfiguration?
    @State private var renameText = ""
    let id: UUID

    var body: some View {
        let p = model.project
        if let g = p.group(id) {
            let u = model.unit
            let locked = p.isLocked(id)
            Form {
                Section("Group") {
                    Group {
                        LabeledContent("Name") { NameField(title: "Group name", value: g.name) { model.rename(id, to: $0) } }
                        LabeledContent("X") { LengthField(title: "Origin x", value: g.origin.x, unit: u) { v in moveOrigin(g, dx: v - g.origin.x, dy: 0, dz: 0) } }
                        LabeledContent("Y") { LengthField(title: "Origin y", value: g.origin.y, unit: u) { v in moveOrigin(g, dx: 0, dy: v - g.origin.y, dz: 0) } }
                        LabeledContent("Z") { LengthField(title: "Origin z", value: g.origin.z, unit: u) { v in moveOrigin(g, dx: 0, dy: 0, dz: v - g.origin.z) } }
                        LabeledContent("Rotation") {
                            AngleField(title: "Group rotation", value: g.rotationDeg) { v in
                                let delta = v - g.rotationDeg
                                return model.perform("Rotate Group") { try $0.rotateObjects([id], by: delta, pivot: g.origin.xy) }
                            }
                        }
                    }
                    .disabled(locked)
                    Toggle("Locked", isOn: Binding(get: { g.locked }, set: { v in model.perform(v ? "Lock" : "Unlock") { try $0.setLocked([id], v) } }))
                }
                Section("Members (\(g.memberIds.count))") {
                    ForEach(g.memberIds, id: \.self) { mid in
                        Button { model.selection = [mid] } label: {
                            HStack { Image(systemName: "chair.lounge"); Text(p.displayName(of: mid)); Spacer() }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section("Configurations") {
                    if g.configurations.isEmpty { Text("No saved configurations").foregroundStyle(.secondary) }
                    ForEach(g.configurations) { c in
                        HStack {
                            Image(systemName: c.id == g.activeConfigurationId ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(c.id == g.activeConfigurationId ? Color.accentColor : Color.secondary)
                            Text(c.name).fontWeight(c.id == g.activeConfigurationId ? .semibold : .regular)
                            Spacer()
                            Button("Activate") {
                                model.perform("Activate Configuration") { try $0.activateConfiguration(groupId: id, configurationId: c.id) }
                            }
                            .controlSize(.small)
                            .disabled(locked || c.id == g.activeConfigurationId)
                            Menu {
                                Button("Overwrite with Current Layout") {
                                    model.perform("Overwrite Configuration") { try $0.saveConfiguration(groupId: id, name: c.name) }
                                }
                                Button("Rename…") { renaming = c; renameText = c.name }
                                Button("Duplicate") { duplicate(c, in: g) }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    model.perform("Delete Configuration") { try $0.deleteConfiguration(groupId: id, configurationId: c.id) }
                                }
                            } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).fixedSize()
                            .help("Configuration actions")
                            .accessibilityLabel("Actions for configuration \(c.name)")
                            .disabled(locked)
                        }
                    }
                    HStack {
                        TextField("New configuration name", text: $newConfigName)
                        Button("Save Current") {
                            let n = newConfigName.trimmingCharacters(in: .whitespaces)
                            if model.perform("Save Configuration", { try $0.saveConfiguration(groupId: id, name: n) }) { newConfigName = "" }
                        }
                        .controlSize(.small)
                        .disabled(locked || newConfigName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                InspectorProductSection(objectId: id, productId: g.productId, productSheet: $productSheet)
                CollisionSection(ids: [id])
            }
            .formStyle(.grouped)
            .sheet(isPresented: $productSheet) { ProductEditorSheet(objectId: id) }
            .alert("Rename Configuration", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $renameText)
                Button("Rename") { if let c = renaming { rename(c, in: g) } }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
        }
    }

    private func moveOrigin(_ g: FurnitureGroup, dx: MM, dy: MM, dz: MM) -> Bool {
        model.perform("Move Group") { try $0.moveObjects([id], by: P3(dx, dy, dz)) }
    }

    private func uniqueName(_ base: String, in g: FurnitureGroup) -> String {
        var n = base, k = 2
        while g.configurations.contains(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) { n = "\(base) \(k)"; k += 1 }
        return n
    }

    private func duplicate(_ c: GroupConfiguration, in g: FurnitureGroup) {
        let name = uniqueName("\(c.name) copy", in: g)
        model.perform("Duplicate Configuration") { p in
            try p.ensureEditable(id)
            try p.modify(\.groups, id, "Group") { $0.configurations.append(GroupConfiguration(name: name, poses: c.poses)) }
        }
    }

    private func rename(_ c: GroupConfiguration, in g: FurnitureGroup) {
        let n = renameText.trimmingCharacters(in: .whitespaces)
        renaming = nil
        guard !n.isEmpty, n != c.name else { return }
        model.perform("Rename Configuration") { p in
            try p.ensureEditable(id)
            if p.group(id)?.configurations.contains(where: { $0.id != c.id && $0.name.caseInsensitiveCompare(n) == .orderedSame }) == true {
                throw CommandError.invalid("A configuration named “\(n)” already exists", ids: [id])
            }
            try p.modify(\.groups, id, "Group") { gr in
                if let k = gr.configurations.firstIndex(where: { $0.id == c.id }) { gr.configurations[k].name = n }
            }
        }
    }
}
