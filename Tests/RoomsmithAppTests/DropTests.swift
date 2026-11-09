import AppKit
import SwiftUI
import Testing
import RoomsmithCore
@testable import Roomsmith

/// Minimal dragging info: a pasteboard with the drag token and a location in window coordinates.
private final class StubDraggingInfo: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard
    let location: NSPoint
    let win: NSWindow
    init(text: String, location: NSPoint, window: NSWindow) {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("roomsmith-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        self.location = location
        self.win = window
    }
    var draggingDestinationWindow: NSWindow? { win }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation { get { .default } set {} }
    var animatesToDestination: Bool { get { false } set {} }
    var numberOfValidItemsForDrop: Int { get { 1 } set {} }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}

@MainActor
struct DropTests {
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let v = view as? T { return v }
        for s in view.subviews { if let f = find(type, in: s) { return f } }
        return nil
    }

    @Test func catalogDropIntoThePlanPlacesFurniture() throws {
        let ws = Workspace()
        let model = ws.active
        model.layout = .split
        let root = ContentView().environment(ws).environment(model).environment(MaterialEditorState())
        let host = NSHostingView(rootView: root)
        let window = QuietWindows.make(width: 1500, height: 900)
        window.contentView = host
        QuietWindows.show(window)
        for _ in 0..<20 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)); window.layoutIfNeeded() }
        let view = try #require(find(PlanNSView.self, in: host))
        view.fit(selectionOnly: false)
        let payload = FurnitureDragSource.catalog("sofa.3seat.2100").payload
        let info = StubDraggingInfo(text: payload, location: view.convert(view.vp.screen(V2(3000, 3000)), to: nil), window: window)
        #expect(view.draggingEntered(info) == .copy)
        let before = model.project.instances.count
        let ok = view.performDragOperation(info)
        #expect(ok)
        #expect(model.project.instances.count == before + 1)
    }

    /// A library entry saved in a temporary library (never the user's) and its drag token.
    private func libraryToken(from model: AppModel, in tmp: URL) throws -> String {
        setenv("ROOMSMITH_SUPPORT_DIR", tmp.path, 1)
        let lib = LibraryModel.shared
        try #require(lib.store.root.path.hasPrefix(tmp.path), "library is not the temporary one")
        let def = try #require(BuiltinCatalog.definition("sofa.3seat.2100"))
        var id: UUID?
        let level = try #require(model.project.levels.first).id
        model.perform("Add") { p in
            p.addDefinition(def)
            id = try p.addInstance(definitionId: def.id, levelId: level, position: P3(9000, 9000, 0))
        }
        let entry = try LibraryContent.save(project: model.project, ids: [try #require(id)], packageURL: nil, into: lib.store)
        lib.reload()
        return LibraryDragToken(entryId: entry.id).payload
    }

    @Test func libraryDropIntoThePlanAndThe3DViewPlacesFurniture() throws {
        let ws = Workspace()
        let model = ws.active
        model.layout = .split
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rs-droptest-\(UUID().uuidString)")
        let previous = getenv("ROOMSMITH_SUPPORT_DIR").map { String(cString: $0) }
        defer {
            if let previous { setenv("ROOMSMITH_SUPPORT_DIR", previous, 1) } else { unsetenv("ROOMSMITH_SUPPORT_DIR") }
            LibraryModel.shared.reload()
            try? FileManager.default.removeItem(at: tmp)
        }
        let token = try libraryToken(from: model, in: tmp)
        let root = ContentView().environment(ws).environment(model).environment(MaterialEditorState())
        let host = NSHostingView(rootView: root)
        let window = QuietWindows.make(width: 1500, height: 900)
        window.contentView = host
        QuietWindows.show(window)
        for _ in 0..<40 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)); window.layoutIfNeeded() }
        let plan = try #require(find(PlanNSView.self, in: host))
        plan.fit(selectionOnly: false)
        var before = model.project.instances.count
        let planInfo = StubDraggingInfo(text: token, location: plan.convert(plan.vp.screen(V2(3000, 3000)), to: nil), window: window)
        #expect(plan.draggingEntered(planInfo) == .copy)
        let okPlan = plan.performDragOperation(planInfo)
        #expect(okPlan, "plan drop failed: \(model.lastError ?? "none")")
        #expect(model.project.instances.count == before + 1)

        let scene = try #require(find(SceneARView.self, in: host))
        before = model.project.instances.count
        let centre = NSPoint(x: scene.bounds.midX, y: scene.bounds.midY)
        let sceneInfo = StubDraggingInfo(text: token, location: scene.convert(centre, to: nil), window: window)
        let op = scene.draggingEntered(sceneInfo)
        #expect(op == .copy)
        let ok3D = scene.performDragOperation(sceneInfo)
        #expect(ok3D, "3D drop failed: \(model.lastError ?? "none")")
        #expect(model.project.instances.count == before + 1)
    }
}
