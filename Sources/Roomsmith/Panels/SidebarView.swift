import SwiftUI
import RoomsmithCore

enum SidebarTab: String, CaseIterable, Identifiable {
    case levels, objects, catalog
    var id: String { rawValue }
    var title: String { switch self { case .levels: "Levels"; case .objects: "Objects"; case .catalog: "Catalog" } }
    var symbol: String { switch self { case .levels: "square.3.layers.3d"; case .objects: "list.bullet.indent"; case .catalog: "sofa" } }
}

/// Levels, object tree and furniture catalog.
struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let tab = model.sidebarTab
        return VStack(spacing: 0) {
            Picker("Sidebar", selection: $model.sidebarTab) {
                ForEach(SidebarTab.allCases) { t in Label(t.title, systemImage: t.symbol).tag(t) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .labelStyle(.iconOnly)
            .padding(8)
            .help("Levels, objects and catalog")
            .accessibilityIdentifier("sidebarTabs")
            if tab != .levels { levelBar }
            Divider()
            switch tab {
            case .levels: SidebarLevelsView()
            case .objects: SidebarObjectsView()
            case .catalog: SidebarCatalogView()
            }
        }
    }

    private var levelBar: some View {
        @Bindable var model = model
        return Picker("Level", selection: $model.activeLevelId) {
            ForEach(model.project.levels) { Text($0.name).tag($0.id) }
        }
        .pickerStyle(.menu)
        .padding(.horizontal, 8).padding(.bottom, 6)
        .help("Active level")
    }
}
