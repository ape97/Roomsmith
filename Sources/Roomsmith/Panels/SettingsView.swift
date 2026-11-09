import AppKit
import SwiftUI
import RoomsmithCore

enum SettingsTab: String, CaseIterable { case general, appearance, walk }

/// Settings window (⌘,): project settings (every change is one undoable command), 3D view options and walk settings.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var tab: SettingsTab

    /// `initialTab` is the tab shown first (the snapshot hook sets it, see `TestHooks`).
    init(initialTab: SettingsTab = .general) {
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $tab) {
            general
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
                .help("Units, snapping, warnings and defaults for new walls")
            appearance
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
                .tag(SettingsTab.appearance)
                .help("How the 3D view shows the model")
            WalkSettingsForm(autoScreenHeightMm: Self.mainScreenHeightMm)
                .tabItem { Label("Walk", systemImage: "figure.walk") }
                .tag(SettingsTab.walk)
                .help("Eye height, speed, field of view and controls for walking through the model")
        }
        // The Appearance tab holds a single short section: its window is only as tall as that content needs.
        .frame(width: 480, height: tab == .appearance ? 300 : 680)
    }

    private static var mainScreenHeightMm: Double? {
        guard let n = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let h = CGDisplayScreenSize(CGDirectDisplayID(n.uint32Value)).height
        return h > 0 ? Double(h) : nil
    }

    private var appearance: some View {
        @Bindable var model = model
        return Form {
            Section("3D view") {
                Toggle("Show ceilings", isOn: $model.showCeilings)
                    .help("Draw room ceilings in the 3D view")
                Toggle("Show lamps", isOn: $model.showLamps)
                    .help("Draw furniture with lamps in the 3D view; their light stays on when hidden")
                Toggle("Only active level", isOn: $model.onlyActiveLevel)
                    .help("Hide every level except the active one in the 3D view")
                Toggle("Show scene controls", isOn: $model.showSceneControls)
                    .help("Show the floating camera and display controls over the 3D view")
                LabeledContent("Wall opacity") {
                    HStack {
                        Slider(value: $model.wallOpacity, in: 0.1 ... 1) { Text("Wall opacity") }
                            .labelsHidden()
                            .frame(width: 160)
                            .help("How opaque walls are in the 3D view")
                        Text("\(Int(model.wallOpacity * 100)) %").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var general: some View {
        let s = model.project.settings
        return Form {
            Section("Units") {
                Picker("Display unit", selection: Binding(get: { s.displayUnit }, set: { v in set("Change Unit") { $0.displayUnit = v } })) {
                    ForEach(LengthUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Snapping") {
                Toggle("Snap", isOn: Binding(get: { s.snap.enabled }, set: { v in set("Snap") { $0.snap.enabled = v } }))
                Group {
                    Toggle("Snap to grid", isOn: Binding(get: { s.snap.toGrid }, set: { v in set("Snap to Grid") { $0.snap.toGrid = v } }))
                    Toggle("Snap to walls", isOn: Binding(get: { s.snap.toWalls }, set: { v in set("Snap to Walls") { $0.snap.toWalls = v } }))
                    Toggle("Snap to objects", isOn: Binding(get: { s.snap.toObjects }, set: { v in set("Snap to Objects") { $0.snap.toObjects = v } }))
                    LabeledContent("Grid") { LengthField(title: "Grid", value: s.snap.grid, unit: s.displayUnit, range: sizeLimit) { v in set("Grid") { $0.snap.grid = v } } }
                    LabeledContent("Tolerance") { LengthField(title: "Snap tolerance", value: s.snap.tolerance, unit: s.displayUnit, range: sizeLimit) { v in set("Snap Tolerance") { $0.snap.tolerance = v } } }
                        .help("Upper limit for how close the pointer must be to snap. The actual reach is the smaller of this and about 9 screen points, so zooming in snaps more precisely.")
                    LabeledContent("Angle step") { AngleField(title: "Angle step", value: s.snap.angleStep, range: 0.1 ... 180) { v in set("Angle Step") { $0.snap.angleStep = v } } }
                }
                .disabled(!s.snap.enabled)
            }
            Section("Warnings") {
                Toggle("Collision warnings", isOn: Binding(get: { s.collisionWarnings }, set: { v in set("Collision Warnings") { $0.collisionWarnings = v } }))
            }
            Section("New walls") {
                LabeledContent("Thickness") { LengthField(title: "Default wall thickness", value: s.defaultWallThickness, unit: s.displayUnit, range: sizeLimit) { v in set("Wall Thickness") { $0.defaultWallThickness = v } } }
                LabeledContent("Height") { LengthField(title: "Default wall height", value: s.defaultWallHeight, unit: s.displayUnit, range: sizeLimit) { v in set("Wall Height") { $0.defaultWallHeight = v } } }
            }
        }
        .formStyle(.grouped)
    }

    @discardableResult
    private func set(_ name: String, _ body: @escaping (inout ProjectSettings) -> Void) -> Bool {
        model.perform(name) { p in p.updateSettings { body(&$0) } }
    }
}
