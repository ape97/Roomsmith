import AppKit
import SwiftUI
import Testing
import RoomsmithCore
@testable import Roomsmith

/// Esc clears the selection wherever the keyboard focus is, except in a text field (there it only cancels the editing).
@MainActor
struct EscapeTests {
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let v = view as? T { return v }
        for s in view.subviews { if let f = find(type, in: s) { return f } }
        return nil
    }

    /// A window that is never shown to the user (off-screen, behind everything), so no focus is taken.
    private func host<V: View>(_ root: V) -> (NSWindow, NSHostingView<V>) {
        let host = NSHostingView(rootView: root)
        let window = QuietWindows.make(width: 1500, height: 900)
        window.contentView = host
        QuietWindows.show(window)
        for _ in 0..<30 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)); window.layoutIfNeeded() }
        return (window, host)
    }

    private func selectedSofa(_ model: AppModel) throws -> UUID {
        let def = try #require(BuiltinCatalog.definition("sofa.3seat.2100"))
        var newId: UUID?
        let level = try #require(model.project.levels.first).id
        model.perform("Add") { p in
            p.addDefinition(def)
            newId = try p.addInstance(definitionId: def.id, levelId: level, position: P3(3000, 3000, 0))
        }
        let id = try #require(newId)
        model.selection = [id]
        return id
    }

    private func escape(in window: NSWindow) {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                 context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53)!
        // The same order as in the app: the window-level monitor first (a local monitor needs the running event loop,
        // so it is called directly), then the responder chain.
        if let content = window.contentView, let probe = find(EscapeClearsSelection.Probe.self, in: content), probe.consume(e) { return }
        window.sendEvent(e)
    }

    private func mainWindow(layout: ViewLayout) -> (AppModel, NSWindow, NSHostingView<some View>) {
        let ws = Workspace()
        let model = ws.active
        model.layout = layout
        let (window, host) = host(ContentView().environment(ws).environment(model).environment(MaterialEditorState()))
        return (model, window, host)
    }

    @Test func escapeInThePlanClearsTheSelection() throws {
        let (model, window, host) = mainWindow(layout: .split)
        _ = try selectedSofa(model)
        let plan = try #require(find(PlanNSView.self, in: host))
        #expect(window.makeFirstResponder(plan))
        escape(in: window)
        #expect(model.selection.isEmpty)
    }

    @Test func escapeInThe3DViewClearsTheSelection() throws {
        let (model, window, host) = mainWindow(layout: .scene)
        _ = try selectedSofa(model)
        let view = try #require(find(SceneARView.self, in: host))
        #expect(window.makeFirstResponder(view))
        escape(in: window)
        #expect(model.selection.isEmpty)
    }

    @Test func escapeWithTheFocusOnAnotherControlClearsTheSelection() throws {
        let (model, window, host) = mainWindow(layout: .split)
        _ = try selectedSofa(model)
        // Stands for any control that takes the key focus but has no use for Esc (sidebar list, inspector, toolbar).
        final class Control: NSView { override var acceptsFirstResponder: Bool { true } }
        let control = Control(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        host.addSubview(control)
        #expect(window.makeFirstResponder(control))
        escape(in: window)
        #expect(model.selection.isEmpty)
    }

    @Test func escapeInATextFieldOnlyEndsTheEditing() throws {
        let (model, window, host) = mainWindow(layout: .split)
        let id = try selectedSofa(model)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        host.addSubview(field)
        #expect(window.makeFirstResponder(field))
        #expect(window.firstResponder is NSText, "the field editor is active")
        escape(in: window)
        #expect(model.selection == [id])
    }

    private func escapeEvent(window: NSWindow, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53)!
    }

    @Test func monitorIgnoresEscFromAnotherWindow() throws {
        let (model, window, host) = mainWindow(layout: .split)
        let id = try selectedSofa(model)
        let other = QuietWindows.make(width: 100, height: 100, prune: false)
        let probe = try #require(find(EscapeClearsSelection.Probe.self, in: host))
        #expect(!probe.consume(escapeEvent(window: other)))
        #expect(model.selection == [id])
        #expect(probe.consume(escapeEvent(window: window)), "control: the own window's Esc is used")
    }

    @Test func monitorIgnoresEscWithModifiers() throws {
        let (model, window, host) = mainWindow(layout: .split)
        let id = try selectedSofa(model)
        let probe = try #require(find(EscapeClearsSelection.Probe.self, in: host))
        for m: NSEvent.ModifierFlags in [.command, .option, .control, .shift] {
            #expect(!probe.consume(escapeEvent(window: window, modifiers: m)))
        }
        #expect(model.selection == [id])
    }

    @Test func monitorIgnoresEscWhileASheetIsAttached() throws {
        let (model, window, host) = mainWindow(layout: .split)
        let id = try selectedSofa(model)
        let probe = try #require(find(EscapeClearsSelection.Probe.self, in: host))
        let sheet = QuietWindows.make(width: 100, height: 100, styleMask: [.titled], prune: false)
        window.beginSheet(sheet) { _ in }
        defer { window.endSheet(sheet) }
        #expect(window.attachedSheet != nil)
        #expect(!probe.consume(escapeEvent(window: window)))
        #expect(model.selection == [id])
    }

    @Test func escapeInTheDetached3DWindowClearsTheSelection() throws {
        let ws = Workspace()
        let model = ws.active
        let id = try selectedSofa(model)
        let (window, host) = host(SceneWindowView().environment(ws).environment(model))
        let view = try #require(find(SceneARView.self, in: host))
        #expect(model.selection == [id])
        // On the 3D view itself.
        #expect(window.makeFirstResponder(view))
        escape(in: window)
        #expect(model.selection.isEmpty)
        // On another control of that window (e.g. the toolbar button).
        model.selection = [id]
        final class Control: NSView { override var acceptsFirstResponder: Bool { true } }
        let control = Control(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        host.addSubview(control)
        #expect(window.makeFirstResponder(control))
        escape(in: window)
        #expect(model.selection.isEmpty)
    }
}
