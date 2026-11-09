import Testing
import Foundation
@testable import RoomsmithCore

// MARK: - Shared helpers for the CommandTests* files

/// A store with one empty level plus quick builders. All builders go through `store.run` like real commands.
@MainActor
struct CTWorld {
    let store: DocumentStore
    let level: UUID

    init() {
        let p = Project.empty(name: "T")
        store = DocumentStore(project: p)
        level = p.levels[0].id
    }

    var p: Project { store.project }

    @discardableResult
    func wall(_ s: P2, _ e: P2, level lvl: UUID? = nil, name: String = "Wall") throws -> UUID {
        var id = UUID()
        let target = lvl ?? level
        try store.run(name) { id = try $0.addWall(levelId: target, start: s, end: e) }
        return id
    }

    @discardableResult
    func opening(_ wallId: UUID, offset: MM, width: MM = 800, height: MM = 2000, sill: MM = 0, kind: OpeningKind = .door) throws -> UUID {
        var id = UUID()
        try store.run("Add opening") { id = try $0.addOpening(wallId: wallId, kind: kind, offset: offset, width: width, height: height, sill: sill) }
        return id
    }

    @discardableResult
    func definition(name: String = "Module", size: MM = 1000) -> UUID {
        let d = FurnitureDefinition(name: name, category: "t", size: Size3(size, size, 400), components: [
            Component(name: "seat", shape: .cushion, position: P3(0, 0, 200), size: Size3(size, size, 400)),
            Component(name: "back", shape: .box, position: P3(0, size / 2, 600), size: Size3(size, 100, 400)),
        ])
        _ = try? store.run("Add definition") { $0.addDefinition(d) }
        return d.id
    }

    @discardableResult
    func instance(_ def: UUID, _ x: MM, _ y: MM, z: MM = 0, rot: Double = 0, level lvl: UUID? = nil) throws -> UUID {
        var id = UUID()
        let target = lvl ?? level
        try store.run("Add furniture") { id = try $0.addInstance(definitionId: def, levelId: target, position: P3(x, y, z), rotationDeg: rot) }
        return id
    }

    @discardableResult
    func group(_ ids: [UUID], name: String = "Sofa") throws -> UUID {
        var id = UUID()
        try store.run("Group") { id = try $0.groupObjects(ids, name: name) }
        return id
    }

    func material(_ name: String = "Paint") -> UUID {
        let m = Material(name: name, color: RGBColor(10, 20, 30))
        _ = try? store.run("Add material") { $0.addMaterial(m) }
        return m.id
    }
}

/// Runs `body`, expects a CommandError with `code`, returns it for further checks.
@MainActor @discardableResult
func ctThrows(_ code: CommandError.Code, sourceLocation: SourceLocation = #_sourceLocation, _ body: () throws -> Void) -> CommandError? {
    do {
        try body()
        Issue.record("expected \(code.rawValue) but nothing was thrown", sourceLocation: sourceLocation)
        return nil
    } catch let e as CommandError {
        #expect(e.code == code, "\(e)", sourceLocation: sourceLocation)
        return e
    } catch {
        Issue.record("unexpected error type \(error)", sourceLocation: sourceLocation)
        return nil
    }
}

/// Project with all revisions and the camera neutralised, for "exact state" comparisons.
func ctNormalized(_ p: Project) -> Project {
    var q = p
    q.revision = 0
    q.camera = .default
    for i in q.levels.indices { q.levels[i].rev = 0 }
    for i in q.walls.indices { q.walls[i].rev = 0 }
    for i in q.rooms.indices { q.rooms[i].rev = 0 }
    for i in q.openings.indices { q.openings[i].rev = 0 }
    for i in q.dimensions.indices { q.dimensions[i].rev = 0 }
    for i in q.materials.indices { q.materials[i].rev = 0 }
    for i in q.definitions.indices { q.definitions[i].rev = 0 }
    for i in q.instances.indices { q.instances[i].rev = 0 }
    for i in q.groups.indices { q.groups[i].rev = 0 }
    for i in q.products.indices { q.products[i].rev = 0 }
    for i in q.assets.indices { q.assets[i].rev = 0 }
    for i in q.backgrounds.indices { q.backgrounds[i].rev = 0 }
    for i in q.cameras.indices { q.cameras[i].rev = 0 }
    return q
}

// MARK: - Revisions, dry run, no-op

@MainActor @Suite("Command revisions") struct CommandRevisionTests {
    @Test func revisionIncrementsOncePerCommittedCommand() throws {
        let w = CTWorld()
        #expect(w.p.revision == 0)
        var ids: [UUID] = []
        let r = try w.store.apply("Three walls") { p in
            ids = try p.addWalls(levelId: w.level, points: [P2(0, 0), P2(1000, 0), P2(1000, 1000), P2(0, 1000)], closed: true)
        }
        #expect(r.committed)
        #expect(r.revision == 1)
        #expect(w.p.revision == 1)
        #expect(ids.count == 4)
        #expect(r.changes.ids(.wall, [.added]).count == 4)
        #expect(w.store.lastSeq == 1)
    }

    @Test func changedObjectsGetNewRevUntouchedKeepTheirs() throws {
        let w = CTWorld()
        let a = try w.wall(P2(0, 0), P2(1000, 0))
        let b = try w.wall(P2(0, 500), P2(1000, 500))
        #expect(w.p.wall(a)?.rev == 1)
        #expect(w.p.wall(b)?.rev == 2)
        try w.store.run("Thicken") { try $0.modify(\.walls, a, "Wall") { $0.thickness = 200 } }
        #expect(w.p.revision == 3)
        #expect(w.p.wall(a)?.rev == 3)
        #expect(w.p.wall(b)?.rev == 2)
        #expect(w.p.level(w.level)?.rev == 0)
        #expect(w.p.rev(of: a) == 3)
        #expect(w.p.rev(of: UUID()) == nil)
    }

    @Test func noOpCommandCommitsNothing() throws {
        let w = CTWorld()
        let a = try w.wall(P2(0, 0), P2(1000, 0))
        let seq = w.store.lastSeq
        let rev = w.p.revision
        let undoName = w.store.undoName
        let r = try w.store.apply("Nothing") { _ in 42 }
        #expect(r.value == 42)
        #expect(!r.committed)
        #expect(r.changes.isEmpty)
        #expect(r.revision == rev)
        // Writing the same value again is also a no-op.
        let r2 = try w.store.apply("Same") { try $0.modify(\.walls, a, "Wall") { $0.thickness = $0.thickness } }
        #expect(!r2.committed)
        #expect(w.p.revision == rev)
        #expect(w.store.lastSeq == seq)
        #expect(w.store.undoName == undoName)
        #expect(w.p.wall(a)?.rev == 1)
    }

    @Test func noOpWithStaleExpectedObjectRevisionStillConflicts() throws {
        let w = CTWorld()
        let a = try w.wall(P2(0, 0), P2(1000, 0))
        ctThrows(.conflict) {
            try w.store.run("No-op", options: CommandOptions(expectedObjectRevisions: [a: 99])) { _ in }
        }
    }

    @Test func dryRunReturnsChangesButTouchesNothing() throws {
        let w = CTWorld()
        let before = w.p
        let seq = w.store.lastSeq
        let r = try w.store.apply("Preview", options: CommandOptions(dryRun: true)) { p in
            try p.addWall(levelId: w.level, start: P2(0, 0), end: P2(2000, 0))
        }
        #expect(!r.committed)
        #expect(r.changes.ids(.wall, [.added]) == [r.value])
        #expect(r.revision == 0)
        #expect(w.p == before)
        #expect(!w.store.canUndo)
        #expect(w.store.lastSeq == seq)
        #expect(w.store.events(after: 0).events.isEmpty)
    }

    @Test func dryRunStillValidates() throws {
        let w = CTWorld()
        ctThrows(.outOfRange) {
            try w.store.run("Bad", options: CommandOptions(dryRun: true)) { p in
                try p.addWall(levelId: w.level, start: P2(0, 0), end: P2(2000, 0), thickness: 0)
            }
        }
    }

    @Test func dryRunDoesNotDisturbUndoOfEarlierCommand() throws {
        let w = CTWorld()
        try w.wall(P2(0, 0), P2(1000, 0))
        _ = try w.store.apply("Preview", options: CommandOptions(dryRun: true)) { p in try p.addWall(levelId: w.level, start: P2(0, 5), end: P2(9, 5)) }
        #expect(w.store.undoName == "Wall")
        try w.store.undo()
        #expect(w.p.walls.isEmpty)
    }

    @Test func failedCommandLeavesProjectUntouched() throws {
        let w = CTWorld()
        let a = try w.wall(P2(0, 0), P2(1000, 0))
        let before = w.p
        ctThrows(.notFound) {
            try w.store.run("Half done") { p in
                try p.modify(\.walls, a, "Wall") { $0.thickness = 300 }
                try p.updateOpening(UUID())
            }
        }
        #expect(w.p == before)
        #expect(w.store.lastSeq == 1)
    }
}

// MARK: - Undo / redo

@MainActor @Suite("Command undo and redo") struct CommandUndoTests {
    @Test func undoRestoresExactStateAndRedoReappliesIt() throws {
        let w = CTWorld()
        let a = try w.wall(P2(0, 0), P2(4000, 0))
        try w.opening(a, offset: 2000)
        let snapshot = ctNormalized(w.p)
        try w.store.run("Big edit") { p in
            try p.moveObjects([a], by: P3(100, 200, 0))
            try p.updateWall(a, thickness: 250, moveJoined: false)
            try p.addRoom(levelId: w.level, name: "R", points: [P2(0, 0), P2(1000, 0), P2(1000, 1000)])
            p.addLevel(name: "Upstairs")
        }
        let edited = ctNormalized(w.p)
        #expect(edited != snapshot)
        let revAfterCommand = w.p.revision

        try w.store.undo()
        #expect(ctNormalized(w.p) == snapshot)
        #expect(w.p.revision == revAfterCommand + 1, "undo is a new revision, never goes backwards")

        try w.store.redo()
        #expect(ctNormalized(w.p) == edited)
        #expect(w.p.revision == revAfterCommand + 2)
    }

    @Test func undoRestoresChangedObjectsRevisionsMonotonic() throws {
        let w = CTWorld()
        let a = try w.wall(P2(0, 0), P2(1000, 0))
        let b = try w.wall(P2(0, 500), P2(1000, 500))
        try w.store.run("Edit a") { try $0.modify(\.walls, a, "Wall") { $0.height = 3000 } }
        let revB = w.p.wall(b)?.rev
        try w.store.undo()
        #expect(w.p.wall(a)?.height == 2500)
        #expect(w.p.wall(a)?.rev == w.p.revision, "restored object is stamped with the undo revision")
        #expect(w.p.wall(b)?.rev == revB, "untouched object keeps its revision")
    }

    @Test func undoKeepsLiveCamera() throws {
        let w = CTWorld()
        try w.wall(P2(0, 0), P2(1000, 0))
        var cam = CameraState.default
        cam.yawDeg = 123
        try w.store.run("Orbit", options: CommandOptions(recordUndo: false)) { $0.setCamera(cam) }
        try w.store.undo()
        #expect(w.p.walls.isEmpty)
        #expect(w.p.camera.yawDeg == 123)
    }

    @Test func newCommandClearsRedo() throws {
        let w = CTWorld()
        try w.wall(P2(0, 0), P2(1000, 0))
        try w.store.undo()
        #expect(w.store.canRedo)
        #expect(w.store.redoName == "Wall")
        try w.wall(P2(0, 0), P2(2000, 0), name: "Other")
        #expect(!w.store.canRedo)
        #expect(w.store.redoName == nil)
        #expect(try w.store.redo() == nil)
    }

    @Test func undoWithEmptyHistoryReturnsNil() throws {
        let w = CTWorld()
        #expect(try w.store.undo() == nil)
        #expect(try w.store.redo() == nil)
        #expect(w.store.lastSeq == 0)
    }

    @Test func historyIsLimitedToTwoHundredEntries() throws {
        let w = CTWorld()
        #expect(w.store.historyLimit == 200)
        for i in 0..<210 {
            try w.store.run("Rename \(i)") { try $0.updateLevel(w.level, name: "L\(i)") }
        }
        #expect(w.store.undoName == "Rename 209")
        var undone = 0
        while try w.store.undo() != nil { undone += 1 }
        #expect(undone == 200)
        // The oldest reachable state is the one before "Rename 10".
        #expect(w.p.level(w.level)?.name == "L9")
        #expect(!w.store.canUndo)
        var redone = 0
        while try w.store.redo() != nil { redone += 1 }
        #expect(redone == 200)
        #expect(w.p.level(w.level)?.name == "L209")
    }

    @Test func undoAndRedoEmitEventsWithKind() throws {
        let w = CTWorld()
        let a = try w.wall(P2(0, 0), P2(1000, 0), name: "Draw")
        let undo = try w.store.undo()
        #expect(undo?.kind == .undo)
        #expect(undo?.name == "Draw")
        #expect(undo?.changes.ids(.wall, [.removed]) == [a])
        let redo = try w.store.redo()
        #expect(redo?.kind == .redo)
        #expect(redo?.changes.ids(.wall, [.added]) == [a])
        let all = w.store.events(after: 0).events
        #expect(all.map(\.kind) == [.command, .undo, .redo])
        #expect(all.map(\.seq) == [1, 2, 3])
        #expect(all.map(\.revision) == [1, 2, 3])
        #expect(w.store.lastSeq == 3)
    }

    @Test func undoOriginIsReported() throws {
        let w = CTWorld()
        try w.wall(P2(0, 0), P2(1000, 0))
        let ev = try w.store.undo(origin: .agent("x"))
        #expect(ev?.origin == .agent("x"))
    }

    @Test func recordUndoFalseMergesIntoLastEntry() throws {
        let w = CTWorld()
        let a = try w.wall(P2(0, 0), P2(1000, 0))
        try w.store.run("Drag", options: CommandOptions(recordUndo: false)) { try $0.moveObjects([a], by: P3(50, 0, 0)) }
        #expect(w.p.wall(a)?.start == P2(50, 0))
        #expect(w.store.undoName == "Wall", "no new entry")
        try w.store.run("Drag more", options: CommandOptions(recordUndo: false)) { try $0.moveObjects([a], by: P3(50, 0, 0)) }
        try w.store.undo()
        #expect(w.p.walls.isEmpty, "one undo reverts the command including the transient moves")
        #expect(!w.store.canUndo)
        try w.store.redo()
        #expect(w.p.wall(a)?.start == P2(100, 0), "redo brings back the merged result")
    }

    @Test func recordUndoFalseWithEmptyHistoryAddsNoEntry() throws {
        let w = CTWorld()
        try w.store.run("Transient", options: CommandOptions(recordUndo: false)) { _ = try $0.addWall(levelId: w.level, start: P2(0, 0), end: P2(10, 0)) }
        #expect(!w.store.canUndo)
        #expect(w.p.walls.count == 1)
        #expect(w.p.revision == 1)
        #expect(w.store.events(after: 0).events.count == 1)
    }
}

// MARK: - Concurrency: CONFLICT, WRITE_LOCKED, BUSY

@MainActor @Suite("Command concurrency") struct CommandConcurrencyTests {
    @Test func expectedRevisionMismatchConflicts() throws {
        let w = CTWorld()
        let a = try w.wall(P2(0, 0), P2(1000, 0))
        let before = w.p
        let e = ctThrows(.conflict) {
            try w.store.run("Stale", options: CommandOptions(expectedRevision: 0)) { try $0.moveObjects([a], by: P3(1, 0, 0)) }
        }
        #expect(e?.details["revision"] == "1")
        #expect(w.p == before)
        // The right revision passes.
        try w.store.run("Fresh", options: CommandOptions(expectedRevision: 1)) { try $0.moveObjects([a], by: P3(1, 0, 0)) }
        #expect(w.p.revision == 2)
    }

    @Test func expectedObjectRevisionsDetailsContainCurrentRev() throws {
        let w = CTWorld()
        let a = try w.wall(P2(0, 0), P2(1000, 0))
        let b = try w.wall(P2(0, 500), P2(1000, 500))
        try w.store.run("Edit a") { try $0.moveObjects([a], by: P3(0, 1, 0)) }
        let e = ctThrows(.conflict) {
            try w.store.run("Stale", options: CommandOptions(expectedObjectRevisions: [a: 1, b: 2])) { try $0.moveObjects([b], by: P3(0, 1, 0)) }
        }
        #expect(e?.ids == [a])
        #expect(e?.details[a.uuidString.lowercased()] == "3")
        #expect(e?.details[b.uuidString.lowercased()] == nil, "b is still at rev 2")
        #expect(e?.details["revision"] == "3")
        // Correct revisions pass.
        try w.store.run("Ok", options: CommandOptions(expectedObjectRevisions: [a: 3, b: 2])) { try $0.moveObjects([b], by: P3(0, 1, 0)) }
    }

    @Test func expectedObjectRevisionOfDeletedObjectSaysDeleted() throws {
        let w = CTWorld()
        let a = try w.wall(P2(0, 0), P2(1000, 0))
        try w.store.run("Delete") { try $0.deleteObjects([a]) }
        let e = ctThrows(.conflict) {
            try w.store.run("Stale", options: CommandOptions(expectedObjectRevisions: [a: 1])) { _ in }
        }
        #expect(e?.details[a.uuidString.lowercased()] == "deleted")
    }

    @Test func agentWritesFailWhenAgentWriteIsDisabled() throws {
        let w = CTWorld()
        let a = try w.wall(P2(0, 0), P2(1000, 0))
        w.store.agentWriteEnabled = false
        let before = w.p
        ctThrows(.writeLocked) { try w.store.run("Agent", options: .agent("c1")) { try $0.moveObjects([a], by: P3(1, 0, 0)) } }
        // Even a no-op agent write is refused: the switch is checked first.
        ctThrows(.writeLocked) { try w.store.run("Agent", options: .agent("c1")) { _ in } }
        #expect(w.p == before)
        #expect(w.store.lastSeq == 1)
    }

    @Test func userAndSystemWritesStillWorkWhenAgentWriteIsDisabled() throws {
        let w = CTWorld()
        let a = try w.wall(P2(0, 0), P2(1000, 0))
        w.store.agentWriteEnabled = false
        try w.store.run("User", options: .user) { try $0.moveObjects([a], by: P3(1, 0, 0)) }
        try w.store.run("System", options: CommandOptions(origin: .system)) { try $0.moveObjects([a], by: P3(1, 0, 0)) }
        #expect(w.p.wall(a)?.start == P2(2, 0))
        try w.store.undo()
        #expect(w.p.wall(a)?.start == P2(1, 0))
    }

    @Test func agentDryRunIsAllowedWhenWriteIsDisabled() throws {
        // Sensible: a dry run changes nothing, so an agent can still plan while writes are off.
        let w = CTWorld()
        let a = try w.wall(P2(0, 0), P2(1000, 0))
        w.store.agentWriteEnabled = false
        let r = try w.store.apply("Plan", options: CommandOptions(origin: .agent("c1"), dryRun: true)) { try $0.moveObjects([a], by: P3(5, 0, 0)) }
        #expect(!r.committed)
        #expect(r.changes.ids(.wall, [.modified]) == [a])
        #expect(w.p.wall(a)?.start == P2(0, 0))
    }

    @Test func agentUndoAndRedoAreWriteLockedToo() throws {
        let w = CTWorld()
        try w.wall(P2(0, 0), P2(1000, 0))
        w.store.agentWriteEnabled = false
        ctThrows(.writeLocked) { try w.store.undo(origin: .agent("c1")) }
        #expect(w.store.canUndo, "refused undo must not pop the entry")
        try w.store.undo()
        ctThrows(.writeLocked) { try w.store.redo(origin: .agent("c1")) }
        #expect(w.store.canRedo)
        #expect(try w.store.redo() != nil)
    }

    @Test func agentWriteToBusyObjectFailsWithBusy() throws {
        let w = CTWorld()
        let a = try w.wall(P2(0, 0), P2(1000, 0))
        let b = try w.wall(P2(0, 500), P2(1000, 500))
        w.store.beginInteraction([a], reason: "dragging")
        #expect(w.store.busy[a] == "dragging")
        let before = w.p
        let e = ctThrows(.busy) { try w.store.run("Agent", options: .agent("c1")) { try $0.moveObjects([a, b], by: P3(1, 0, 0)) } }
        #expect(e?.ids == [a])
        #expect(w.p == before)
        // Other objects and the user are not blocked.
        try w.store.run("Agent other", options: .agent("c1")) { try $0.moveObjects([b], by: P3(1, 0, 0)) }
        try w.store.run("User", options: .user) { try $0.moveObjects([a], by: P3(1, 0, 0)) }
        // Adding unrelated objects works while something is busy.
        try w.store.run("Agent add", options: .agent("c1")) { _ = try $0.addWall(levelId: w.level, start: P2(0, 900), end: P2(100, 900)) }
        w.store.endInteraction([a])
        #expect(w.store.busy.isEmpty)
        try w.store.run("Agent now", options: .agent("c1")) { try $0.moveObjects([a], by: P3(1, 0, 0)) }
    }

    @Test func busyWallBlocksCascadingDeleteOfItsOpening() throws {
        let w = CTWorld()
        let a = try w.wall(P2(0, 0), P2(4000, 0))
        let o = try w.opening(a, offset: 2000)
        w.store.beginInteraction([o], reason: "editing")
        let e = ctThrows(.busy) { try w.store.run("Agent", options: .agent("c1")) { try $0.deleteObjects([a]) } }
        #expect(e?.ids.contains(o) == true)
        w.store.endInteraction()
        #expect(w.store.busy.isEmpty)
    }

    @Test func agentUndoBusyWhenUndoWouldChangeBusyObject() throws {
        let w = CTWorld()
        let a = try w.wall(P2(0, 0), P2(1000, 0))
        let b = try w.wall(P2(0, 500), P2(1000, 500))
        try w.store.run("Move b") { try $0.moveObjects([b], by: P3(0, 10, 0)) }
        w.store.beginInteraction([b], reason: "dragging")
        let e = ctThrows(.busy) { try w.store.undo(origin: .agent("c1")) }
        #expect(e?.ids == [b])
        #expect(w.store.canUndo)
        #expect(w.p.wall(b)?.start.y == 510)
        // Busy on an unrelated object does not block the agent's undo.
        w.store.endInteraction()
        w.store.beginInteraction([a], reason: "dragging")
        #expect(try w.store.undo(origin: .agent("c1")) != nil)
        #expect(w.p.wall(b)?.start.y == 500)
        // The user's own undo is never blocked.
        w.store.beginInteraction([b], reason: "dragging")
        #expect(try w.store.redo() != nil)
    }

    @Test func replaceProjectClearsBusyAndHistory() throws {
        let w = CTWorld()
        let a = try w.wall(P2(0, 0), P2(1000, 0))
        w.store.beginInteraction([a], reason: "x")
        w.store.replaceProject(Project.empty(name: "Other"))
        #expect(w.store.busy.isEmpty)
        #expect(!w.store.canUndo && !w.store.canRedo)
        #expect(w.p.name == "Other")
    }
}

// MARK: - Events

@MainActor @Suite("Command events") struct CommandEventTests {
    @Test func eventsAfterOnEmptyStore() {
        let w = CTWorld()
        let r = w.store.events(after: 0)
        #expect(r.events.isEmpty)
        #expect(!r.truncated)
    }

    @Test func eventsAfterFiltersAndCarriesFields() throws {
        let w = CTWorld()
        let a = try w.wall(P2(0, 0), P2(1000, 0), name: "One")
        try w.store.run("Two", options: .agent("c1")) { try $0.moveObjects([a], by: P3(1, 0, 0)) }
        let all = w.store.events(after: 0)
        #expect(all.events.count == 2)
        #expect(!all.truncated)
        #expect(all.events[1].origin == .agent("c1"))
        #expect(all.events[1].name == "Two")
        #expect(all.events[1].revision == 2)
        #expect(all.events[1].changes.ids(.wall, [.modified]) == [a])
        let tail = w.store.events(after: 1)
        #expect(tail.events.map(\.seq) == [2])
        #expect(w.store.events(after: 2).events.isEmpty)
        #expect(!w.store.events(after: 2).truncated)
    }

    @Test func ringBufferKeepsLastTwoThousandAndReportsTruncation() throws {
        let w = CTWorld()
        for i in 0..<2010 {
            try w.store.run("n\(i)") { try $0.updateLevel(w.level, name: "L\(i)") }
        }
        #expect(w.store.lastSeq == 2010)
        let all = w.store.events(after: 0)
        #expect(all.events.count == 2000)
        #expect(all.truncated)
        #expect(all.events.first?.seq == 11)
        #expect(all.events.last?.seq == 2010)
        // Exactly at the edge nothing was missed.
        let edge = w.store.events(after: 10)
        #expect(edge.events.count == 2000)
        #expect(!edge.truncated)
        let recent = w.store.events(after: 2005)
        #expect(recent.events.count == 5)
        #expect(!recent.truncated)
        let off = w.store.events(after: 9)
        #expect(off.truncated)
    }

    @Test func observersReceiveEventsUntilRemoved() throws {
        let w = CTWorld()
        var seen: [String] = []
        let token = w.store.addObserver { seen.append($0.name) }
        try w.wall(P2(0, 0), P2(1000, 0), name: "A")
        w.store.removeObserver(token)
        try w.wall(P2(0, 5), P2(1000, 5), name: "B")
        #expect(seen == ["A"])
    }

    @Test func replaceProjectEmitsMonotonicResetEvent() throws {
        let w = CTWorld()
        try w.wall(P2(0, 0), P2(1000, 0))
        try w.wall(P2(0, 5), P2(1000, 5))
        var other = Project.empty(name: "Other")
        other.revision = 0
        w.store.replaceProject(other)
        #expect(w.p.revision == 3, "never goes below the previous revision + 1")
        let last = w.store.events(after: 0).events.last
        #expect(last?.kind == .reset)
        #expect(last?.origin == .system)
        #expect(last?.revision == 3)
        #expect(!w.store.isDirty)
        let newLevel = w.p.levels[0].id
        try w.store.run("Edit") { _ = try $0.addWall(levelId: newLevel, start: P2(0, 0), end: P2(1000, 0)) }
        #expect(w.store.isDirty)
        w.store.markSaved()
        #expect(!w.store.isDirty)
    }

    @Test func waitForEventsReturnsOnChange() async throws {
        let w = CTWorld()
        let store = w.store
        let after = store.lastSeq
        async let waiting = store.waitForEvents(after: after, timeout: 10)
        for _ in 0..<5 { await Task.yield() }
        try w.wall(P2(0, 0), P2(1000, 0), name: "Wake")
        let got = await waiting
        #expect(got.count == 1)
        #expect(got.first?.name == "Wake")
        #expect(got.first?.seq == after + 1)
    }

    @Test func waitForEventsReturnsImmediatelyWhenEventsAlreadyExist() async throws {
        let w = CTWorld()
        try w.wall(P2(0, 0), P2(1000, 0))
        let got = await w.store.waitForEvents(after: 0, timeout: 10)
        #expect(got.count == 1)
    }

    @Test func waitForEventsTimesOutWithEmptyList() async throws {
        let w = CTWorld()
        let start = Date()
        let got = await w.store.waitForEvents(after: w.store.lastSeq, timeout: 0.15)
        let elapsed = Date().timeIntervalSince(start)
        #expect(got.isEmpty)
        #expect(elapsed >= 0.1, "waited \(elapsed)")
        #expect(elapsed < 30, "waited \(elapsed)")  // generous: the main actor may be busy with other suites
        // Zero timeout never blocks.
        let none = await w.store.waitForEvents(after: w.store.lastSeq, timeout: 0)
        #expect(none.isEmpty)
    }

    @Test func dryRunDoesNotWakeWaiters() async throws {
        let w = CTWorld()
        let store = w.store
        async let waiting = store.waitForEvents(after: 0, timeout: 0.3)
        for _ in 0..<5 { await Task.yield() }
        _ = try store.apply("Preview", options: CommandOptions(dryRun: true)) { try $0.addWall(levelId: w.level, start: P2(0, 0), end: P2(10, 0)) }
        let got = await waiting
        #expect(got.isEmpty)
    }
}

// MARK: - Validator

@MainActor @Suite("Command validator") struct CommandValidatorTests {
    private func wallWorld(length: MM = 4000) throws -> (CTWorld, UUID) {
        let w = CTWorld()
        return (w, try w.wall(P2(0, 0), P2(length, 0)))
    }

    @Test func openingMustFitIntoWallAlongItsAxis() throws {
        let (w, a) = try wallWorld()
        ctThrows(.outOfRange) { try w.opening(a, offset: 100, width: 400) }
        ctThrows(.outOfRange) { try w.opening(a, offset: 3900, width: 400) }
        ctThrows(.outOfRange) { try w.opening(a, offset: -10, width: 400) }
        #expect(w.p.openings.isEmpty)
        // Exactly flush with both ends is fine.
        try w.opening(a, offset: 200, width: 400)
        try w.opening(a, offset: 3800, width: 400)
        #expect(w.p.openings.count == 2)
    }

    @Test func openingTooWideForWallIsRejected() throws {
        let (w, a) = try wallWorld(length: 700)
        ctThrows(.outOfRange) { try w.opening(a, offset: 350, width: 800) }
    }

    @Test func sillPlusHeightMustNotExceedWallHeight() throws {
        let (w, a) = try wallWorld()
        let e = ctThrows(.outOfRange) { try w.opening(a, offset: 2000, width: 1000, height: 1700, sill: 900, kind: .window) }
        #expect(e?.ids.count == 2)
        try w.opening(a, offset: 2000, width: 1000, height: 1600, sill: 900, kind: .window)
        #expect(w.p.openings.count == 1)
    }

    @Test func lowerWallHeightThanOpeningIsRejected() throws {
        let (w, a) = try wallWorld()
        try w.opening(a, offset: 2000)
        ctThrows(.outOfRange) { try w.store.run("Lower") { try $0.updateWall(a, height: 1800) } }
        #expect(w.p.wall(a)?.height == 2500)
    }

    @Test func shorteningWallBelowItsOpeningIsRejected() throws {
        let (w, a) = try wallWorld()
        try w.opening(a, offset: 3500, width: 800)
        ctThrows(.outOfRange) { try w.store.run("Shorten") { try $0.updateWall(a, end: P2(3000, 0)) } }
        #expect(w.p.wall(a)?.end == P2(4000, 0))
    }

    @Test func overlappingOpeningsAreRejected() throws {
        let (w, a) = try wallWorld()
        try w.opening(a, offset: 1000, width: 800)
        ctThrows(.invalidArgument) { try w.opening(a, offset: 1500, width: 800) }
        ctThrows(.invalidArgument) { try w.opening(a, offset: 1000, width: 100) }
        #expect(w.p.openings.count == 1)
        // Touching edges (1400 | 1400) do not overlap.
        try w.opening(a, offset: 1800, width: 800)
        #expect(w.p.openings.count == 2)
    }

    @Test func movingOpeningIntoAnotherIsRejected() throws {
        let (w, a) = try wallWorld()
        try w.opening(a, offset: 1000, width: 800)
        let b = try w.opening(a, offset: 3000, width: 800)
        ctThrows(.invalidArgument) { try w.store.run("Slide") { try $0.updateOpening(b, offset: 1500) } }
        #expect(w.p.opening(b)?.offset == 3000)
    }

    @Test func openingOnMissingWallIsNotFound() throws {
        let w = CTWorld()
        ctThrows(.notFound) { try w.opening(UUID(), offset: 1000) }
    }

    @Test func nonSimpleRoomPolygonIsRejected() throws {
        let w = CTWorld()
        let bowtie = [P2(0, 0), P2(2000, 2000), P2(2000, 0), P2(0, 2000)]
        ctThrows(.invalidArgument) { try w.store.run("Room") { _ = try $0.addRoom(levelId: w.level, name: "Bowtie", points: bowtie) } }
        ctThrows(.invalidArgument) { try w.store.run("Room") { _ = try $0.addRoom(levelId: w.level, name: "Line", points: [P2(0, 0), P2(1000, 0), P2(2000, 0)]) } }
        ctThrows(.invalidArgument) { try w.store.run("Room") { _ = try $0.addRoom(levelId: w.level, name: "Two", points: [P2(0, 0), P2(1000, 0)]) } }
        #expect(w.p.rooms.isEmpty)
        try w.store.run("Room") { _ = try $0.addRoom(levelId: w.level, name: "Square", points: [P2(0, 0), P2(2000, 0), P2(2000, 2000), P2(0, 2000)]) }
        #expect(w.p.rooms.count == 1)
    }

    @Test func updatingRoomToCrossingOutlineIsRejected() throws {
        let w = CTWorld()
        var rid = UUID()
        try w.store.run("Room") { rid = try $0.addRoom(levelId: w.level, name: "Square", points: [P2(0, 0), P2(2000, 0), P2(2000, 2000), P2(0, 2000)]) }
        ctThrows(.invalidArgument) {
            try w.store.run("Twist") { try $0.updateRoom(rid, points: [P2(0, 0), P2(2000, 2000), P2(2000, 0), P2(0, 2000)]) }
        }
    }

    @Test func invalidProductLinksAreRejected() throws {
        let w = CTWorld()
        for bad in ["ftp://example.com/x", "not a url", "javascript:alert(1)", "http://", "example.com", "file:///etc/passwd", ""] {
            var pr = CatalogProduct(name: "Chair")
            pr.links = [ProductLink(title: "Shop", url: bad)]
            ctThrows(.invalidArgument) { try w.store.run("Product") { $0.addProduct(pr) } }
        }
        #expect(w.p.products.isEmpty)
        var good = CatalogProduct(name: "Chair")
        good.links = [ProductLink(title: "Shop", url: "https://example.com/chair?x=1"), ProductLink(title: "Shop 2", url: "HTTP://example.org")]
        try w.store.run("Product") { $0.addProduct(good) }
        #expect(w.p.products.count == 1)
    }

    @Test func updatingProductToBadLinkIsRejected() throws {
        let w = CTWorld()
        let pr = CatalogProduct(name: "Chair")
        try w.store.run("Product") { $0.addProduct(pr) }
        ctThrows(.invalidArgument) {
            try w.store.run("Link") { try $0.updateProduct(pr.id) { $0.links = [ProductLink(title: "x", url: "gopher://x")] } }
        }
        ctThrows(.invalidArgument) { try w.store.run("Name") { try $0.updateProduct(pr.id) { $0.name = "  " } } }
        ctThrows(.outOfRange) { try w.store.run("Price") { try $0.updateProduct(pr.id) { $0.priceMinor = -1 } } }
        ctThrows(.outOfRange) { try w.store.run("Dim") { try $0.updateProduct(pr.id) { $0.dimensions = Size3(0, 10, 10) } } }
    }

    @Test func outOfRangeWallSizesAndCoordinatesAreRejected() throws {
        let w = CTWorld()
        ctThrows(.outOfRange) { try w.store.run("W") { _ = try $0.addWall(levelId: w.level, start: P2(0, 0), end: P2(1000, 0), thickness: 0) } }
        ctThrows(.outOfRange) { try w.store.run("W") { _ = try $0.addWall(levelId: w.level, start: P2(0, 0), end: P2(1000, 0), thickness: 100_001) } }
        ctThrows(.outOfRange) { try w.store.run("W") { _ = try $0.addWall(levelId: w.level, start: P2(0, 0), end: P2(1000, 0), height: 0) } }
        ctThrows(.outOfRange) { try w.store.run("W") { _ = try $0.addWall(levelId: w.level, start: P2(0, 0), end: P2(coordinateLimit + 1, 0)) } }
        ctThrows(.invalidArgument) { try w.store.run("W") { _ = try $0.addWall(levelId: w.level, start: P2(5, 5), end: P2(5, 5)) } }
        ctThrows(.notFound) { try w.store.run("W") { _ = try $0.addWall(levelId: UUID(), start: P2(0, 0), end: P2(5, 0)) } }
        #expect(w.p.walls.isEmpty)
        try w.store.run("W") { _ = try $0.addWall(levelId: w.level, start: P2(-coordinateLimit, 0), end: P2(coordinateLimit, 0), thickness: 100_000, height: 1) }
        #expect(w.p.walls.count == 1)
    }

    @Test func outOfRangeFurnitureSizesAreRejected() throws {
        let w = CTWorld()
        let def = w.definition()
        ctThrows(.outOfRange) { try w.store.run("I") { _ = try $0.addInstance(definitionId: def, levelId: w.level, position: P3(0, 0, 0), size: Size3(0, 100, 100)) } }
        ctThrows(.outOfRange) { try w.store.run("I") { _ = try $0.addInstance(definitionId: def, levelId: w.level, position: P3(0, 0, 0), size: Size3(100, 100_001, 100)) } }
        ctThrows(.outOfRange) { try w.store.run("I") { _ = try $0.addInstance(definitionId: def, levelId: w.level, position: P3(coordinateLimit + 1, 0, 0)) } }
        let bad = FurnitureDefinition(name: "Bad", category: "t", size: Size3(0, 1, 1),
                                      components: [Component(name: "c", shape: .box, position: .zero, size: Size3(1, 1, 1))])
        ctThrows(.outOfRange) { try w.store.run("D") { $0.addDefinition(bad) } }
        let empty = FurnitureDefinition(name: "Empty", category: "t", size: Size3(1, 1, 1), components: [])
        ctThrows(.invalidArgument) { try w.store.run("D") { $0.addDefinition(empty) } }
        let unnamed = FurnitureDefinition(name: " ", category: "t", size: Size3(1, 1, 1), components: empty.components + [Component(name: "c", shape: .box, position: .zero, size: Size3(1, 1, 1))])
        ctThrows(.invalidArgument) { try w.store.run("D") { $0.addDefinition(unnamed) } }
        #expect(w.p.instances.isEmpty)
        #expect(w.p.definitions.count == 1)
        try w.store.run("I") { _ = try $0.addInstance(definitionId: def, levelId: w.level, position: P3(0, 0, 0), size: Size3(1, 100_000, 50)) }
    }

    @Test func otherRangeChecks() throws {
        let w = CTWorld()
        ctThrows(.outOfRange) { try w.store.run("L") { try $0.updateLevel(w.level, height: 0) } }
        ctThrows(.invalidArgument) { try w.store.run("L") { try $0.updateLevel(w.level, name: "  ") } }
        let hot = Material(name: "Hot", color: RGBColor(1, 2, 3), roughness: 2)
        ctThrows(.outOfRange) { try w.store.run("M") { $0.addMaterial(hot) } }
        ctThrows(.outOfRange) { try w.store.run("S") { $0.updateSettings { $0.snap.grid = 0 } } }
        ctThrows(.outOfRange) { try w.store.run("S") { $0.updateSettings { $0.snap.angleStep = 0 } } }
        var cam = CameraState.default
        cam.distance = 1
        ctThrows(.outOfRange) { try w.store.run("C", options: CommandOptions(recordUndo: false)) { $0.setCamera(cam) } }
        ctThrows(.invalidArgument) { try w.store.run("Dim") { _ = try $0.addDimension(levelId: w.level, a: P2(1, 1), b: P2(1, 1)) } }
        #expect(w.p.revision == 0)
    }

    @Test func duplicateObjectIdIsRejected() throws {
        let w = CTWorld()
        let id = try w.wall(P2(0, 0), P2(1000, 0))
        ctThrows(.invalidArgument) { try w.store.run("Dup") { _ = try $0.addWall(levelId: w.level, start: P2(0, 5), end: P2(9, 5), id: id) } }
        #expect(w.p.walls.count == 1)
    }

    @Test func lastLevelCannotBeRemoved() throws {
        let w = CTWorld()
        let e = ctThrows(.invalidArgument) { try w.store.run("Del") { try $0.deleteObjects([w.level]) } }
        #expect(e?.ids == [w.level])
        #expect(w.p.levels.count == 1)
        // Bypassing deleteObjects is caught by the validator.
        ctThrows(.invalidArgument) { try w.store.run("Raw") { $0.levels.removeAll() } }
        var up = UUID()
        try w.store.run("Add") { up = $0.addLevel(name: "Up") }
        try w.store.run("Del") { try $0.deleteObjects([w.level]) }
        #expect(w.p.levels.map(\.id) == [up])
        ctThrows(.invalidArgument) { try w.store.run("Del") { try $0.deleteObjects([up]) } }
        // Deleting both in one go must not leave the project without a level.
        try w.store.run("Add") { $0.addLevel(name: "Third") }
        ctThrows(.invalidArgument) { try w.store.run("Del both") { try $0.deleteObjects(w.p.levels.map(\.id)) } }
        #expect(w.p.levels.count == 2)
    }

    @Test func lockedLevelCannotBeDeletedNorGetNewContent() throws {
        let w = CTWorld()
        var up = UUID()
        try w.store.run("Add") { up = $0.addLevel(name: "Up") }
        try w.store.run("Lock") { try $0.setLocked([up], true) }
        ctThrows(.locked) { try w.store.run("Del") { try $0.deleteObjects([up]) } }
        ctThrows(.locked) { try w.wall(P2(0, 0), P2(10, 0), level: up) }
        try w.store.run("Unlock") { try $0.setLocked([up], false) }
        try w.wall(P2(0, 0), P2(10, 0), level: up)
    }
}
