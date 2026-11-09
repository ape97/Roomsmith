import AppKit
import SwiftUI
import Testing
import RoomsmithCore
@testable import Roomsmith

/// The Hand tool only looks: it pans the plan, orbits the 3D camera, and never selects, moves or deletes anything.
@MainActor
struct HandToolTests {
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let v = view as? T { return v }
        for s in view.subviews { if let f = find(type, in: s) { return f } }
        return nil
    }

    // MARK: Plan

    private func planSetup() throws -> (AppModel, PlanNSView, UUID) {
        var p = AppModel.starterProject()
        let level = try #require(p.levels.first).id
        let def = try #require(BuiltinCatalog.definition("sofa.3seat.2100"))
        p.addDefinition(def)
        let id = try p.addInstance(definitionId: def.id, levelId: level, position: P3(3000, 3000, 0))
        let model = AppModel(project: p)
        let view = PlanNSView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.setFrameSize(NSSize(width: 800, height: 600))
        view.fit(selectionOnly: false)
        return (model, view, id)
    }

    private func mouse(_ type: NSEvent.EventType, _ view: PlanNSView, at pt: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(pt, to: nil), modifierFlags: [], timestamp: 0,
                           windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func letter(_ c: String, code: UInt16, window: NSWindow?, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window?.windowNumber ?? 0,
                         context: nil, characters: c, charactersIgnoringModifiers: c, isARepeat: false, keyCode: code)!
    }

    @Test func handToolHasItsOwnToolbarEntryNextToSelect() {
        let all = EditorTool.allCases
        let i = all.firstIndex(of: .select)!
        #expect(all[i + 1] == .hand)
        #expect(EditorTool.hand.symbol == "hand.raised")
        #expect(!EditorTool.hand.title.isEmpty)
    }

    @Test func draggingInThePlanWithTheHandToolPansAndChangesNothing() throws {
        let (model, view, id) = try planSetup()
        model.selection = [id]
        model.tool = .hand
        view.sync(projectId: model.project.id, revision: model.store.contentRevision, levelId: model.activeLevelId, tool: .hand, frameRequest: 0)
        let before = try #require(model.project.instance(id)).position
        let dirty = model.store.isDirty
        let start = view.vp.screen(V2(3000, 3000))
        view.mouseDown(with: mouse(.leftMouseDown, view, at: start))
        for i in 1...10 { view.mouseDragged(with: mouse(.leftMouseDragged, view, at: CGPoint(x: start.x + Double(i) * 8, y: start.y))) }
        view.mouseUp(with: mouse(.leftMouseUp, view, at: CGPoint(x: start.x + 80, y: start.y)))
        #expect(try #require(model.project.instance(id)).position == before)
        #expect(model.store.isDirty == dirty)
        #expect(model.selection == [id])
        let moved = view.vp.screen(V2(3000, 3000))
        #expect(abs(moved.x - (start.x + 80)) < 1, "plan did not pan with the drag: \(start) -> \(moved)")
        #expect(!view.panning)
    }

    @Test func clickingInThePlanWithTheHandToolSelectsNothing() throws {
        let (model, view, id) = try planSetup()
        model.tool = .hand
        view.sync(projectId: model.project.id, revision: model.store.contentRevision, levelId: model.activeLevelId, tool: .hand, frameRequest: 0)
        let p = view.vp.screen(V2(3000, 3000))
        view.mouseDown(with: mouse(.leftMouseDown, view, at: p))
        view.mouseUp(with: mouse(.leftMouseUp, view, at: p))
        #expect(model.selection.isEmpty)
        #expect(model.project.instance(id) != nil)
    }

    @Test func planKeysSwitchBetweenSelectAndHandAndDeleteDoesNothingInHandMode() throws {
        let (model, view, id) = try planSetup()
        view.keyDown(with: letter("h", code: 4, window: view.window))
        #expect(model.tool == .hand)
        model.selection = [id]
        view.keyDown(with: letter("\u{7F}", code: 51, window: view.window))
        #expect(model.project.instance(id) != nil)
        view.keyDown(with: letter("v", code: 9, window: view.window))
        #expect(model.tool == .select)
        view.keyDown(with: letter("h", code: 4, window: view.window, modifiers: .command))
        #expect(model.tool == .select, "Command-H must not switch tools")
    }

    @Test func escapeLeavesTheHandToolInThePlan() throws {
        let (model, view, _) = try planSetup()
        model.tool = .hand
        view.keyDown(with: letter("\u{1B}", code: 53, window: view.window))
        #expect(model.tool == .select)
    }

    // MARK: 3D

    private func sceneWindow() throws -> (AppModel, NSWindow, SceneARView, UUID) {
        let ws = Workspace()
        let model = ws.active
        model.layout = .scene
        let def = try #require(BuiltinCatalog.definition("sofa.3seat.2100"))
        var newId: UUID?
        let level = try #require(model.project.levels.first).id
        model.perform("Add") { p in
            p.addDefinition(def)
            newId = try p.addInstance(definitionId: def.id, levelId: level, position: P3(3000, 3000, 0))
        }
        let id = try #require(newId)
        model.selection = [id]
        let host = NSHostingView(rootView: ContentView().environment(ws).environment(model).environment(MaterialEditorState()))
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1500, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        for _ in 0..<30 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)); window.layoutIfNeeded() }
        let view = try #require(find(SceneARView.self, in: host))
        #expect(window.makeFirstResponder(view))
        return (model, window, view, id)
    }

    @Test func sceneKeysSwitchToolsAndEscapeLeavesTheHandTool() throws {
        let (model, window, _, _) = try sceneWindow()
        window.sendEvent(letter("h", code: 4, window: window))
        #expect(model.tool == .hand)
        window.sendEvent(letter("\u{1B}", code: 53, window: window))
        #expect(model.tool == .select)
        window.sendEvent(letter("h", code: 4, window: window))
        window.sendEvent(letter("v", code: 9, window: window))
        #expect(model.tool == .select)
    }

    @Test func deleteInTheHandToolKeepsTheFurnitureIn3D() throws {
        let (model, window, _, id) = try sceneWindow()
        model.tool = .hand
        window.sendEvent(letter("\u{7F}", code: 51, window: window))
        #expect(model.project.instance(id) != nil)
        #expect(model.selection == [id])
    }

    @Test func spaceHeldIsATemporaryHandIn3D() throws {
        let (model, window, view, id) = try sceneWindow()
        window.sendEvent(letter(" ", code: 49, window: window))
        #expect(view.renderer.spaceHeld)
        #expect(view.renderer.handActive)
        window.sendEvent(letter("\u{7F}", code: 51, window: window))
        #expect(model.project.instance(id) != nil)
        let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                  context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
        window.sendEvent(up)
        #expect(!view.renderer.spaceHeld)
        #expect(!view.renderer.handActive)
        #expect(model.tool == .select)
    }

    @Test func draggingIn3DWithTheHandToolMovesTheCameraAndNotTheFurniture() throws {
        let (model, _, view, id) = try sceneWindow()
        model.tool = .hand
        let r = view.renderer
        let before = try #require(model.project.instance(id)).position
        let rigBefore = r.camera.rig
        let start = SIMD2<Double>(Double(view.bounds.midX), Double(view.bounds.midY))
        r.mouseDown(point: start, shift: false, option: false)
        var pt = start
        for _ in 0..<10 {
            pt.x += 8
            r.mouseDragged(point: pt, dx: 8, dy: 0, shift: false, option: false)
        }
        guard case .camera = r.drag else { Issue.record("drag is not a camera drag: \(String(describing: r.drag))"); return }
        r.mouseUp(point: pt, shift: false)
        #expect(try #require(model.project.instance(id)).position == before)
        #expect(r.camera.rig.yaw != rigBefore.yaw || r.camera.rig.target != rigBefore.target)
    }

    @Test func releasingSpaceBeforeTheMouseDoesNotSelectIn3D() throws {
        let (model, _, view, id) = try sceneWindow()
        let r = view.renderer
        let pt = SIMD2<Double>(Double(view.bounds.midX), Double(view.bounds.midY))
        // Precondition: without Space the same click picks the piece, so the test below can really fail.
        model.selection = []
        r.mouseDown(point: pt, shift: false, option: false)
        r.mouseUp(point: pt, shift: false)
        try #require(model.selection == [id], "the click at the view centre must hit the piece")
        model.selection = []
        _ = r.keyDown(code: KeyCode.space, modifiers: [])
        r.mouseDown(point: pt, shift: false, option: false)
        _ = r.keyUp(code: KeyCode.space)
        r.mouseUp(point: pt, shift: false)
        #expect(model.selection.isEmpty)
        #expect(model.project.instance(id) != nil)
    }

    @Test func clickingIn3DWithTheHandToolDoesNotChangeTheSelection() throws {
        let (model, _, view, id) = try sceneWindow()
        model.tool = .hand
        let r = view.renderer
        let pt = SIMD2<Double>(Double(view.bounds.midX), Double(view.bounds.midY))
        r.mouseDown(point: pt, shift: false, option: false)
        r.mouseUp(point: pt, shift: false)
        #expect(model.selection == [id])
        #expect(r.gizmoOrigin == nil)
        #expect(!r.allowsEditing)
    }
}
