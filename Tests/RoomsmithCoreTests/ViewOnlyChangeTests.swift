import Testing
import Foundation
@testable import RoomsmithCore

/// Moving the live camera is view state: it must not mark a clean document as edited and must not make an agent's
/// `expectedRevision` stale.
@MainActor
struct ViewOnlyChangeTests {
    let cam = CameraState(mode: .orbit, target: P3(1000, 2000, 0), distance: 5000, yawDeg: 10, pitchDeg: -20)
    let viewOpts = CommandOptions(origin: .system, recordUndo: false)

    @Test func cameraMoveKeepsCleanDocumentClean() throws {
        let w = CTWorld()
        w.store.markSaved()
        let before = w.store.project.revision
        try w.store.run("Camera", options: viewOpts) { $0.setCamera(cam) }
        #expect(w.store.project.revision == before + 1)   // subscribers still see the change
        #expect(!w.store.isDirty)
        #expect(w.store.project.camera == cam)
    }

    @Test func cameraMoveKeepsDirtyDocumentDirty() throws {
        let w = CTWorld()
        w.store.markSaved()
        try w.wall(P2(0, 0), P2(3000, 0))
        try w.store.run("Camera", options: viewOpts) { $0.setCamera(cam) }
        #expect(w.store.isDirty)
        w.store.markSaved()
        #expect(!w.store.isDirty)
    }

    @Test func expectedRevisionSurvivesCameraMovesButNotContentEdits() throws {
        let w = CTWorld()
        let seen = w.store.project.revision
        try w.store.run("Camera", options: viewOpts) { $0.setCamera(cam) }
        // Only the camera moved since `seen`: the agent write is accepted.
        try w.store.run("Agent wall", options: CommandOptions(origin: .agent("t"), expectedRevision: seen)) {
            _ = try $0.addWall(levelId: w.level, start: P2(0, 0), end: P2(2000, 0))
        }
        // Now content changed after `seen`: stale.
        #expect(throws: CommandError.self) {
            try w.store.run("Agent wall 2", options: CommandOptions(origin: .agent("t"), expectedRevision: seen)) {
                _ = try $0.addWall(levelId: w.level, start: P2(0, 1000), end: P2(2000, 1000))
            }
        }
        // A revision from the future is never accepted.
        #expect(throws: CommandError.self) {
            try w.store.run("Agent wall 3", options: CommandOptions(origin: .agent("t"), expectedRevision: w.store.project.revision + 5)) {
                _ = try $0.addWall(levelId: w.level, start: P2(0, 2000), end: P2(2000, 2000))
            }
        }
    }

    @Test func undoAndRedoMakeOlderExpectedRevisionsStale() throws {
        let w = CTWorld()
        try w.wall(P2(0, 0), P2(3000, 0))
        try w.store.run("Camera", options: viewOpts) { $0.setCamera(cam) }
        let seen = w.store.project.revision
        try w.store.undo()
        #expect(throws: CommandError.self) {
            try w.store.run("Agent wall", options: CommandOptions(origin: .agent("t"), expectedRevision: seen)) {
                _ = try $0.addWall(levelId: w.level, start: P2(0, 1000), end: P2(2000, 1000))
            }
        }
        let afterUndo = w.store.project.revision
        try w.store.redo()
        #expect(throws: CommandError.self) {
            try w.store.run("Agent wall", options: CommandOptions(origin: .agent("t"), expectedRevision: afterUndo)) {
                _ = try $0.addWall(levelId: w.level, start: P2(0, 1000), end: P2(2000, 1000))
            }
        }
    }

    @Test func recoveredUnsavedDocumentStaysDirtyAfterCameraMove() throws {
        let w = CTWorld()
        w.store.replaceProject(Project.empty(name: "Recovered"), markSaved: false)
        #expect(w.store.isDirty)
        try w.store.run("Camera", options: viewOpts) { $0.setCamera(cam) }
        #expect(w.store.isDirty)
    }
}

@MainActor
struct ContentRevisionTests {
    let cam = CameraState(mode: .orbit, target: P3(1000, 2000, 0), distance: 5000, yawDeg: 10, pitchDeg: -20)
    let viewOpts = CommandOptions(origin: .system, recordUndo: false)

    @Test func cameraOnlyChangeKeepsContentRevision() throws {
        let w = CTWorld()
        let c = w.store.contentRevision, r = w.store.project.revision
        try w.store.run("Camera", options: viewOpts) { $0.setCamera(cam) }
        #expect(w.store.contentRevision == c)
        #expect(w.store.project.revision == r + 1)
    }

    @Test func realEditAndUndoRedoBumpContentRevision() throws {
        let w = CTWorld()
        let c0 = w.store.contentRevision
        try w.wall(P2(0, 0), P2(3000, 0))
        let c1 = w.store.contentRevision
        #expect(c1 > c0 && c1 == w.store.project.revision)
        try w.store.undo()
        let c2 = w.store.contentRevision
        #expect(c2 > c1)
        try w.store.redo()
        #expect(w.store.contentRevision > c2)
    }
}
