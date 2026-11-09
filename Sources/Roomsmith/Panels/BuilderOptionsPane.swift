import SwiftUI
import RoomsmithCore

/// Options tab: option groups (colour, front, handle) with choices; each choice sets the material and/or visibility of parts.
struct BuilderOptionsPane: View {
    @Binding var def: FurnitureDefinition
    let materials: [RoomsmithCore.Material]

    @State private var groupId: UUID?
    @State private var choiceId: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                groupsSection
                if let gi = groupIndex {
                    Divider()
                    groupEditor(gi)
                    if let ci = choiceIndex(gi) {
                        Divider()
                        effectsEditor(gi, ci)
                    }
                }
            }
            .padding(10)
        }
        .onAppear { if groupId == nil { groupId = def.optionGroups.first?.id } }
    }

    private var groupIndex: Int? { def.optionGroups.firstIndex { $0.id == groupId } }

    private func choiceIndex(_ gi: Int) -> Int? { def.optionGroups[gi].choices.firstIndex { $0.id == choiceId } }

    // MARK: Groups

    private var groupsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Options").font(.headline)
            Text("A choice changes the material or visibility of parts. Size and pose stay the same; use States for movement.")
                .font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(def.optionGroups) { g in
                    HStack {
                        Image(systemName: groupId == g.id ? "largecircle.fill.circle" : "circle")
                        Text(g.name)
                        Spacer()
                        Text("\(g.choices.count)").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(groupId == g.id ? Color.accentColor.opacity(0.15) : .clear)
                    .contentShape(Rectangle())
                    .onTapGesture { select(g) }
                    .focusable()
                    .onKeyPress(.space) { select(g); return .handled }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(groupId == g.id ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { select(g) }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Button("Add Group") { addGroup() }
                    .disabled(def.optionGroups.count >= OptionGroup.maxPerDefinition)
                Button("Delete") { deleteGroup() }.disabled(groupId == nil)
            }
        }
    }

    private func select(_ g: OptionGroup) {
        groupId = g.id
        choiceId = g.choices.first?.id
    }

    private func addGroup() {
        let a = OptionChoice(name: "Choice 1"), b = OptionChoice(name: "Choice 2")
        let g = OptionGroup(name: BuilderSupport.uniqueGroupName("Option", in: def), choices: [a, b])
        def.optionGroups.append(g)
        groupId = g.id
        choiceId = a.id
    }

    private func deleteGroup() {
        guard let gid = groupId else { return }
        def.optionGroups.removeAll { $0.id == gid }
        groupId = def.optionGroups.first?.id
        choiceId = def.optionGroups.first?.choices.first?.id
    }

    // MARK: Group editor

    @ViewBuilder private func groupEditor(_ gi: Int) -> some View {
        let g = def.optionGroups[gi]
        VStack(alignment: .leading, spacing: 8) {
            TextField("Group name", text: $def.optionGroups[gi].name).textFieldStyle(.roundedBorder)
            Text("Choices").font(.subheadline.weight(.semibold))
            VStack(spacing: 0) {
                ForEach(g.choices) { c in
                    HStack {
                        Image(systemName: choiceId == c.id ? "largecircle.fill.circle" : "circle")
                        Text(c.name)
                        Spacer()
                        if g.effectiveChoice(selected: nil)?.id == c.id { Text("Default").font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(choiceId == c.id ? Color.accentColor.opacity(0.15) : .clear)
                    .contentShape(Rectangle())
                    .onTapGesture { choiceId = c.id }
                    .focusable()
                    .onKeyPress(.space) { choiceId = c.id; return .handled }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(choiceId == c.id ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { choiceId = c.id }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Button("Add Choice") { addChoice(gi) }
                    .disabled(g.choices.count >= OptionGroup.maxChoices)
                Button("Delete") { deleteChoice(gi) }
                    .disabled(choiceIndex(gi) == nil || g.choices.count <= 1)
            }
            if let ci = choiceIndex(gi) {
                TextField("Choice name", text: $def.optionGroups[gi].choices[ci].name).textFieldStyle(.roundedBorder)
                Toggle("Default choice", isOn: Binding(
                    get: { g.effectiveChoice(selected: nil)?.id == g.choices[ci].id },
                    set: { if $0 { def.optionGroups[gi].defaultChoiceId = g.choices[ci].id } }))
                    .disabled(g.effectiveChoice(selected: nil)?.id == g.choices[ci].id)
            }
        }
    }

    private func addChoice(_ gi: Int) {
        let c = OptionChoice(name: BuilderSupport.uniqueChoiceName("Choice", in: def.optionGroups[gi]))
        def.optionGroups[gi].choices.append(c)
        choiceId = c.id
    }

    private func deleteChoice(_ gi: Int) {
        guard let cid = choiceId, def.optionGroups[gi].choices.count > 1 else { return }
        def.optionGroups[gi].choices.removeAll { $0.id == cid }
        if def.optionGroups[gi].defaultChoiceId == cid { def.optionGroups[gi].defaultChoiceId = nil }
        choiceId = def.optionGroups[gi].choices.first?.id
    }

    // MARK: Effects

    @ViewBuilder private func effectsEditor(_ gi: Int, _ ci: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Effect of this choice").font(.subheadline.weight(.semibold))
            if def.components.isEmpty {
                Text("Add components first.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(def.components) { c in
                let e = def.optionGroups[gi].choices[ci].effects[c.id] ?? OptionEffect()
                VStack(alignment: .leading, spacing: 4) {
                    Text(c.name).font(.callout)
                    MaterialPicker(title: "Material", materials: materials, selection: e.materialId, defaultLabel: "No change") { m in
                        update(gi, ci, c.id) { $0.materialId = m }
                    }
                    Picker("Visibility", selection: Binding(get: { e.visible }, set: { v in update(gi, ci, c.id) { $0.visible = v } })) {
                        Text("No change").tag(Bool?.none)
                        Text("Shown").tag(Bool?.some(true))
                        Text("Hidden").tag(Bool?.some(false))
                    }
                }
                .padding(6).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func update(_ gi: Int, _ ci: Int, _ cid: UUID, _ change: (inout OptionEffect) -> Void) {
        var e = def.optionGroups[gi].choices[ci].effects[cid] ?? OptionEffect()
        change(&e)
        def.optionGroups[gi].choices[ci].effects[cid] = e.isEmpty ? nil : e
    }
}
