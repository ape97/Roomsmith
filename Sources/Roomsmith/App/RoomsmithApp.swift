import AppKit
import SwiftUI
import RoomsmithCore

@main
struct RoomsmithApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var workspace = Workspace()
    @State private var materialEditor = MaterialEditorState()

    var body: some Scene {
        Window("Roomsmith", id: "main") {
            ContentView()
                .modifier(MaterialEditorHost(state: materialEditor))
                .environment(workspace)
                .environment(workspace.focused)
                .environment(materialEditor)
                .frame(minWidth: 1000, minHeight: 640)
                .onAppear { delegate.workspace = workspace; AppLaunch.start(workspace) }
                .onChange(of: workspace.sessionSnapshot) { _, state in workspace.persistSession(state) }
        }
        .commands { RoomsmithCommands(workspace: workspace, materialEditor: materialEditor) }

        Window("3D View", id: EditorLayoutKey.sceneWindowID) {
            SceneWindowView()
                .environment(workspace)
                .environment(workspace.active)
        }
        .defaultSize(width: 900, height: 650)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView().environment(workspace.focused)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var workspace: Workspace?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let workspace else { return .terminateNow }
        // Active tab and split are taken before the questions: asking about a dirty tab brings it to the front, which
        // is not the user's choice. The files are read after them, so an untitled tab saved there stays in the session.
        let active = workspace.activeId, compare = workspace.compare
        // Every project with unsaved changes is asked about, one after the other.
        guard workspace.confirmDiscardAll() else { return .terminateCancel }
        AppDefaults.isTerminating = true
        workspace.persistSession(workspace.sessionSnapshot(active: active, compare: compare))
        workspace.discardAllAutosaves()
        workspace.agentHost?.stop()
        return .terminateNow
    }

    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let workspace else { return }
        for url in urls { workspace.open(url) }
    }
}

/// Menu bar commands. Editing actions route through the project that has the focus (the active tab, or the focused
/// pane in a compare split).
struct RoomsmithCommands: Commands {
    let workspace: Workspace
    let materialEditor: MaterialEditorState

    var body: some Commands {
        let model = workspace.focused
        CommandGroup(replacing: .newItem) {
            Button("New Project") { workspace.newProject() }.keyboardShortcut("n")
            Button("Open…") { workspace.openWithPanel() }.keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(workspace.recent.items(), id: \.path) { item in
                    Button(item.title) { workspace.openRecent(item.path) }.help(item.path)
                }
                Divider()
                Button("Clear Menu") { workspace.clearRecent() }
            }
            .disabled(workspace.recent.isEmpty)
            Button("Close Tab") { workspace.closeWithConfirmation(workspace.active.id) }
                .keyboardShortcut("w", modifiers: [.command, .option])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { model.save() }.keyboardShortcut("s")
                .disabled(!model.store.isDirty && model.fileURL != nil)
            Button("Save As…") { model.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .undoRedo) {
            Button(model.store.undoName.map { "Undo \($0)" } ?? "Undo") { model.undo() }
                .keyboardShortcut("z").disabled(!model.store.canUndo)
            Button(model.store.redoName.map { "Redo \($0)" } ?? "Redo") { model.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.store.canRedo)
        }
        // Copy and paste work across projects; in a text field they stay the text commands.
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
                .keyboardShortcut("x")
            Button("Copy") {
                if model.textEditingActive { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
                else { workspace.copySelection(of: model) }
            }
            .keyboardShortcut("c")
            Button("Paste") {
                if model.textEditingActive || !workspace.canPaste { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
                else { workspace.paste(into: model) }
            }
            .keyboardShortcut("v")
        }
        PhotoCommands(model: model)
        LibraryCommands(model: model)
        EditCommands(model: model)
        ExportCommands(model: model)
        ViewLayoutCommands(model: model)
        WorkspaceCommands(workspace: workspace)
        MaterialCommands(state: materialEditor)
    }
}
