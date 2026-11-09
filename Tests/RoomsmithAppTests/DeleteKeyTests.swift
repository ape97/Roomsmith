import AppKit
import SwiftUI
import Testing
import RoomsmithCore
@testable import Roomsmith

/// Delete/Backspace removes the selected, unlocked furniture in the plan, the 3D view and (via the window monitor) on
/// other controls; never in a text field, never in first-person mode.
@MainActor
struct DeleteKeyTests {
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let v = view as? T { return v }
        for s in view.subviews { if let f = find(type, in: s) { return f } }
        return nil
    }

    private func host<V: View>(_ root: V) -> (NSWindow, NSHostingView<V>) {
        let host = NSHostingView(rootView: root)
        let window = QuietWindows.make(width: 1500, height: 900)
        window.contentView = host
        QuietWindows.show(window)
        for _ in 0..<30 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)); window.layoutIfNeeded() }
        return (window, host)
    }

    private func mainWindow(layout: ViewLayout) -> (AppModel, NSWindow, NSHostingView<some View>) {
        let ws = Workspace()
        let model = ws.active
        model.layout = layout
        let (window, host) = host(ContentView().environment(ws).environment(model).environment(MaterialEditorState()))
        return (model, window, host)
    }

    private func selectedSofa(_ model: AppModel, locked: Bool = false) throws -> UUID {
        let def = try #require(BuiltinCatalog.definition("sofa.3seat.2100"))
        var newId: UUID?
        let level = try #require(model.project.levels.first).id
        model.perform("Add") { p in
            p.addDefinition(def)
            newId = try p.addInstance(definitionId: def.id, levelId: level, position: P3(3000, 3000, 0))
        }
        let id = try #require(newId)
        if locked { model.perform("Lock") { p in try p.setLocked([id], true) } }
        model.selection = [id]
        return id
    }

    private func key(_ code: UInt16, window: NSWindow, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: code)!
    }

    /// Monitor first (called directly: a local monitor needs the running event loop), then the responder chain.
    private func press(_ code: UInt16, in window: NSWindow, modifiers: NSEvent.ModifierFlags = []) {
        let e = key(code, window: window, modifiers: modifiers)
        if let content = window.contentView, let probe = find(EscapeClearsSelection.Probe.self, in: content), probe.consume(e) { return }
        window.sendEvent(e)
    }

    private func exists(_ model: AppModel, _ id: UUID) -> Bool { model.project.instance(id) != nil }

    @Test func deleteIn3DViewRemovesTheSelection() throws {
        for code: UInt16 in [51, 117] {
            let (model, window, host) = mainWindow(layout: .scene)
            let id = try selectedSofa(model)
            let view = try #require(find(SceneARView.self, in: host))
            #expect(window.makeFirstResponder(view))
            press(code, in: window)
            #expect(!exists(model, id), "key \(code)")
        }
    }

    @Test func lockedFurnitureSurvivesDeleteIn3DView() throws {
        let (model, window, host) = mainWindow(layout: .scene)
        let id = try selectedSofa(model, locked: true)
        let view = try #require(find(SceneARView.self, in: host))
        #expect(window.makeFirstResponder(view))
        press(51, in: window)
        #expect(exists(model, id))
    }

    @Test func deleteInFirstPersonModeDoesNothing() throws {
        let (model, window, host) = mainWindow(layout: .scene)
        let id = try selectedSofa(model)
        let view = try #require(find(SceneARView.self, in: host))
        view.renderer.camera.setMode(.firstPerson, levelElevation: 0)
        #expect(view.renderer.camera.rig.mode == .firstPerson)
        #expect(window.makeFirstResponder(view))
        #expect(!view.renderer.keyDown(code: 51, modifiers: []))
        #expect(exists(model, id))
    }

    @Test func deleteWithCommandIsNotTheBareKey() throws {
        let (model, window, host) = mainWindow(layout: .scene)
        let id = try selectedSofa(model)
        let view = try #require(find(SceneARView.self, in: host))
        #expect(window.makeFirstResponder(view))
        #expect(!view.renderer.keyDown(code: 51, modifiers: [.command]))
        #expect(exists(model, id))
    }

    @Test func deleteOnAnotherControlRemovesTheSelection() throws {
        let (model, window, host) = mainWindow(layout: .split)
        let id = try selectedSofa(model)
        final class Control: NSView { override var acceptsFirstResponder: Bool { true } }
        let control = Control(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        host.addSubview(control)
        #expect(window.makeFirstResponder(control))
        press(51, in: window)
        #expect(!exists(model, id))
    }

    @Test func lockedFurnitureSurvivesDeleteOnAnotherControl() throws {
        let (model, window, host) = mainWindow(layout: .split)
        let id = try selectedSofa(model, locked: true)
        final class Control: NSView { override var acceptsFirstResponder: Bool { true } }
        let control = Control(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        host.addSubview(control)
        #expect(window.makeFirstResponder(control))
        press(117, in: window)
        #expect(exists(model, id))
    }

    @Test func deleteInATextFieldIsNotConsumed() throws {
        let (model, window, host) = mainWindow(layout: .split)
        let id = try selectedSofa(model)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        host.addSubview(field)
        #expect(window.makeFirstResponder(field))
        #expect(window.firstResponder is NSText)
        let probe = try #require(find(EscapeClearsSelection.Probe.self, in: host))
        #expect(!probe.consume(key(51, window: window)))
        #expect(exists(model, id))
    }

    @Test func monitorIgnoresDeleteWithModifiers() throws {
        let (model, window, host) = mainWindow(layout: .split)
        let id = try selectedSofa(model)
        final class Control: NSView { override var acceptsFirstResponder: Bool { true } }
        let control = Control(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        host.addSubview(control)
        #expect(window.makeFirstResponder(control))
        let probe = try #require(find(EscapeClearsSelection.Probe.self, in: host))
        for m: NSEvent.ModifierFlags in [.command, .option, .control, .shift] {
            #expect(!probe.consume(key(51, window: window, modifiers: m)))
        }
        #expect(exists(model, id))
    }

    @Test func deleteInThePlanRemovesTheSelection() throws {
        let (model, window, host) = mainWindow(layout: .split)
        let plan = try #require(find(PlanNSView.self, in: host))
        let id = try selectedSofa(model)
        #expect(window.makeFirstResponder(plan))
        press(51, in: window)
        #expect(!exists(model, id))
    }

    @Test func lockedFurnitureSurvivesDeleteInThePlan() throws {
        let (model, window, host) = mainWindow(layout: .split)
        let plan = try #require(find(PlanNSView.self, in: host))
        let id = try selectedSofa(model, locked: true)
        #expect(model.isLockedForMenu(id))
        #expect(window.makeFirstResponder(plan))
        press(51, in: window)
        #expect(exists(model, id))
    }

    @Test func mixedSelectionDeletesOnlyTheUnlockedPart() throws {
        let (model, window, host) = mainWindow(layout: .scene)
        let locked = try selectedSofa(model, locked: true)
        let def = try #require(BuiltinCatalog.definition("sofa.3seat.2100"))
        var other: UUID?
        model.perform("Add") { p in other = try p.addInstance(definitionId: def.id, levelId: model.activeLevelId, position: P3(6000, 3000, 0)) }
        let freeId = try #require(other)
        model.selection = [locked, freeId]
        let view = try #require(find(SceneARView.self, in: host))
        #expect(window.makeFirstResponder(view))
        press(51, in: window)
        #expect(exists(model, locked))
        #expect(!exists(model, freeId))
    }
}
