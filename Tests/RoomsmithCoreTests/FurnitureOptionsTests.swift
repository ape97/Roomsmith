import Foundation
import Testing
@testable import RoomsmithCore

// Furniture options: model, resolution (override > option > design), partition, decoding of old data, validation.

/// A wardrobe-like design: body, two door variants (A, B) and a handle, with material ids to tell the colours apart.
private struct Wardrobe {
    var def: FurnitureDefinition
    let body: UUID, doorA: UUID, doorB: UUID, handle: UUID
    let white: UUID, oak: UUID, black: UUID, steel: UUID
    var colour: OptionGroup
    var door: OptionGroup
    var colourWhite: UUID { colour.choices[0].id }
    var colourOak: UUID { colour.choices[1].id }
    var doorPlain: UUID { door.choices[0].id }
    var doorGlass: UUID { door.choices[1].id }

    init() {
        white = UUID(); oak = UUID(); black = UUID(); steel = UUID()
        let bodyC = Component(name: "body", shape: .box, position: P3(0, 0, 1000), size: Size3(1000, 580, 2000), materialId: white)
        let a = Component(name: "door plain", shape: .box, position: P3(0, -300, 1000), size: Size3(1000, 20, 2000), materialId: white)
        let b = Component(name: "door glass", shape: .box, position: P3(0, -300, 1000), size: Size3(1000, 20, 2000), materialId: black)
        let h = Component(name: "handle", shape: .cylinder, position: P3(400, -330, 1000), size: Size3(20, 20, 200))
        body = bodyC.id; doorA = a.id; doorB = b.id; handle = h.id
        var d = FurnitureDefinition(name: "Wardrobe", category: "Storage", size: Size3(1000, 580, 2000), components: [bodyC, a, b, h])
        colour = OptionGroup(name: "Colour", choices: [
            OptionChoice(name: "White", effects: [bodyC.id: OptionEffect(materialId: white), a.id: OptionEffect(materialId: white)]),
            OptionChoice(name: "Oak", effects: [bodyC.id: OptionEffect(materialId: oak), a.id: OptionEffect(materialId: oak)]),
        ])
        door = OptionGroup(name: "Door", choices: [
            OptionChoice(name: "Plain", effects: [a.id: OptionEffect(visible: true), b.id: OptionEffect(visible: false)]),
            OptionChoice(name: "Glass", effects: [a.id: OptionEffect(visible: false), b.id: OptionEffect(visible: true)]),
        ])
        d.optionGroups = [colour, door]
        def = d
    }

    func instance(_ selection: [UUID: UUID] = [:]) -> FurnitureInstance {
        var i = FurnitureInstance(definitionId: def.id, levelId: UUID(), name: "Wardrobe", position: P3(0, 0, 0))
        i.optionSelection = selection
        return i
    }
}

struct FurnitureOptionsTests {
    // MARK: Resolution

    @Test func noGroupsMeansNoOutcome() {
        var w = Wardrobe()
        w.def.optionGroups = []
        #expect(FurnitureResolver.optionOutcome(of: w.instance(), definition: w.def) == .none)
    }

    @Test func defaultChoiceAppliesWithoutSelectionAndFirstChoiceIsTheFallback() {
        var w = Wardrobe()
        let plain = FurnitureResolver.resolve(w.instance(), definition: w.def)
        #expect(plain.first { $0.componentId == w.body }?.materialId == w.white, "first choice is the default")
        #expect(plain.first { $0.componentId == w.doorA }?.visible == true)
        #expect(plain.first { $0.componentId == w.doorB }?.visible == false)
        w.def.optionGroups[0].defaultChoiceId = w.colourOak
        let oak = FurnitureResolver.resolve(w.instance(), definition: w.def)
        #expect(oak.first { $0.componentId == w.body }?.materialId == w.oak, "explicit default")
    }

    @Test func selectionSwitchesMaterialAndVisibility() {
        let w = Wardrobe()
        let inst = w.instance([w.colour.id: w.colourOak, w.door.id: w.doorGlass])
        let r = FurnitureResolver.resolve(inst, definition: w.def)
        func comp(_ id: UUID) -> ResolvedComponent { r.first { $0.componentId == id }! }
        #expect(comp(w.body).materialId == w.oak)
        #expect(comp(w.doorA).visible == false)
        #expect(comp(w.doorB).visible == true)
        #expect(comp(w.doorB).materialId == w.black, "a component the option does not touch keeps its own material")
        #expect(comp(w.handle).materialId == nil && comp(w.handle).visible)
    }

    @Test func precedenceOverrideThenOptionThenDesign() {
        let w = Wardrobe()
        var inst = w.instance([w.colour.id: w.colourOak])
        #expect(FurnitureResolver.resolve(inst, definition: w.def).first { $0.componentId == w.body }?.materialId == w.oak, "option beats design")
        inst.materialOverrides[w.body] = w.steel
        #expect(FurnitureResolver.resolve(inst, definition: w.def).first { $0.componentId == w.body }?.materialId == w.steel, "override beats option")
        inst.materialOverrides[w.body] = nil
        #expect(FurnitureResolver.resolve(inst, definition: w.def).first { $0.componentId == w.doorB }?.materialId == w.black, "design material")
    }

    @Test func optionNeverShowsWhatTheStateHides() {
        var w = Wardrobe()
        let st = FurnitureState(name: "hidden doors", poses: [w.doorA: ComponentPose(visible: false)])
        w.def.states = [st]
        var inst = w.instance([w.door.id: w.doorPlain])
        inst.stateId = st.id
        let r = FurnitureResolver.resolve(inst, definition: w.def)
        #expect(r.first { $0.componentId == w.doorA }?.visible == false, "state pose AND option")
        inst.visible = false
        #expect(FurnitureResolver.resolve(inst, definition: w.def).allSatisfy { !$0.visible })
    }

    @Test func staleSelectionFallsBackToTheDefault() {
        let w = Wardrobe()
        let inst = w.instance([w.colour.id: UUID(), UUID(): UUID()])
        let r = FurnitureResolver.resolve(inst, definition: w.def)
        #expect(r.first { $0.componentId == w.body }?.materialId == w.white)
    }

    @Test func laterGroupWinsOnTheSameProperty() {
        var w = Wardrobe()
        let paint = OptionGroup(name: "Paint", choices: [OptionChoice(name: "Black", effects: [w.body: OptionEffect(materialId: w.black)])])
        w.def.optionGroups.append(paint)
        let r = FurnitureResolver.resolve(w.instance([w.colour.id: w.colourOak]), definition: w.def)
        #expect(r.first { $0.componentId == w.body }?.materialId == w.black)
    }

    // MARK: Partition

    @Test func partitionChangesWithTheSelectionAndOmitsHiddenParts() {
        let w = Wardrobe()
        func partition(_ sel: [UUID: UUID]) -> [FurnitureMeshMerge.Entry] {
            FurnitureMeshMerge.partition(of: w.instance(sel), definition: w.def) { _ in false }
        }
        let plain = partition([w.door.id: w.doorPlain, w.colour.id: w.colourWhite])
        let glass = partition([w.door.id: w.doorGlass, w.colour.id: w.colourWhite])
        let oak = partition([w.door.id: w.doorPlain, w.colour.id: w.colourOak])
        #expect(plain.map(\.componentId) == [w.body, w.doorA, w.handle])
        #expect(glass.map(\.componentId) == [w.body, w.doorB, w.handle])
        #expect(plain != glass && plain != oak && glass != oak, "the merge cache key (partition) differs per selection")
        #expect(oak.first { $0.componentId == w.body }?.materialId == w.oak)
        #expect(partition([:]) == plain, "no selection = defaults")
    }

    // MARK: Footprint, size

    @Test func footprintAndSizeIgnoreOptions() {
        let w = Wardrobe()
        let base = w.instance()
        let glass = w.instance([w.door.id: w.doorGlass, w.colour.id: w.colourOak])
        #expect(FurnitureResolver.footprint(of: base, definition: w.def) == FurnitureResolver.footprint(of: glass, definition: w.def))
        #expect(FurnitureResolver.size(of: base, definition: w.def) == FurnitureResolver.size(of: glass, definition: w.def))
        let rb = FurnitureResolver.resolve(base, definition: w.def), rg = FurnitureResolver.resolve(glass, definition: w.def)
        #expect(rb.map(\.worldMatrix) == rg.map(\.worldMatrix), "options change neither pose nor size")
    }

    // MARK: Reports and plan

    @Test func billOfMaterialsListsTheVisibleMaterialsOfTheSelection() {
        var p = Project.empty(name: "T")
        let w = Wardrobe()
        for (id, name) in [(w.white, "White"), (w.oak, "Oak"), (w.black, "Black"), (w.steel, "Steel")] {
            _ = p.addMaterial(Material(id: id, name: name, color: RGBColor(10, 10, 10)))
        }
        _ = p.addDefinition(w.def)
        var inst = w.instance([w.colour.id: w.colourOak, w.door.id: w.doorPlain])
        inst.levelId = p.levels[0].id
        p.instances = [inst]
        let line = BillOfMaterials.make(p).furniture.first
        #expect(line?.material == "Oak", "hidden glass door (Black) and the unset handle are not listed")
    }

    @Test func topViewColourFollowsTheOption() {
        let w = Wardrobe()
        let colors: [UUID: RGBColor] = [w.white: RGBColor(255, 255, 255), w.oak: RGBColor(200, 150, 80), w.black: RGBColor(0, 0, 0)]
        let oak = FurnitureTopView.make(w.instance([w.colour.id: w.colourOak]), definition: w.def, colors: colors)
        let white = FurnitureTopView.make(w.instance(), definition: w.def, colors: colors)
        #expect(oak.overallColor == RGBColor(200, 150, 80))
        #expect(white.overallColor == RGBColor(255, 255, 255))
        let glass = FurnitureTopView.make(w.instance([w.door.id: w.doorGlass]), definition: w.def, colors: colors)
        #expect(!glass.shapes.contains { $0.componentId == w.doorA }, "hidden component is not drawn")
        #expect(glass.shapes.contains { $0.componentId == w.doorB })
    }

    // MARK: Decoding

    @Test func oldJSONWithoutOptionFieldsDecodes() throws {
        let w = Wardrobe()
        var plainDef = w.def
        plainDef.optionGroups = []
        let enc = JSONEncoder()
        let defJSON = try JSONSerialization.jsonObject(with: enc.encode(plainDef)) as! [String: Any]
        var oldDef = defJSON
        oldDef.removeValue(forKey: "optionGroups")
        oldDef.removeValue(forKey: "lights")
        let back = try JSONDecoder().decode(FurnitureDefinition.self, from: JSONSerialization.data(withJSONObject: oldDef))
        #expect(back.optionGroups.isEmpty && back.lights.isEmpty)
        #expect(back == plainDef)

        let inst = w.instance()
        var oldInst = try JSONSerialization.jsonObject(with: enc.encode(inst)) as! [String: Any]
        oldInst.removeValue(forKey: "optionSelection")
        let backInst = try JSONDecoder().decode(FurnitureInstance.self, from: JSONSerialization.data(withJSONObject: oldInst))
        #expect(backInst.optionSelection.isEmpty)
        #expect(backInst == inst)
    }

    @Test func populatedDefinitionAndInstanceRoundTripThroughJSON() throws {
        var w = Wardrobe()
        w.def.optionGroups[0].defaultChoiceId = w.colourOak
        w.def.lights = []
        w.def.tags = ["wardrobe"]; w.def.builtin = true; w.def.catalogKey = "wardrobe"; w.def.productId = UUID(); w.def.rev = 7
        let st = FurnitureState(name: "open", poses: [w.doorA: ComponentPose(visible: false)])
        w.def.states = [st]; w.def.defaultStateId = st.id
        w.def.tracks = [AnimationTrack(fromStateId: nil, toStateId: st.id)]
        let back = try JSONDecoder().decode(FurnitureDefinition.self, from: JSONEncoder().encode(w.def))
        #expect(back == w.def)

        var inst = w.instance([w.colour.id: w.colourOak, w.door.id: w.doorGlass])
        inst.rotationDeg = 90; inst.size = Size3(500, 580, 2000); inst.materialOverrides = [w.body: w.steel]; inst.stateId = st.id
        inst.groupId = UUID(); inst.productId = UUID(); inst.visible = false; inst.locked = true; inst.lightOn = false
        inst.allowsOverlap = true; inst.rev = 3
        let backInst = try JSONDecoder().decode(FurnitureInstance.self, from: JSONEncoder().encode(inst))
        #expect(backInst == inst)
    }

    // MARK: Validation

    @Test func validatorAcceptsAWellFormedDefinition() throws {
        let w = Wardrobe()
        try Validator.validateDefinition(w.def, materialIds: [w.white, w.oak, w.black, w.steel])
    }

    @Test func validatorRejectsBrokenOptionGroups() {
        let w = Wardrobe()
        let mats: Set<UUID> = [w.white, w.oak, w.black, w.steel]
        func rejects(_ edit: (inout FurnitureDefinition) -> Void, _ why: String) {
            var d = w.def
            edit(&d)
            #expect(throws: CommandError.self, "\(why)") { try Validator.validateDefinition(d, materialIds: mats) }
        }
        rejects({ $0.optionGroups[0].name = "  " }, "empty group name")
        rejects({ $0.optionGroups[1].name = "colour" }, "duplicate group name (case-insensitive)")
        rejects({ $0.optionGroups[0].choices = [] }, "no choice")
        rejects({ $0.optionGroups[0].choices[1].name = "WHITE" }, "duplicate choice name")
        rejects({ $0.optionGroups[0].choices[1].id = $0.optionGroups[0].choices[0].id }, "duplicate choice id")
        rejects({ $0.optionGroups[1].id = $0.optionGroups[0].id }, "duplicate group id")
        rejects({ $0.optionGroups[0].defaultChoiceId = UUID() }, "default choice not in the group")
        rejects({ $0.optionGroups[0].choices[0].effects[UUID()] = OptionEffect(visible: false) }, "unknown component")
        rejects({ $0.optionGroups[0].choices[0].effects[$0.components[0].id] = OptionEffect(materialId: UUID()) }, "unknown material")
        rejects({ d in d.optionGroups = (0..<(OptionGroup.maxPerDefinition + 1)).map { OptionGroup(name: "G\($0)", choices: [OptionChoice(name: "a")]) } }, "too many groups")
        rejects({ $0.optionGroups[0].choices = (0..<(OptionGroup.maxChoices + 1)).map { OptionChoice(name: "c\($0)") } }, "too many choices")
    }

    @MainActor @Test func validatorRejectsAForeignSelectionOnAnInstance() throws {
        let store = DocumentStore(project: Project.empty(name: "T"))
        let w = Wardrobe()
        let level = store.project.levels[0].id
        var materialIds: [UUID] = []
        for (id, name) in [(w.white, "White"), (w.oak, "Oak"), (w.black, "Black"), (w.steel, "Steel")] {
            _ = try store.run("Mat") { $0.addMaterial(Material(id: id, name: name, color: RGBColor(1, 2, 3))) }
            materialIds.append(id)
        }
        _ = try store.run("Def") { $0.addDefinition(w.def) }
        var id = UUID()
        try store.run("Add") { id = try $0.addInstance(definitionId: w.def.id, levelId: level, position: P3(0, 0, 0)) }
        try store.run("Select") { try $0.updateInstance(id) { $0.optionSelection = [w.colour.id: w.colourOak] } }
        #expect(store.project.instance(id)?.optionSelection == [w.colour.id: w.colourOak])
        #expect(throws: CommandError.self) { try store.run("Foreign group") { try $0.updateInstance(id) { $0.optionSelection = [UUID(): w.colourOak] } } }
        #expect(throws: CommandError.self) { try store.run("Foreign choice") { try $0.updateInstance(id) { $0.optionSelection = [w.colour.id: w.doorGlass] } } }
        #expect(store.project.instance(id)?.optionSelection == [w.colour.id: w.colourOak], "failed edits change nothing")
    }

    // MARK: Footprint in a state with poses

    @Test func partsHiddenByAnOptionDoNotCountForTheStateFootprint() {
        var w = Wardrobe()
        let state = FurnitureState(name: "Sliding out", poses: [w.doorB: ComponentPose(position: P3(0, -700, 1000))])
        w.def.states = [state]

        var plain = w.instance([w.door.id: w.doorPlain])
        plain.stateId = state.id
        let hidden = FurnitureResolver.localFootprint(of: plain, definition: w.def)
        #expect(abs(hidden.half.y - 315) < 0.001, "body and handle only: the moved glass door is hidden by the option")
        #expect(abs(hidden.center.y - -25) < 0.001)

        var glass = w.instance([w.door.id: w.doorGlass])
        glass.stateId = state.id
        let shown = FurnitureResolver.localFootprint(of: glass, definition: w.def)
        #expect(abs(shown.half.y - 500) < 0.001, "the selected door reaches out to -710")
        #expect(abs(shown.center.y - -210) < 0.001)
    }
}
