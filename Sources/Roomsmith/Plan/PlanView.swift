import SwiftUI
import RoomsmithCore

/// Remembers the last VoiceOver summary of the drawing; recomputed only when revision, level or selection change.
/// Not observed: `body` only reads it.
@MainActor final class SceneSummaryCache {
    private var key: [AnyHashable] = []
    private var text = ""
    func text(_ p: Project, revision: Int64, levelId: UUID, selected: Int, view: String) -> String {
        let k: [AnyHashable] = [p.id, revision, levelId, selected, view]
        if k != key { text = SceneSummary.text(p, levelId: levelId, selected: selected, view: view); key = k }
        return text
    }
}

/// 2D plan editor: millimetre-exact drawing and furniture placement on the active level.
struct PlanView: View {
    @Environment(AppModel.self) private var model
    @State private var summary = SceneSummaryCache()

    var body: some View {
        // Reading these makes SwiftUI call `updateNSView` whenever one of them changes.
        PlanCanvas(model: model,
                   projectId: model.project.id,
                   revision: model.store.contentRevision,
                   levelId: model.activeLevel?.id ?? model.activeLevelId,
                   selection: model.selection,
                   hoveredId: model.hoveredId,
                   tool: model.tool,
                   frameRequest: model.frameSelectionRequest,
                   viewRequest: model.planViewRequest,
                   snapSuspended: model.snapSuspended,
                   lastError: model.lastError)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(summary.text(model.project, revision: model.store.contentRevision, levelId: model.activeLevel?.id ?? model.activeLevelId,
                                             selected: model.selection.count, view: "Floor plan"))
            .accessibilityIdentifier("planView")
    }
}

/// SwiftUI wrapper around the AppKit plan canvas.
struct PlanCanvas: NSViewRepresentable {
    let model: AppModel
    let projectId: UUID
    let revision: Int64
    let levelId: UUID
    let selection: Set<UUID>
    let hoveredId: UUID?
    let tool: EditorTool
    let frameRequest: Int
    /// Agent `view.set` viewport / fit request; applied once per serial.
    let viewRequest: PlanViewRequest?
    let snapSuspended: Bool
    let lastError: String?

    func makeNSView(context: Context) -> PlanNSView {
        let view = PlanNSView(model: model)
        view.restoreViewport()
        return view
    }

    func updateNSView(_ view: PlanNSView, context: Context) {
        view.sync(projectId: projectId, revision: revision, levelId: levelId, tool: tool, frameRequest: frameRequest,
                  viewRequest: viewRequest)
    }
}
