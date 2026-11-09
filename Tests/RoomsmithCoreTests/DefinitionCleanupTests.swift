import Foundation
import Testing
@testable import RoomsmithCore

// Furniture designs that pile up in a project: recognising identical ones, the once-per-name list, deleting unused ones,
// swapping the model of placed pieces, and reusing an identical design on paste.

private func wardrobe(name: String = "Wardrobe", width: MM = 1000, ids: Bool = true) -> FurnitureDefinition {
    var d = FurnitureDefinition(name: name, category: "Storage", size: Size3(width, 500, 2000), components: [
        Component(name: "body", shape: .box, position: P3(0, 0, 1000), size: Size3(width, 500, 2000)),
        Component(name: "door", shape: .box, position: P3(0, 250, 1000), size: Size3(width, 20, 2000)),
    ])
    let door = d.components[1].id
    let open = FurnitureState(name: "open", poses: [door: ComponentPose(position: P3(width / 2, 250, 1000), rotation: R3(0, 0, 90))])
    d.states = [FurnitureState(name: "closed"), open]
    d.defaultStateId = d.states[0].id
    d.optionGroups = [OptionGroup(name: "Colour", choices: [OptionChoice(name: "Oak"), OptionChoice(name: "Black")])]
    return d
}

@MainActor
@Suite("Definition cleanup") struct DefinitionCleanupTests {
    // MARK: Telling copies apart

    @Test func identicalDesignsWithOtherIdsAreTheSameDesign() {
        let a = wardrobe()
        let b = wardrobe()
        #expect(a.id != b.id && a.components[0].id != b.components[0].id && a.states[0].id != b.states[0].id)
        #expect(a.isSameDesign(as: b))
        #expect(a.idNormalized() == b.idNormalized())
    }

    @Test func aDifferentNameSizeOrPartMakesADifferentDesign() {
        let a = wardrobe()
        #expect(!a.isSameDesign(as: wardrobe(name: "Wardrobe tall")))
        #expect(!a.isSameDesign(as: wardrobe(width: 1001)))
        var more = wardrobe()
        more.components.append(Component(name: "knob", shape: .box, position: P3(0, 0, 1000), size: Size3(20, 20, 20)))
        #expect(!a.isSameDesign(as: more))
        var tagged = wardrobe()
        tagged.tags = ["x"]
        #expect(!a.isSameDesign(as: tagged))
    }

    @Test func ownTwinIgnoresBuiltinDesignsAndItself() {
        let w = CTWorld()
        var builtin = wardrobe()
        builtin.builtin = true
        let own = wardrobe()
        try? w.store.run("add") { p in _ = p.addDefinition(builtin); _ = p.addDefinition(own) }
        #expect(w.p.ownTwin(of: wardrobe())?.id == own.id)
        #expect(w.p.ownTwin(of: own) == nil, "a design is not its own twin")
    }

    // MARK: The list shows each name once

    @Test func listShowsEveryNameOnceWithTheMostUsedDesign() throws {
        let w = CTWorld()
        let first = wardrobe(name: "Wardrobe 100"), second = wardrobe(name: "wardrobe 100 "), third = wardrobe(name: "Wardrobe 100")
        let other = wardrobe(name: "Cabinet")
        try w.store.run("add") { p in for d in [first, other, second, third] { _ = p.addDefinition(d) } }
        _ = try w.instance(second.id, 0, 0)
        _ = try w.instance(second.id, 2000, 0)
        _ = try w.instance(third.id, 4000, 0)
        let rows = w.p.listedOwnDefinitions()
        #expect(rows.map(\.definition.id) == [second.id, other.id])
        #expect(rows[0].definition.id == second.id, "most placed pieces wins")
        #expect(rows[0].placedCount == 2 && rows[0].copies == 3)
        #expect(rows[1].definition.id == other.id && rows[1].copies == 1)
    }

    @Test func listTieGoesToTheNewestDesignAndLeavesBuiltinsOut() throws {
        let w = CTWorld()
        let old = wardrobe(), new = wardrobe()
        var builtin = wardrobe(name: "Builtin sofa")
        builtin.builtin = true
        try w.store.run("add") { p in for d in [old, new, builtin] { _ = p.addDefinition(d) } }
        let rows = w.p.listedOwnDefinitions()
        #expect(rows.map(\.definition.id) == [new.id])
        #expect(rows[0].copies == 2)
        // The list changes nothing in the project.
        #expect(w.p.definitions.count == 3)
    }

    // MARK: Delete and prune

    @Test func deleteDefinitionsIsAllOrNothingAndNamesEveryBlocker() throws {
        let w = CTWorld()
        let free = wardrobe(name: "Free"), used = wardrobe(name: "Used")
        var builtin = wardrobe(name: "Built")
        builtin.builtin = true
        try w.store.run("add") { p in for d in [free, used, builtin] { _ = p.addDefinition(d) } }
        _ = try w.instance(used.id, 0, 0)
        do { try w.store.run("bad") { _ = try $0.deleteDefinitions([free.id, used.id, builtin.id]) }; Issue.record("must throw") }
        catch let err as CommandError {
            #expect(err.message.contains("Used") && err.message.contains("Built"))
            #expect(Set(err.ids) == [used.id, builtin.id])
        }
        #expect(w.p.definition(free.id) != nil, "nothing changed")
        var deleted: [UUID] = []
        try w.store.run("ok") { deleted = try $0.deleteDefinitions([free.id, free.id]) }
        #expect(deleted == [free.id])
        #expect(w.p.definition(free.id) == nil && w.p.definition(used.id) != nil)
        #expect(throws: CommandError.self) { try w.store.run("unknown") { _ = try $0.deleteDefinitions([UUID()]) } }
    }

    @Test func removeUnusedKeepsUsedBuiltinAndProductLinkedDesignsInOneUndoStep() throws {
        let w = CTWorld()
        let used = wardrobe(name: "Used"), spare1 = wardrobe(name: "Spare"), spare2 = wardrobe(name: "Spare")
        let linked = wardrobe(name: "Planned")
        var builtin = wardrobe(name: "Built")
        builtin.builtin = true
        let product = CatalogProduct(name: "Planned wardrobe")
        try w.store.run("add") { p in
            for d in [used, spare1, spare2, linked, builtin] { _ = p.addDefinition(d) }
            _ = p.addProduct(product)
            try p.linkProduct(product.id, to: linked.id)
        }
        _ = try w.instance(used.id, 0, 0)
        #expect(Set(w.p.prunableDefinitions().map(\.id)) == [spare1.id, spare2.id])
        #expect(Set(w.p.unusedDefinitions().map(\.id)) == [spare1.id, spare2.id, linked.id])
        var removed: [UUID] = []
        try w.store.run("Remove Unused Furniture") { removed = try $0.removeUnusedDefinitions() }
        #expect(removed.count == 2)
        #expect(Set(w.p.definitions.map(\.id)) == [used.id, linked.id, builtin.id])
        _ = try w.store.undo()
        #expect(w.p.definitions.count == 5, "one undo step brings all back")
        try w.store.run("again") { removed = try $0.removeUnusedDefinitions() }
        #expect(removed.count == 2)
        try w.store.run("nothing left") { removed = try $0.removeUnusedDefinitions() }
        #expect(removed.isEmpty)
    }

    // MARK: Replace a model

    @MainActor private struct Pair {
        let w = CTWorld()
        let old: FurnitureDefinition
        let new: FurnitureDefinition
        let piece: UUID
        init() throws {
            let a = wardrobe(), b = wardrobe()
            try w.store.run("add") { p in _ = p.addDefinition(a); _ = p.addDefinition(b) }
            piece = try w.instance(a.id, 1500, 800, rot: 90)
            old = a
            new = b
        }
    }

    @Test func replacingAModelMovesThePiecesAndRemovesTheOldDesign() throws {
        let x = try Pair()
        let open = try #require(x.old.states.first { $0.name == "open" })
        let black = try #require(x.old.optionGroups[0].choices.first { $0.name == "Black" })
        let door = x.old.components[1].id, colour = x.old.optionGroups[0].id
        let paint = x.w.material("Paint")
        try x.w.store.run("set") { p in
            try p.activateState([x.piece], stateId: open.id)
            try p.setOptions([x.piece], select: [colour: black.id])
            try p.updateInstance(x.piece) { $0.materialOverrides = [door: paint]; $0.name = "My wardrobe" }
        }
        var result: DefinitionReplacement?
        try x.w.store.run("Replace") { result = try $0.replaceDefinition([x.old.id], with: x.new.id) }
        let r = try #require(result)
        #expect(r.instanceIds == [x.piece] && r.removedDefinitionIds == [x.old.id] && r.keptDefinitionIds.isEmpty)
        let i = try #require(x.w.p.instance(x.piece))
        #expect(i.definitionId == x.new.id)
        #expect(i.position == P3(1500, 800, 0) && i.rotationDeg == 90 && i.name == "My wardrobe")
        #expect(i.stateId == x.new.states.first { $0.name == "open" }?.id, "state carried over by name")
        #expect(i.optionSelection == [x.new.optionGroups[0].id: x.new.optionGroups[0].choices[1].id], "option carried over by name")
        #expect(i.materialOverrides == [x.new.components[1].id: paint], "colour carried over to the part of the same name")
        #expect(x.w.p.definition(x.old.id) == nil)
        _ = try x.w.store.undo()
        #expect(x.w.p.instance(x.piece)?.definitionId == x.old.id && x.w.p.definition(x.old.id) != nil, "undo is one step")
    }

    @Test func unmatchedStateFallsBackToTheDefaultAndUnmatchedPartsAndOptionsDrop() throws {
        let w = CTWorld()
        let old = wardrobe()
        var new = wardrobe(name: "Wardrobe new")
        new.states = [FurnitureState(name: "shut")]
        new.defaultStateId = new.states[0].id
        new.optionGroups = []
        new.components = [Component(name: "carcass", shape: .box, position: P3(0, 0, 1000), size: Size3(1000, 500, 2000))]
        try w.store.run("add") { p in _ = p.addDefinition(old); _ = p.addDefinition(new) }
        let piece = try w.instance(old.id, 0, 0)
        let paint = w.material()
        try w.store.run("set") { p in
            try p.activateState([piece], stateId: old.states[1].id)
            try p.updateInstance(piece) { $0.materialOverrides = [old.components[1].id: paint] }
            try p.setOptions([piece], select: [old.optionGroups[0].id: old.optionGroups[0].choices[1].id])
        }
        try w.store.run("Replace") { _ = try $0.replaceDefinition([old.id], with: new.id) }
        let i = try #require(w.p.instance(piece))
        #expect(i.stateId == new.defaultStateId)
        #expect(i.materialOverrides.isEmpty && i.optionSelection.isEmpty)
    }

    @Test func aPieceWithoutAStateStaysWithoutOne() throws {
        let x = try Pair()
        // addInstance starts a piece in the design's default state, so clear it first to get a piece that really has none.
        try x.w.store.run("clear") { try $0.updateInstance(x.piece) { $0.stateId = nil } }
        #expect(x.w.p.instance(x.piece)?.stateId == nil)
        try x.w.store.run("Replace") { _ = try $0.replaceDefinition([x.old.id], with: x.new.id) }
        #expect(x.w.p.instance(x.piece)?.stateId == nil)
    }

    @Test func replacingOnlySomePiecesKeepsTheOldDesign() throws {
        let x = try Pair()
        let other = try x.w.instance(x.old.id, 4000, 800)
        var result: DefinitionReplacement?
        try x.w.store.run("Replace") { result = try $0.replaceDefinition([x.old.id], with: x.new.id, only: [x.piece]) }
        #expect(result?.removedDefinitionIds.isEmpty == true && result?.keptDefinitionIds == [x.old.id])
        #expect(x.w.p.instance(x.piece)?.definitionId == x.new.id)
        #expect(x.w.p.instance(other)?.definitionId == x.old.id)
        #expect(x.w.p.definition(x.old.id) != nil)
        #expect(throws: CommandError.self) {
            try x.w.store.run("bad") { _ = try $0.replaceDefinition([x.old.id], with: x.new.id, only: [x.piece]) }
        }
    }

    @Test func removeOldFalseAndProductLinkedDesignsStay() throws {
        let x = try Pair()
        try x.w.store.run("Replace") { _ = try $0.replaceDefinition([x.old.id], with: x.new.id, removeOld: false) }
        #expect(x.w.p.definition(x.old.id) != nil)

        let y = try Pair()
        let product = CatalogProduct(name: "P")
        try y.w.store.run("link") { p in _ = p.addProduct(product); try p.linkProduct(product.id, to: y.old.id) }
        var result: DefinitionReplacement?
        try y.w.store.run("Replace") { result = try $0.replaceDefinition([y.old.id], with: y.new.id) }
        #expect(result?.keptDefinitionIds == [y.old.id])
        #expect(y.w.p.definition(y.old.id) != nil)
    }

    @Test func aLockedPieceFailsTheWholeCallAndNothingChanges() throws {
        let x = try Pair()
        let free = try x.w.instance(x.old.id, 4000, 800)
        try x.w.store.run("lock") { try $0.setLocked([x.piece], true) }
        #expect(throws: CommandError.self) { try x.w.store.run("Replace") { _ = try $0.replaceDefinition([x.old.id], with: x.new.id) } }
        #expect(x.w.p.instance(free)?.definitionId == x.old.id && x.w.p.instance(x.piece)?.definitionId == x.old.id)
        #expect(x.w.p.definition(x.old.id) != nil)
    }

    @Test func badArgumentsAreRefused() throws {
        let x = try Pair()
        #expect(throws: CommandError.self) { try x.w.store.run("a") { _ = try $0.replaceDefinition([x.old.id], with: x.old.id) } }
        #expect(throws: CommandError.self) { try x.w.store.run("b") { _ = try $0.replaceDefinition([], with: x.new.id) } }
        #expect(throws: CommandError.self) { try x.w.store.run("c") { _ = try $0.replaceDefinition([UUID()], with: x.new.id) } }
        #expect(throws: CommandError.self) { try x.w.store.run("d") { _ = try $0.replaceDefinition([x.old.id], with: UUID()) } }
    }

    @Test func groupConfigurationsFollowTheNewDesign() throws {
        let x = try Pair()
        let second = try x.w.instance(x.old.id, 3000, 800)
        let open = try #require(x.old.states.first { $0.name == "open" })
        var group = UUID()
        try x.w.store.run("group") { p in
            try p.activateState([x.piece], stateId: open.id)
            group = try p.groupObjects([x.piece, second], name: "Pair")
            _ = try p.saveConfiguration(groupId: group, name: "Open")
        }
        let before = try #require(x.w.p.group(group)?.configurations.first?.poses[x.piece])
        #expect(before.stateId == open.id)
        try x.w.store.run("Replace") { _ = try $0.replaceDefinition([x.old.id], with: x.new.id) }
        let after = try #require(x.w.p.group(group)?.configurations.first?.poses[x.piece])
        #expect(after.stateId == x.new.states.first { $0.name == "open" }?.id)
    }

    // MARK: Paste reuses an identical design

    @Test func pastingTheSamePieceAgainAddsNoDesign() throws {
        let w = CTWorld()
        let d = wardrobe()
        try w.store.run("add") { p in _ = p.addDefinition(d) }
        let piece = try w.instance(d.id, 0, 0)
        let transfer = try FurnitureTransfer.make(from: w.p, ids: [piece], packageURL: nil)
        for _ in 0..<3 {
            let ids = try FurnitureTransferService.importTransfer(transfer, into: w.store, targetPackage: nil, levelId: w.level, offset: P2(500, 500))
            #expect(ids.count == 1)
            #expect(w.p.instance(ids[0])?.definitionId == d.id, "the existing identical design is used")
        }
        #expect(w.p.definitions.count == 1)
        #expect(w.p.instances.count == 4)
    }

    @Test func pastingIntoAnotherProjectAddsTheDesignOnceThenReusesIt() throws {
        let source = CTWorld(), target = CTWorld()
        let d = wardrobe()
        try source.store.run("add") { p in _ = p.addDefinition(d) }
        let piece = try source.instance(d.id, 0, 0)
        let transfer = try FurnitureTransfer.make(from: source.p, ids: [piece], packageURL: nil)
        let first = try FurnitureTransferService.importTransfer(transfer, into: target.store, targetPackage: nil, levelId: target.level)
        let second = try FurnitureTransferService.importTransfer(transfer, into: target.store, targetPackage: nil, levelId: target.level)
        #expect(target.p.definitions.count == 1)
        let a = try #require(target.p.instance(first[0])), b = try #require(target.p.instance(second[0]))
        #expect(a.definitionId == b.definitionId)
    }

    @Test func aPastedPieceKeepsStateOptionsAndColoursOnAReusedDesign() throws {
        let w = CTWorld()
        let d = wardrobe()
        try w.store.run("add") { p in _ = p.addDefinition(d) }
        let piece = try w.instance(d.id, 0, 0)
        let paint = w.material()
        try w.store.run("set") { p in
            try p.activateState([piece], stateId: d.states[1].id)
            try p.setOptions([piece], select: [d.optionGroups[0].id: d.optionGroups[0].choices[1].id])
            try p.updateInstance(piece) { $0.materialOverrides = [d.components[1].id: paint] }
        }
        let transfer = try FurnitureTransfer.make(from: w.p, ids: [piece], packageURL: nil)
        let ids = try FurnitureTransferService.importTransfer(transfer, into: w.store, targetPackage: nil, levelId: w.level)
        let copy = try #require(w.p.instance(ids[0]))
        #expect(copy.stateId == d.states[1].id)
        #expect(copy.optionSelection == [d.optionGroups[0].id: d.optionGroups[0].choices[1].id])
        #expect(copy.materialOverrides == [d.components[1].id: paint])
    }

    @Test func aDesignLinkedToAProductIsNotReusedOnPaste() throws {
        let source = CTWorld(), target = CTWorld()
        var d = wardrobe()
        let product = CatalogProduct(name: "Planned")
        try source.store.run("add") { p in
            _ = p.addProduct(product)
            d.productId = product.id
            _ = p.addDefinition(d)
        }
        let piece = try source.instance(d.id, 0, 0)
        let transfer = try FurnitureTransfer.make(from: source.p, ids: [piece], packageURL: nil)
        _ = try FurnitureTransferService.importTransfer(transfer, into: target.store, targetPackage: nil, levelId: target.level)
        _ = try FurnitureTransferService.importTransfer(transfer, into: target.store, targetPackage: nil, levelId: target.level)
        #expect(target.p.definitions.count == 2, "a product link makes each copy its own design")
    }
}
