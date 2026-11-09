import SwiftUI
import RoomsmithCore

/// Level list with visibility, lock, name, elevation and height.
struct SidebarLevelsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let unit = model.project.settings.displayUnit
        VStack(spacing: 0) {
            List(selection: Binding<UUID?>(get: { model.activeLevelId }, set: { if let id = $0 { model.activeLevelId = id; model.selection = [] } })) {
                ForEach(model.project.levels.sorted { $0.elevation > $1.elevation }) { level in
                    HStack(spacing: 6) {
                        Button {
                            model.perform(level.visible ? "Hide Level" : "Show Level") { try $0.updateLevel(level.id, visible: !level.visible) }
                        } label: { Image(systemName: level.visible ? "eye" : "eye.slash") }
                            .buttonStyle(.borderless)
                            .help(level.visible ? "Hide level" : "Show level")
                            .accessibilityLabel(level.visible ? "Hide level \(level.name)" : "Show level \(level.name)")
                        Button {
                            model.perform(level.locked ? "Unlock Level" : "Lock Level") { try $0.updateLevel(level.id, locked: !level.locked) }
                        } label: { Image(systemName: level.locked ? "lock.fill" : "lock.open") }
                            .buttonStyle(.borderless)
                            .help(level.locked ? "Unlock level" : "Lock level")
                            .accessibilityLabel(level.locked ? "Unlock level \(level.name)" : "Lock level \(level.name)")
                        VStack(alignment: .leading, spacing: 0) {
                            Text(level.name).lineLimit(1).foregroundStyle(Color(nsColor: .labelColor))
                            Text("\(unit.format(level.elevation)) – \(unit.format(level.elevation + level.height))")
                                .font(.caption).foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        }
                        Spacer()
                    }
                    .tag(level.id)
                    .listRowBackground(
                        SelectionBackdrop(selected: level.id == model.activeLevelId)
                    )
                    .opacity(level.visible ? 1 : 0.5)
                    .contextMenu {
                        Button("Delete Level", role: .destructive) { model.deleteObjects([level.id]) }
                            .disabled(model.project.levels.count <= 1)
                    }
                }
            }
            .listStyle(.sidebar)
            // The list is only as tall as its rows (up to the free space), so the editor sits right under it.
            .frame(maxHeight: CGFloat(model.project.levels.count) * 46 + 12)
            Divider()
            if let level = model.activeLevel {
                LevelEditor(level: level, unit: unit).id(level.id).padding(10)
            }
            Divider()
            HStack {
                Button {
                    var newId: UUID?
                    let n = model.project.levels.count + 1
                    if model.perform("Add Level", { newId = $0.addLevel(name: "Level \(n)") }), let newId {
                        model.activeLevelId = newId
                        model.selection = []
                    }
                } label: { Label("Add Level", systemImage: "plus") }
                    .help("Add a level on top of the highest one")
                Spacer()
            }
            .padding(8)
            Spacer(minLength: 0)
        }
    }
}

private struct LevelEditor: View {
    @Environment(AppModel.self) private var model
    let level: Level
    let unit: LengthUnit

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                Text("Name").foregroundStyle(.secondary)
                NameField(title: "Level name", value: level.name) { v in
                    model.perform("Rename Level") { try $0.updateLevel(level.id, name: v) }
                }
            }
            GridRow {
                Text("Elevation").foregroundStyle(.secondary)
                LengthField(title: "Level elevation", value: level.elevation, unit: unit) { v in
                    model.perform("Set Level Elevation") { try $0.updateLevel(level.id, elevation: v) }
                }
            }
            GridRow {
                Text("Height").foregroundStyle(.secondary)
                LengthField(title: "Level height", value: level.height, unit: unit, range: sizeLimit) { v in
                    model.perform("Set Level Height") { try $0.updateLevel(level.id, height: v) }
                }
            }
        }
    }
}

/// Opaque selection fill: covers the native (dark in inactive windows) selection so label colors stay readable.
struct SelectionBackdrop: View {
    let selected: Bool
    var body: some View {
        if selected {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor))
                RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.28))
            }
            .padding(.horizontal, 6)
        } else {
            Color.clear
        }
    }
}
