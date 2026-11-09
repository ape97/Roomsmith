import AppKit
import SwiftUI
import Testing
import RoomsmithCore
@testable import Roomsmith

@MainActor
struct HostedDragTests {
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let v = view as? T { return v }
        for s in view.subviews { if let f = find(type, in: s) { return f } }
        return nil
    }

    @Test func draggingInTheHostedWindowMovesFurniture() throws {
        let ws = Workspace()
        let model = ws.active
        let def = try #require(BuiltinCatalog.definition("sofa.3seat.2100"))
        var newId: UUID?
        let level = try #require(model.project.levels.first).id
        model.perform("Add") { p in
            p.addDefinition(def)
            newId = try p.addInstance(definitionId: def.id, levelId: level, position: P3(3000, 3000, 0))
        }
        let id = try #require(newId)
        model.layout = .split
        let root = ContentView().environment(ws).environment(model).environment(MaterialEditorState())
        let host = NSHostingView(rootView: root)
        let window = QuietWindows.make(width: 1500, height: 900)
        window.contentView = host
        QuietWindows.show(window)
        window.layoutIfNeeded()
        for _ in 0..<20 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)); window.layoutIfNeeded() }
        let view = try #require(find(PlanNSView.self, in: host))
        view.fit(selectionOnly: false)
        let start = view.vp.screen(V2(3000, 3000))
        let before = try #require(model.project.instance(id)).position
        func ev(_ t: NSEvent.EventType, _ pt: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: t, location: view.convert(pt, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        window.sendEvent(ev(.leftMouseDown, start))
        for i in 1...10 {
            window.sendEvent(ev(.leftMouseDragged, CGPoint(x: start.x + Double(i) * 8, y: start.y)))
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        window.sendEvent(ev(.leftMouseUp, CGPoint(x: start.x + 80, y: start.y)))
        let after = try #require(model.project.instance(id)).position
        #expect(after.x > before.x, "furniture did not move: \(before) -> \(after), error: \(model.lastError ?? "none")")
    }

    @Test func draggingIn3DMovesFurniture() throws {
        let ws = Workspace()
        let model = ws.active
        let def = try #require(BuiltinCatalog.definition("sofa.3seat.2100"))
        var newId: UUID?
        let level = try #require(model.project.levels.first).id
        model.perform("Add") { p in
            p.addDefinition(def)
            newId = try p.addInstance(definitionId: def.id, levelId: level, position: P3(3000, 3000, 0))
        }
        let id = try #require(newId)
        model.layout = .scene
        let root = ContentView().environment(ws).environment(model).environment(MaterialEditorState())
        let host = NSHostingView(rootView: root)
        let window = QuietWindows.make(width: 1500, height: 900)
        window.contentView = host
        QuietWindows.show(window)
        for _ in 0..<40 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)); window.layoutIfNeeded() }
        let view = try #require(find(SceneARView.self, in: host))
        let r = view.renderer
        model.selection = [id]
        for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        var found: CGPoint?
        outer: for y in stride(from: 20.0, to: view.bounds.height, by: 12) {
            for x in stride(from: 20.0, to: view.bounds.width, by: 12) {
                if r.furnitureMoveCandidate(at: SIMD2(x, y)) != nil { found = CGPoint(x: x, y: y); break outer }
            }
        }
        let start = try #require(found, "no pick point on the selected sofa")
        func ev(_ t: NSEvent.EventType, _ pt: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: t, location: view.convert(pt, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let before = try #require(model.project.instance(id)).position
        window.sendEvent(ev(.leftMouseDown, start))
        for i in 1...10 {
            window.sendEvent(ev(.leftMouseDragged, CGPoint(x: start.x + Double(i) * 8, y: start.y)))
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        window.sendEvent(ev(.leftMouseUp, CGPoint(x: start.x + 80, y: start.y)))
        let after = try #require(model.project.instance(id)).position
        #expect(after != before, "furniture did not move in 3D: \(before) -> \(after), error: \(model.lastError ?? "none")")
    }

    /// Esc in the 3D view: cancels a running drag first; with nothing to cancel it clears the selection (not in first person).
    @Test func escapeClearsTheSelectionIn3D() throws {
        let ws = Workspace()
        let model = ws.active
        let def = try #require(BuiltinCatalog.definition("sofa.3seat.2100"))
        var newId: UUID?
        let level = try #require(model.project.levels.first).id
        model.perform("Add") { p in
            p.addDefinition(def)
            newId = try p.addInstance(definitionId: def.id, levelId: level, position: P3(3000, 3000, 0))
        }
        let id = try #require(newId)
        model.layout = .scene
        let host = NSHostingView(rootView: ContentView().environment(ws).environment(model).environment(MaterialEditorState()))
        let window = QuietWindows.make(width: 1500, height: 900)
        window.contentView = host
        QuietWindows.show(window)
        for _ in 0..<40 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)); window.layoutIfNeeded() }
        let r = try #require(find(SceneARView.self, in: host)).renderer
        model.selection = [id]
        #expect(r.keyDown(code: KeyCode.escape, modifiers: []))
        #expect(model.selection.isEmpty)
        #expect(!r.keyDown(code: KeyCode.escape, modifiers: []), "Esc with nothing selected is not used")
        model.selection = [id]
        r.setViewMode(.firstPerson)
        _ = r.keyDown(code: KeyCode.escape, modifiers: [])
        #expect(model.selection == [id], "first person keeps the selection")
    }

    /// Esc while a camera drag runs or a press is still undecided must not clear the selection.
    @Test func escapeKeepsTheSelectionDuringACameraDragOrPendingClick() throws {
        let ws = Workspace()
        let model = ws.active
        let def = try #require(BuiltinCatalog.definition("sofa.3seat.2100"))
        var newId: UUID?
        let level = try #require(model.project.levels.first).id
        model.perform("Add") { p in
            p.addDefinition(def)
            newId = try p.addInstance(definitionId: def.id, levelId: level, position: P3(3000, 3000, 0))
        }
        let id = try #require(newId)
        model.layout = .scene
        let host = NSHostingView(rootView: ContentView().environment(ws).environment(model).environment(MaterialEditorState()))
        let window = QuietWindows.make(width: 1500, height: 900)
        window.contentView = host
        QuietWindows.show(window)
        for _ in 0..<40 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)); window.layoutIfNeeded() }
        let r = try #require(find(SceneARView.self, in: host)).renderer
        model.selection = [id]
        // Press in a corner (no furniture there): undecided click.
        let start = SIMD2<Double>(5, 5)
        r.mouseDown(point: start, shift: false, option: false)
        #expect(r.pendingClick != nil)
        _ = r.keyDown(code: KeyCode.escape, modifiers: [])
        #expect(model.selection == [id], "pending click keeps the selection")
        // Past the slop: camera drag.
        r.mouseDragged(point: SIMD2<Double>(80, 5), dx: 75, dy: 0, shift: false, option: false)
        #expect(r.drag != nil)
        _ = r.keyDown(code: KeyCode.escape, modifiers: [])
        #expect(model.selection == [id], "camera drag keeps the selection")
        r.mouseUp(point: SIMD2<Double>(80, 5), shift: false)
    }
}
