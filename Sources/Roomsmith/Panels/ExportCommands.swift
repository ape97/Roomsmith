import SwiftUI
import RoomsmithCore

/// File menu additions after Save: Import 3D Model… and the Export submenu.
struct ExportCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Divider()
            Button("Import 3D Model…") { USDZImport.run(model) }
            Button("Import Background Image…") { BackgroundImport.run(model) }
                .disabled(!BackgroundImport.canRun(model))
            Button("Calibrate Background Scale") { model.tool = .calibrate }
                .disabled(model.project.backgrounds.allSatisfy { $0.levelId != model.activeLevel?.id })
            Menu("Export") {
                Button("Plan as PDF…") { ExportActions.run(.pdf, model: model) }
                Button("Plan as SVG…") { ExportActions.run(.svg, model: model) }
                Button("Plan as PNG…") { ExportActions.run(.png, model: model) }
                Divider()
                Button("3D Model as OBJ…") { ExportActions.run(.obj, model: model) }
                Button("3D View as Image (1920 × 1080)…") { ExportActions.export3DImage(width: 1920, height: 1080, model: model) }
                Button("3D View as Image (3840 × 2160)…") { ExportActions.export3DImage(width: 3840, height: 2160, model: model) }
                Divider()
                Button("Reports…") { model.sheet = .reports }
            }
            .disabled(!ExportActions.canExport(model.project))
        }
    }
}
