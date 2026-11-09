import AppKit
import Testing
import RoomsmithCore
@testable import Roomsmith

@MainActor
struct PlanDragTests {
    /// A model with one sofa and a plan view in an off-screen window.
    private func setup() throws -> (AppModel, PlanNSView, UUID) {
        var p = AppModel.starterProject()
        let level = try #require(p.levels.first).id
        let def = try #require(BuiltinCatalog.definition("sofa.3seat.2100"))
        p.addDefinition(def)
        let id = try p.addInstance(definitionId: def.id, levelId: level, position: P3(3000, 3000, 0))
        let model = AppModel(project: p)
        let view = PlanNSView(model: model)
        let window = QuietWindows.make(width: 800, height: 600, styleMask: [.titled])
        window.contentView = view
        view.setFrameSize(NSSize(width: 800, height: 600))
        view.fit(selectionOnly: false)
        return (model, view, id)
    }

    private func event(_ type: NSEvent.EventType, _ view: PlanNSView, at pt: CGPoint) -> NSEvent {
        let w = view.convert(pt, to: nil)
        return NSEvent.mouseEvent(with: type, location: w, modifierFlags: [], timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
                                  context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @Test func draggingFurnitureInThePlanMovesIt() throws {
        let (model, view, id) = try setup()
        let before = try #require(model.project.instance(id)).position
        let start = view.vp.screen(V2(3000, 3000))
        view.mouseDown(with: event(.leftMouseDown, view, at: start))
        for i in 1...10 {
            view.mouseDragged(with: event(.leftMouseDragged, view, at: CGPoint(x: start.x + Double(i) * 8, y: start.y)))
        }
        view.mouseUp(with: event(.leftMouseUp, view, at: CGPoint(x: start.x + 80, y: start.y)))
        let after = try #require(model.project.instance(id)).position
        #expect(after.x > before.x, "furniture did not move: \(before) -> \(after), error: \(model.lastError ?? "none")")
    }
}
