import AppKit
import SwiftUI
import Testing
import RoomsmithCore
@testable import Roomsmith

/// Serialized: the hosted windows and the async model observation interfere when tests run in parallel.
/// The Measure tool in the 3D view (two clicks on surfaces give a distance) and the tool availability per layout.
@Suite(.serialized)
@MainActor
struct MeasureTool3DTests {
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let v = view as? T { return v }
        for s in view.subviews { if let f = find(type, in: s) { return f } }
        return nil
    }

    private func sceneWindow() async throws -> (AppModel, NSWindow, SceneARView, UUID) {
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
        let window = QuietWindows.make(width: 1500, height: 900)
        window.contentView = host
        QuietWindows.show(window)
        for _ in 0..<30 { try await Task.sleep(for: .milliseconds(50)); window.layoutIfNeeded() }
        let view = try #require(find(SceneARView.self, in: host))
        #expect(window.makeFirstResponder(view))
        return (model, window, view, id)
    }

    /// Lets the main actor run the model observation (tool changes reach the renderer through a task).
    private func settle() async throws {
        for _ in 0..<5 { try await Task.sleep(for: .milliseconds(100)) }
    }

    private func click(_ r: SceneRenderer, at p: SIMD2<Double>) {
        r.mouseDown(point: p, shift: false, option: false)
        r.mouseUp(point: p, shift: false)
    }

    private func escape(_ window: NSWindow) {
        window.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                          context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53)!)
    }

    // MARK: Availability

    @Test func onlySelectHandAndMeasureWorkIn3D() {
        let working = EditorTool.pickerTools.filter { $0.isAvailable(in: .scene) }
        #expect(Set(working) == [.select, .hand, .measure])
        for tool in EditorTool.allCases {
            #expect(tool.isAvailable(in: .plan))
            #expect(tool.isAvailable(in: .split))
        }
        #expect(!EditorTool.pickerTools.contains(.calibrate))
        #expect(EditorTool.wall.help(in: .scene).contains("plan view"))
        #expect(EditorTool.wall.help(in: .plan) == EditorTool.wall.title)
    }

    @Test func switchingTo3DOnlyFallsBackToSelectForAPlanTool() async throws {
        let (model, _, _, _) = try await sceneWindow()
        model.layout = .plan
        model.tool = .wall
        try await settle()
        #expect(model.tool == .wall)
        model.layout = .scene
        try await settle()
        #expect(model.tool == .select)
        model.tool = .measure
        try await settle()
        #expect(model.tool == .measure, "the Measure tool stays available in 3D")
    }

    // MARK: Measuring

    @Test func twoClicksMeasureAndChangeNothingElse() async throws {
        let (model, _, view, id) = try await sceneWindow()
        let r = view.renderer
        model.tool = .measure
        try await settle()
        #expect(r.measureActive)
        #expect(!r.allowsEditing)
        let before = try #require(model.project.instance(id)).position
        let revision = model.store.contentRevision
        let a = SIMD2(Double(view.bounds.midX), Double(view.bounds.midY))
        let b = SIMD2(a.x + 160, a.y - 90)
        click(r, at: a)
        #expect(r.measure.isPending)
        click(r, at: b)
        let m = try #require(r.measure.finished)
        #expect(m.distanceMm > 0)
        #expect(model.selection == [id], "measuring must not change the selection")
        #expect(r.gizmoOrigin == nil)
        #expect(try #require(model.project.instance(id)).position == before)
        #expect(model.store.contentRevision == revision)
        // The overlay shows the same text as the plan format.
        let shape = try #require(r.currentMeasureShape())
        #expect(shape.lines == m.labelLines(unit: model.project.settings.displayUnit))
        #expect(shape.a != nil && shape.b != nil)
        // Third click starts over.
        click(r, at: a)
        #expect(r.measure.isPending && r.measure.b == nil)
    }

    @Test func dragWithTheMeasureToolOrbitsAndSetsNoPoint() async throws {
        let (model, _, view, _) = try await sceneWindow()
        let r = view.renderer
        model.tool = .measure
        let yaw = r.camera.rig.yaw, target = r.camera.rig.target
        let start = SIMD2(Double(view.bounds.midX), Double(view.bounds.midY))
        r.mouseDown(point: start, shift: false, option: false)
        var pt = start
        for _ in 0..<10 { pt.x += 8; r.mouseDragged(point: pt, dx: 8, dy: 0, shift: false, option: false) }
        r.mouseUp(point: pt, shift: false)
        #expect(r.measure.isEmpty)
        #expect(r.camera.rig.yaw != yaw || r.camera.rig.target != target)
    }

    @Test func theMeasurementStaysOnItsWorldPointsWhenTheCameraMoves() async throws {
        let (model, _, view, _) = try await sceneWindow()
        let r = view.renderer
        model.tool = .measure
        let a = SIMD2(Double(view.bounds.midX), Double(view.bounds.midY))
        click(r, at: a)
        click(r, at: SIMD2(a.x + 160, a.y - 90))
        let world = try #require(r.measure.finished)
        let shapeBefore = try #require(r.currentMeasureShape())
        r.camera.orbit(dx: 40, dy: 10)
        #expect(r.measure.finished == world, "the world points do not move with the camera")
        let shapeAfter = try #require(r.currentMeasureShape())
        #expect(shapeAfter.a != shapeBefore.a)
        #expect(shapeAfter.lines == shapeBefore.lines)
    }

    @Test func escapeClearsTheMeasurementThenLeavesTheTool() async throws {
        let (model, window, view, _) = try await sceneWindow()
        let r = view.renderer
        model.tool = .measure
        click(r, at: SIMD2(Double(view.bounds.midX), Double(view.bounds.midY)))
        #expect(!r.measure.isEmpty)
        escape(window)
        #expect(r.measure.isEmpty)
        #expect(model.tool == .measure)
        escape(window)
        #expect(model.tool == .select)
    }

    @Test func leavingTheToolForgetsTheMeasurement() async throws {
        let (model, _, view, _) = try await sceneWindow()
        let r = view.renderer
        model.tool = .measure
        try await settle()
        click(r, at: SIMD2(Double(view.bounds.midX), Double(view.bounds.midY)))
        model.tool = .select
        try await settle()
        #expect(r.measure.isEmpty)
        #expect(r.allowsEditing)
    }
}
