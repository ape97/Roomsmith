import Foundation
import Testing
@testable import RoomsmithCore

@MainActor
struct NewItemTrackerTests {
    private func world() throws -> (store: DocumentStore, level: UUID, def: UUID) {
        let store = DocumentStore(project: Project.empty(name: "T"))
        var def = UUID()
        try store.run("def") { p in
            def = p.addDefinition(FurnitureDefinition(name: "Box", category: "Test", size: Size3(500, 500, 500),
                                                      components: [Component(name: "b", shape: .box, position: P3(0, 0, 250), size: Size3(500, 500, 500))]))
        }
        return (store, store.project.levels[0].id, def)
    }

    private func tracked(_ store: DocumentStore) -> (get: () -> NewItemTracker, token: UUID) {
        final class Box { var t = NewItemTracker() }
        let box = Box()
        let token = store.addObserver { box.t.apply($0) }
        return ({ box.t }, token)
    }

    @Test func userAddsNeverBadge() throws {
        let w = try world()
        let t = tracked(w.store)
        try w.store.run("wall") { _ = try $0.addWall(levelId: w.level, start: P2(0, 0), end: P2(2000, 0)) }
        #expect(t.get().isEmpty)
    }

    @Test func agentAddsBadgeAllRowKinds() throws {
        let w = try world()
        let t = tracked(w.store)
        var ids: [UUID] = []
        try w.store.run("agent", options: .agent("c")) { p in
            let wall = try p.addWall(levelId: w.level, start: P2(0, 0), end: P2(4000, 0))
            ids.append(wall)
            ids.append(try p.addOpening(wallId: wall, kind: .door, width: 900, height: 2000))
            ids.append(try p.addRoom(levelId: w.level, name: "R", points: [P2(0, 0), P2(3000, 0), P2(3000, 3000), P2(0, 3000)]))
            ids.append(try p.addDimension(levelId: w.level, a: P2(0, 0), b: P2(1000, 0)))
            let a = try p.addInstance(definitionId: w.def, levelId: w.level, position: P3(500, 500, 0))
            let b = try p.addInstance(definitionId: w.def, levelId: w.level, position: P3(1500, 500, 0))
            ids += [a, b]
            ids.append(try p.groupObjects([a, b], name: "G"))
        }
        // Every kind of row in the object list is covered by what the tracker marks.
        #expect(t.get().ids == Set(ids))
        #expect(t.get().ids.isSubset(of: w.store.project.listedObjectIds))
        #expect(w.store.project.listedObjectIds == Set(ids))
    }

    @Test func undoRedoByUserMarksNothingAndDeletedFallOut() throws {
        let w = try world()
        let t = tracked(w.store)
        var wall = UUID()
        try w.store.run("agent", options: .agent("c")) { wall = try $0.addWall(levelId: w.level, start: P2(0, 0), end: P2(2000, 0)) }
        #expect(t.get().contains(wall))
        try w.store.undo()                       // removed -> badge gone
        #expect(t.get().isEmpty)
        try w.store.redo()                       // user redo brings it back, but not as "New"
        #expect(t.get().isEmpty)
        var mine = UUID()
        try w.store.run("user") { mine = try $0.addWall(levelId: w.level, start: P2(0, 500), end: P2(2000, 500)) }
        try w.store.undo(); try w.store.redo()
        #expect(!t.get().contains(mine))
    }

    @Test func resetClears() throws {
        let w = try world()
        let t = tracked(w.store)
        try w.store.run("agent", options: .agent("c")) { _ = try $0.addWall(levelId: w.level, start: P2(0, 0), end: P2(2000, 0)) }
        #expect(!t.get().isEmpty)
        w.store.replaceProject(Project.empty(name: "Other"))
        #expect(t.get().isEmpty)
    }

    @Test func plainTrackerSemantics() {
        var t = NewItemTracker()
        let a = UUID(), b = UUID(), c = UUID()
        t.noteAdded(before: [], after: [a], origin: .user)
        t.noteAdded(before: [], after: [a], origin: .system)
        #expect(t.isEmpty)
        t.noteAdded(before: [a], after: [a, b, c], origin: .agent("x"))
        #expect(t.ids == [b, c])
        t.markSeen([b, a])
        #expect(t.ids == [c])
        t.prune(existing: [a, b])
        #expect(t.isEmpty)
        t.noteAdded([a], origin: .agent("x"))
        t.noteAdded([b], origin: .user)
        #expect(t.ids == [a])
    }
}

struct LibraryExamplesTests {
    @Test func exampleKeysAreFewAndExist() {
        #expect(BuiltinCatalog.exampleKeys.count <= 5)
        #expect(Set(BuiltinCatalog.exampleKeys).count == BuiltinCatalog.exampleKeys.count)
        for k in BuiltinCatalog.exampleKeys { #expect(BuiltinCatalog.definition(k) != nil, "\(k)") }
        #expect(BuiltinCatalog.examples(matching: "").map(\.key) == BuiltinCatalog.exampleKeys)
        #expect(BuiltinCatalog.examples(matching: "sofa").map(\.key) == ["sofa.3seat.2100"])   // the 2-seat sofa is not an example
        #expect(BuiltinCatalog.examples(matching: "stove").isEmpty)
        #expect(BuiltinCatalog.entries.count > 5)   // the full catalog stays for agents
    }

    @Test func entriesSortByNameWithinCategory() {
        func e(_ n: String) -> LibraryEntry { LibraryEntry(section: .own, name: n, size: Size3(100, 100, 100)) }
        let sorted = LibrarySearch.sortedByName([e("table 10"), e("Zebra"), e("apple"), e("table 2")])
        #expect(sorted.map(\.name) == ["apple", "table 2", "table 10", "Zebra"])
    }
}
