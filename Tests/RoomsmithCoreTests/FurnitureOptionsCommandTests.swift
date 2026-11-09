import Foundation
import Testing
@testable import RoomsmithCore

// Furniture options: commands with undo, cleanup, copy/paste/duplicate, file and library round trips.

/// A project with one wardrobe design (body, two doors, handle), four project materials and two placed pieces.
@MainActor
private struct OptionLab {
    let store: DocumentStore
    let level: UUID
    let defId: UUID
    let body: UUID, doorA: UUID, doorB: UUID, handle: UUID
    let white = UUID(), oak = UUID(), black = UUID(), steel = UUID()
    var first = UUID(), second = UUID()
    var colourId = UUID(), whiteChoice = UUID(), oakChoice = UUID()
    var doorId = UUID(), plainChoice = UUID(), glassChoice = UUID()

    init(withGroups: Bool = true) throws {
        store = DocumentStore(project: Project.empty(name: "Options"))
        level = store.project.levels[0].id
        let b = Component(name: "body", shape: .box, position: P3(0, 0, 1000), size: Size3(1000, 580, 2000))
        let a = Component(name: "door plain", shape: .box, position: P3(0, -300, 1000), size: Size3(1000, 20, 2000))
        let g = Component(name: "door glass", shape: .box, position: P3(0, -300, 1000), size: Size3(1000, 20, 2000))
        let h = Component(name: "handle", shape: .cylinder, position: P3(400, -330, 1000), size: Size3(20, 20, 200))
        body = b.id; doorA = a.id; doorB = g.id; handle = h.id
        var def = FurnitureDefinition(name: "Wardrobe", category: "Storage", size: Size3(1000, 580, 2000), components: [b, a, g, h])
        defId = def.id
        if withGroups {
            def.optionGroups = [
                OptionGroup(id: colourId, name: "Colour", choices: [
                    OptionChoice(id: whiteChoice, name: "White", effects: [b.id: OptionEffect(materialId: white), a.id: OptionEffect(materialId: white)]),
                    OptionChoice(id: oakChoice, name: "Oak", effects: [b.id: OptionEffect(materialId: oak), a.id: OptionEffect(materialId: oak)]),
                ]),
                OptionGroup(id: doorId, name: "Door", choices: [
                    OptionChoice(id: plainChoice, name: "Plain", effects: [a.id: OptionEffect(visible: true), g.id: OptionEffect(visible: false)]),
                    OptionChoice(id: glassChoice, name: "Glass", effects: [a.id: OptionEffect(visible: false), g.id: OptionEffect(visible: true)]),
                ]),
            ]
        }
        let lv = level
        var f = UUID(), s = UUID()
        try store.run("Build") { p in
            for (id, name) in [(white, "White"), (oak, "Oak"), (black, "Black"), (steel, "Steel")] {
                p.addMaterial(Material(id: id, name: name, color: RGBColor(10, 20, 30)))
            }
            p.addDefinition(def)
            f = try p.addInstance(definitionId: def.id, levelId: lv, position: P3(1000, 1000, 0))
            s = try p.addInstance(definitionId: def.id, levelId: lv, position: P3(3000, 1000, 0))
        }
        first = f; second = s
    }

    var project: Project { store.project }
    var def: FurnitureDefinition { store.project.definition(defId)! }
    func selection(_ id: UUID) -> [UUID: UUID] { store.project.instance(id)!.optionSelection }
    func materialName(_ inst: UUID, _ comp: UUID) -> String? {
        let i = store.project.instance(inst)!
        let r = FurnitureResolver.resolve(i, definition: store.project.definition(i.definitionId)!)
        return r.first { $0.componentId == comp }?.materialId.flatMap { store.project.material($0)?.name }
    }
}

/// Whole-project check: every definition and instance passes the validator, as if all of them had just changed.
private func valid(_ p: Project) -> Bool {
    var cs = ChangeSet()
    for d in p.definitions { cs.objects.append(ObjectChange(id: d.id, kind: .definition, op: .modified)) }
    for i in p.instances { cs.objects.append(ObjectChange(id: i.id, kind: .furniture, op: .modified)) }
    return (try? Validator.validate(p, changes: cs)) != nil
}

@MainActor
struct FurnitureOptionsCommandTests {
    // MARK: defineOptionGroup / deleteOptionGroup

    @Test func defineAddsAGroupAndUndoRemovesIt() throws {
        let lab = try OptionLab(withGroups: false)
        let g = OptionGroup(name: "Colour", choices: [OptionChoice(name: "White", effects: [lab.body: OptionEffect(materialId: lab.white)])])
        var gid = UUID()
        try lab.store.run("Define") { gid = try $0.defineOptionGroup(definitionId: lab.defId, g) }
        #expect(gid == g.id)
        #expect(lab.def.optionGroups.map(\.name) == ["Colour"])
        try lab.store.undo()
        #expect(lab.def.optionGroups.isEmpty)
        try lab.store.redo()
        #expect(lab.def.optionGroups.map(\.id) == [g.id])
    }

    @Test func redefiningByNameKeepsGroupAndChoiceIdsSoSelectionsSurvive() throws {
        let lab = try OptionLab()
        try lab.store.run("Select") { try $0.setOptions([lab.first, lab.second], select: [lab.colourId: lab.oakChoice]) }
        // Same name, fresh ids; "Oak" keeps its id by name, "Ash" is new, "White" is gone.
        let again = OptionGroup(name: "colour", choices: [
            OptionChoice(name: "OAK", effects: [lab.body: OptionEffect(materialId: lab.black)]),
            OptionChoice(name: "Ash", effects: [lab.body: OptionEffect(materialId: lab.steel)]),
        ])
        var gid = UUID()
        try lab.store.run("Redefine") { gid = try $0.defineOptionGroup(definitionId: lab.defId, again) }
        #expect(gid == lab.colourId)
        #expect(lab.def.optionGroups.count == 2)
        let g = try #require(lab.def.optionGroups.first { $0.id == gid })
        #expect(g.choices.first?.id == lab.oakChoice)
        #expect(lab.selection(lab.first) == [lab.colourId: lab.oakChoice])
        #expect(lab.materialName(lab.first, lab.body) == "Black")
        // Dropping the selected choice drops the selection.
        let onlyAsh = OptionGroup(name: "Colour", choices: [OptionChoice(name: "Ash", effects: [lab.body: OptionEffect(materialId: lab.steel)])])
        try lab.store.run("Drop choice") { _ = try $0.defineOptionGroup(definitionId: lab.defId, onlyAsh) }
        #expect(lab.selection(lab.first).isEmpty && lab.selection(lab.second).isEmpty)
        try lab.store.undo()
        #expect(lab.selection(lab.first) == [lab.colourId: lab.oakChoice], "undo brings the selection back")
    }

    @Test func defineRejectsUnknownPartsMaterialsAndBadGroups() throws {
        let lab = try OptionLab(withGroups: false)
        let before = lab.project
        let ghostPart = OptionGroup(name: "X", choices: [OptionChoice(name: "a", effects: [UUID(): OptionEffect(materialId: lab.white)])])
        let ghostMat = OptionGroup(name: "X", choices: [OptionChoice(name: "a", effects: [lab.body: OptionEffect(materialId: UUID())])])
        let empty = OptionGroup(name: "X", choices: [])
        let dupe = OptionGroup(name: "X", choices: [OptionChoice(name: "a"), OptionChoice(name: "A")])
        for g in [ghostPart, ghostMat, empty, dupe] {
            #expect(throws: CommandError.self) { try lab.store.run("Bad") { _ = try $0.defineOptionGroup(definitionId: lab.defId, g) } }
        }
        #expect(throws: CommandError.self) { try lab.store.run("No def") { _ = try $0.defineOptionGroup(definitionId: UUID(), OptionGroup(name: "X", choices: [OptionChoice(name: "a")])) } }
        #expect(lab.project == before, "failed commands change nothing")
    }

    @Test func deleteGroupForgetsSelectionsAndUndoRestores() throws {
        let lab = try OptionLab()
        try lab.store.run("Select") { try $0.setOptions([lab.first], select: [lab.colourId: lab.oakChoice, lab.doorId: lab.glassChoice]) }
        try lab.store.run("Delete") { try $0.deleteOptionGroup(definitionId: lab.defId, groupId: lab.colourId) }
        #expect(lab.def.optionGroups.map(\.id) == [lab.doorId])
        #expect(lab.selection(lab.first) == [lab.doorId: lab.glassChoice])
        #expect(throws: CommandError.self) { try lab.store.run("Again") { try $0.deleteOptionGroup(definitionId: lab.defId, groupId: lab.colourId) } }
        try lab.store.undo()
        #expect(lab.def.optionGroups.count == 2)
        #expect(lab.selection(lab.first) == [lab.colourId: lab.oakChoice, lab.doorId: lab.glassChoice])
    }

    // MARK: setOptions

    @Test func setOptionsSelectsResetsAndIsOneUndoStep() throws {
        let lab = try OptionLab()
        #expect(lab.materialName(lab.first, lab.body) == "White", "default is the first choice")
        try lab.store.run("Select") { try $0.setOptions([lab.first, lab.second], select: [lab.colourId: lab.oakChoice]) }
        #expect(lab.materialName(lab.first, lab.body) == "Oak" && lab.materialName(lab.second, lab.body) == "Oak")
        try lab.store.run("Reset") { try $0.setOptions([lab.second], select: [:], reset: [lab.colourId]) }
        #expect(lab.selection(lab.second).isEmpty && lab.materialName(lab.second, lab.body) == "White")
        #expect(lab.materialName(lab.first, lab.body) == "Oak")
        try lab.store.undo()
        #expect(lab.selection(lab.second) == [lab.colourId: lab.oakChoice])
        try lab.store.undo()
        #expect(lab.selection(lab.first).isEmpty && lab.selection(lab.second).isEmpty)
        try lab.store.redo()
        #expect(lab.selection(lab.first) == [lab.colourId: lab.oakChoice])
    }

    @Test func setOptionsClearsOverridesOfTheColouredPartsOnly() throws {
        let lab = try OptionLab()
        try lab.store.run("Overrides") { p in
            try p.updateInstance(lab.first) { $0.materialOverrides = [lab.body: lab.steel, lab.handle: lab.black] }
        }
        #expect(lab.materialName(lab.first, lab.body) == "Steel", "override beats the option")
        try lab.store.run("Select") { try $0.setOptions([lab.first], select: [lab.colourId: lab.oakChoice]) }
        #expect(lab.materialName(lab.first, lab.body) == "Oak")
        #expect(lab.project.instance(lab.first)?.materialOverrides == [lab.handle: lab.black], "the handle is no part of the group")
        // The door group sets no material: it leaves overrides alone.
        try lab.store.run("Override again") { try $0.updateInstance(lab.first) { $0.materialOverrides[lab.body] = lab.steel } }
        try lab.store.run("Door") { try $0.setOptions([lab.first], select: [lab.doorId: lab.glassChoice]) }
        #expect(lab.project.instance(lab.first)?.materialOverrides[lab.body] == lab.steel)
    }

    @Test func setOptionsRejectsForeignGroupsChoicesAndChangesNothing() throws {
        let lab = try OptionLab()
        let before = lab.project
        #expect(throws: CommandError.self) { try lab.store.run("Foreign group") { try $0.setOptions([lab.first], select: [UUID(): lab.oakChoice]) } }
        #expect(throws: CommandError.self) { try lab.store.run("Foreign choice") { try $0.setOptions([lab.first], select: [lab.colourId: UUID()]) } }
        #expect(throws: CommandError.self) { try lab.store.run("Other group's choice") { try $0.setOptions([lab.first], select: [lab.colourId: lab.glassChoice]) } }
        #expect(throws: CommandError.self) { try lab.store.run("Reset foreign") { try $0.setOptions([lab.first], select: [:], reset: [UUID()]) } }
        #expect(throws: CommandError.self) { try lab.store.run("Not furniture") { try $0.setOptions([UUID()], select: [lab.colourId: lab.oakChoice]) } }
        // One bad piece rejects the whole call: a piece of a design without these groups.
        var plain = UUID()
        try lab.store.run("Other design") { p in
            let d = p.addDefinition(FurnitureDefinition(name: "Box", category: "x", size: Size3(100, 100, 100),
                                                        components: [Component(name: "b", shape: .box, position: P3(0, 0, 50), size: Size3(100, 100, 100))]))
            plain = try p.addInstance(definitionId: d, levelId: lab.level, position: P3(0, 0, 0))
        }
        let mid = lab.project
        #expect(throws: CommandError.self) { try lab.store.run("Mixed") { try $0.setOptions([lab.first, plain], select: [lab.colourId: lab.oakChoice]) } }
        #expect(lab.project == mid)
        #expect(before.instance(lab.first) == lab.project.instance(lab.first))
    }

    @Test func lockedFurnitureCannotChangeItsOptions() throws {
        let lab = try OptionLab()
        try lab.store.run("Lock") { try $0.updateInstance(lab.first) { $0.locked = true } }
        #expect(throws: CommandError.self) { try lab.store.run("Select") { try $0.setOptions([lab.first], select: [lab.colourId: lab.oakChoice]) } }
        #expect(lab.selection(lab.first).isEmpty)
    }

    // MARK: Cleanup

    @Test func deletingAMaterialDropsItFromOptionEffectsButKeepsTheChoice() throws {
        let lab = try OptionLab()
        try lab.store.run("Delete oak") { try $0.deleteObjects([lab.oak]) }
        let oak = try #require(lab.def.optionGroups.first { $0.id == lab.colourId }?.choices.first { $0.id == lab.oakChoice })
        #expect(oak.effects.isEmpty, "effects that only set the deleted material are gone")
        #expect(lab.def.optionGroups.first { $0.id == lab.doorId }?.choices.count == 2)
        #expect(valid(lab.project))
        try lab.store.undo()
        #expect(lab.def.optionGroups.first { $0.id == lab.colourId }?.choices[1].effects[lab.body]?.materialId == lab.oak)
    }

    @Test func removingAPartDropsItsEffectsAndRepairsTheDefault() throws {
        let lab = try OptionLab()
        try lab.store.run("Select") { try $0.setOptions([lab.first], select: [lab.doorId: lab.glassChoice]) }
        try lab.store.run("Remove door B") { p in
            try p.updateDefinition(lab.defId) { $0.components.removeAll { $0.id == lab.doorB } }
        }
        for g in lab.def.optionGroups { for c in g.choices { #expect(c.effects[lab.doorB] == nil) } }
        #expect(lab.selection(lab.first) == [lab.doorId: lab.glassChoice], "the choice itself stays")
        #expect(valid(lab.project))
        // A default that points at a removed choice falls back.
        try lab.store.run("Default") { p in try p.updateDefinition(lab.defId) { $0.optionGroups[1].defaultChoiceId = lab.glassChoice } }
        try lab.store.run("Drop glass") { p in try p.updateDefinition(lab.defId) { $0.optionGroups[1].choices.removeAll { $0.id == lab.glassChoice } } }
        #expect(lab.def.optionGroups[1].defaultChoiceId == nil)
        #expect(lab.selection(lab.first).isEmpty)
        #expect(valid(lab.project))
    }

    @Test func referencesNameOptionMaterials() throws {
        let lab = try OptionLab()
        let refs = lab.project.references(to: lab.oak)
        #expect(refs.contains { $0.id == lab.defId && $0.role == "option material" })
    }

    // MARK: Duplicate, copy, paste

    @Test func duplicateCarriesTheSelection() throws {
        let lab = try OptionLab()
        try lab.store.run("Select") { try $0.setOptions([lab.first], select: [lab.colourId: lab.oakChoice, lab.doorId: lab.glassChoice]) }
        var map: [UUID: UUID] = [:]
        try lab.store.run("Duplicate") { map = try $0.duplicateObjects([lab.first]) }
        let copy = try #require(map[lab.first])
        #expect(lab.selection(copy) == [lab.colourId: lab.oakChoice, lab.doorId: lab.glassChoice])
        #expect(lab.materialName(copy, lab.body) == "Oak")
        #expect(valid(lab.project))
    }

    @Test func copyToAnotherProjectRemapsGroupsChoicesAndMaterials() throws {
        let lab = try OptionLab()
        try lab.store.run("Select") { try $0.setOptions([lab.first], select: [lab.colourId: lab.oakChoice, lab.doorId: lab.glassChoice]) }
        let target = DocumentStore(project: Project.empty(name: "Target"))
        let out = try FurnitureTransferService.copy(ids: [lab.first], from: lab.store, sourcePackage: nil, to: target, targetPackage: nil,
                                                    levelId: target.project.levels[0].id)
        let p = target.project
        let inst = try #require(p.instance(out.newIds[0]))
        let def = try #require(p.definition(inst.definitionId))
        #expect(def.optionGroups.count == 2)
        let ids = Set(def.optionGroups.map(\.id)).union(def.optionGroups.flatMap { $0.choices.map(\.id) })
        #expect(ids.isDisjoint(with: [lab.colourId, lab.doorId, lab.oakChoice, lab.glassChoice, lab.whiteChoice, lab.plainChoice]), "fresh ids")
        #expect(inst.optionSelection.count == 2)
        let colour = try #require(def.optionGroups.first { $0.name == "Colour" })
        let door = try #require(def.optionGroups.first { $0.name == "Door" })
        #expect(colour.choices.first { $0.id == inst.optionSelection[colour.id] }?.name == "Oak")
        #expect(door.choices.first { $0.id == inst.optionSelection[door.id] }?.name == "Glass")
        // Effects point at the new parts and at materials that exist in the target (the white one travels too).
        let comps = Set(def.components.map(\.id))
        for g in def.optionGroups { for c in g.choices { for (k, e) in c.effects {
            #expect(comps.contains(k))
            if let m = e.materialId { #expect(p.material(m) != nil) }
        } } }
        #expect(p.materials.map(\.name).sorted() == ["Oak", "White"])
        #expect(valid(p))
        let r = FurnitureResolver.resolve(inst, definition: def)
        #expect(r.first { $0.name == "body" }.flatMap { $0.materialId }.flatMap { p.material($0)?.name } == "Oak")
        #expect(r.first { $0.name == "door glass" }?.visible == true && r.first { $0.name == "door plain" }?.visible == false)
        // Undo of the paste leaves nothing behind.
        try target.undo()
        #expect(target.project.definitions.isEmpty && target.project.instances.isEmpty)
    }

    @Test func transferWithoutOptionKeysStillDecodes() throws {
        let lab = try OptionLab(withGroups: false)
        let t = try FurnitureTransfer.make(from: lab.project, ids: [lab.first], packageURL: nil)
        let data = try JSONEncoder().encode(t)
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var insts = try #require(obj["instances"] as? [[String: Any]])
        for i in insts.indices { insts[i].removeValue(forKey: "optionSelection") }
        obj["instances"] = insts
        var defs = try #require(obj["definitions"] as? [[String: Any]])
        for i in defs.indices { defs[i].removeValue(forKey: "optionGroups") }
        obj["definitions"] = defs
        let old = try JSONDecoder().decode(FurnitureTransfer.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(old.instances[0].optionSelection.isEmpty && old.definitions[0].optionGroups.isEmpty)
    }

    // MARK: File and library

    @Test func markdownRoundTripKeepsGroupsChoicesEffectsAndSelections() throws {
        let lab = try OptionLab()
        try lab.store.run("Defaults") { p in
            try p.updateDefinition(lab.defId) { $0.optionGroups[0].defaultChoiceId = lab.oakChoice }
            try p.setOptions([lab.first], select: [lab.doorId: lab.glassChoice, lab.colourId: lab.whiteChoice])
        }
        let text = RoomsmithMarkdown.encode(lab.project)
        #expect(text.contains("schema: \(Project.currentSchemaVersion)") && Project.currentSchemaVersion == 5)
        #expect(text.contains("Options") && text.contains("| options |"))
        let (q, warnings) = try RoomsmithMarkdown.decode(text)
        #expect(warnings.isEmpty, "\(warnings)")
        #expect(q == lab.project)
        #expect(q.definition(lab.defId)?.optionGroups.map(\.name) == ["Colour", "Door"])
        #expect(q.instance(lab.first)?.optionSelection == [lab.doorId: lab.glassChoice, lab.colourId: lab.whiteChoice])
        #expect(RoomsmithMarkdown.encode(q) == text, "encoding is stable")
    }

    @Test func projectsWithoutOptionsWriteNoOptionsTable() throws {
        let lab = try OptionLab(withGroups: false)
        let text = RoomsmithMarkdown.encode(lab.project)
        #expect(!text.contains("#### Options"))
        let (q, warnings) = try RoomsmithMarkdown.decode(text)
        #expect(warnings.isEmpty, "\(warnings)")
        #expect(q == lab.project)
    }

    @Test func schema4FileWithoutOptionColumnLoadsAndMigrates() throws {
        let lab = try OptionLab(withGroups: false)
        var lines = RoomsmithMarkdown.encode(lab.project).components(separatedBy: "\n")
        lines = lines.map { $0.hasPrefix("schema:") ? "schema: 4" : $0 }
        // Cut the `options` column out of the Instances table, as a schema 4 writer would have.
        if let h = lines.firstIndex(where: { $0.contains("| allowsOverlap |") && $0.contains("| options |") }) {
            let column = try #require(lines[h].components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }.firstIndex(of: "options"))
            func cut(_ s: String) -> String {
                var c = s.components(separatedBy: "|")
                c.remove(at: column)
                return c.joined(separator: "|")
            }
            var i = h
            while i < lines.count, lines[i].hasPrefix("|") { lines[i] = cut(lines[i]); i += 1 }
        }
        let (q, warnings) = try RoomsmithMarkdown.decode(lines.joined(separator: "\n"))
        #expect(warnings.contains { $0.hasPrefix("migrated:") })
        #expect(q.instances.count == 2 && q.instances.allSatisfy { $0.optionSelection.isEmpty })
    }

    @Test func packageSaveAndLoadKeepsOptions() throws {
        let lab = try OptionLab()
        try lab.store.run("Select") { try $0.setOptions([lab.second], select: [lab.colourId: lab.oakChoice]) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rs-opt-\(UUID().uuidString).roomsmith")
        defer { try? FileManager.default.removeItem(at: dir) }
        try ProjectPackage.save(lab.project, to: dir)
        let loaded = try ProjectPackage.load(from: dir)
        #expect(loaded.project.instance(lab.second)?.optionSelection == [lab.colourId: lab.oakChoice])
        #expect(loaded.project.definition(lab.defId)?.optionGroups == lab.def.optionGroups)
    }

    @Test func libraryEntryKeepsOptionsAndPlacesWithTheSelection() throws {
        let lab = try OptionLab()
        try lab.store.run("Select") { try $0.setOptions([lab.first], select: [lab.colourId: lab.oakChoice]) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rs-optlib-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = LibraryStore(root: root)
        let entry = try LibraryContent.save(project: lab.project, ids: [lab.first], packageURL: nil, into: lib)
        #expect(entry.materialNames.contains("Oak") && entry.materialNames.contains("White"), "option colours are listed: \(entry.materialNames)")
        // A fresh store (a new app launch) reads the same data; the index format stays 1.
        let again = LibraryStore(root: root)
        let t = try again.transfer(for: entry.id)
        #expect(t.definitions[0].optionGroups == lab.def.optionGroups)
        #expect(t.instances[0].optionSelection == [lab.colourId: lab.oakChoice])
        #expect(LibraryIndex.currentVersion == 1)

        let target = DocumentStore(project: Project.empty(name: "Target"))
        let ids = try LibraryPlacement.place(entry.id, from: again, into: target, targetPackage: nil, levelId: target.project.levels[0].id, at: P2(0, 0))
        let inst = try #require(target.project.instance(ids[0]))
        let def = try #require(target.project.definition(inst.definitionId))
        let colour = try #require(def.optionGroups.first { $0.name == "Colour" })
        #expect(colour.choices.first { $0.id == inst.optionSelection[colour.id] }?.name == "Oak")
        #expect(valid(target.project))
    }
}
