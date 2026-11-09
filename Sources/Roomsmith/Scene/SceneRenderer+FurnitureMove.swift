import AppKit
import Foundation
import RealityKit
import RoomsmithCore
import simd

// Dragging a selected piece of furniture over the floor in the 3D view. Same contact rules as the plan (stops flush at
// walls and furniture, slides along them, goes through when pulled far enough); the document changes only on release.
// Kept out of `SceneRenderer+Interaction.swift` so the input code there stays small.

/// State of a running furniture drag. The entities show a live preview.
struct FurnitureMoveDrag {
    /// Objects the command acts on (groups are expanded by the command itself).
    var ids: [UUID]
    /// Objects whose entities move in the preview (groups expanded).
    var expanded: [UUID]
    var bases: [(entity: Entity, matrix: simd_float4x4)]
    /// Height of the plane the cursor slides on: the lower edge of the piece that was grabbed.
    var planeZ: Double
    /// Where the cursor met the plane when the drag began.
    var startGround: V2
    var gizmoStart: D3?
    var bodies: [ContactBody]
    /// Built once per drag: pieces moved by someone else meanwhile count from the next drag.
    var obstacles: [ContactObstacle]
    /// Distance from the eye, for the screen-space size of the snap tolerance.
    var depth: Double
    /// Set when exactly one loose piece is dragged: it climbs onto furniture below it and steps down again.
    var rest: RestingDrag?
    /// Whole mm moved so far.
    var delta = V2(0, 0)
    /// Height change of the piece so far (resting on furniture), mm.
    var dz: MM = 0
}

extension SceneRenderer {
    /// A press on an already selected, movable piece of furniture may become a furniture drag. Returns the picked
    /// piece, or nil (then the press stays a click or a camera drag as before).
    func furnitureMoveCandidate(at point: SIMD2<Double>) -> UUID? {
        guard camera.rig.mode != .firstPerson, let hit = pickHit(at: point) else { return nil }
        let p = model.project
        guard p.instance(hit.id) != nil, expand(model.selection).contains(hit.id) else { return nil }
        // Only furniture and groups: a selection with walls or rooms keeps the camera drag.
        guard model.selection.allSatisfy({ p.instance($0) != nil || p.group($0) != nil }) else { return nil }
        guard let t = gizmoTargets(), Set(t.ids) == model.selection else { return nil }
        return hit.id
    }

    /// About 9 points on screen, between 20 and 300 mm, never more than the snap tolerance of the project.
    func contactTolerance(depth: Double) -> Double {
        let mm = camera.rig.mmPerPoint(depth: depth, viewHeight: Double(camera.viewSize.height))
        return min(min(max(mm * 9, 20), 300), Double(model.project.settings.snap.tolerance))
    }

    /// Contact data for an X or Y gizmo drag of furniture and groups; nil for everything else (walls, rooms, Z, ring).
    func gizmoContact(handle: GizmoHandle, ids: [UUID], expanded: [UUID], origin: D3) -> GizmoContact? {
        guard handle == .axisX || handle == .axisY else { return nil }
        let p = model.project
        guard ids.allSatisfy({ p.instance($0) != nil || p.group($0) != nil }),
              let levelId = expanded.lazy.compactMap({ p.instance($0)?.levelId }).first else { return nil }
        let snap = p.settings.snap
        let bodies = MoveContact.bodies(project: p, levelId: levelId, ids: Set(expanded))
        guard !bodies.isEmpty else { return nil }
        let obstacles = MoveContact.obstacles(project: p, levelId: levelId, excluding: Set(expanded),
                                              toWalls: snap.toWalls, toObjects: snap.toObjects,
                                              showLamps: options.showLamps)
        let r = camera.rig
        return GizmoContact(bodies: bodies, obstacles: obstacles, depth: max(simd_dot(origin - r.eye, r.forward), 100))
    }

    /// Stops for a Z gizmo drag of furniture and groups; nil for everything else or when snapping to objects is off.
    func gizmoVertical(handle: GizmoHandle, ids: [UUID], expanded: [UUID], origin: D3) -> GizmoVertical? {
        guard handle == .axisZ else { return nil }
        let p = model.project
        guard p.settings.snap.toObjects, ids.allSatisfy({ p.instance($0) != nil || p.group($0) != nil }),
              let levelId = expanded.lazy.compactMap({ p.instance($0)?.levelId }).first else { return nil }
        let r = camera.rig
        return GizmoVertical(contact: VerticalContact(project: p, levelId: levelId, moving: Set(expanded)),
                             depth: max(simd_dot(origin - r.eye, r.forward), 100))
    }

    /// Plane point under the cursor. Nil when the ray is nearly parallel to the floor or points away from it.
    func groundPoint(at point: SIMD2<Double>, z: Double) -> V2? {
        let r = ray(at: point)
        guard abs(r.dir.z) >= 0.05 else { return nil }
        let t = (z - r.origin.z) / r.dir.z
        guard t > 0 else { return nil }
        let hit = r.origin + r.dir * min(t, 50_000)
        return V2(hit.x, hit.y)
    }

    /// Starts the furniture drag for a press that moved past the click slop. False: nothing started.
    func beginFurnitureMoveIfNeeded(_ pc: PendingClick, current point: SIMD2<Double>) -> Bool {
        guard let grabbed = pc.furnitureId, let t = gizmoTargets(), let b = bounds(of: grabbed),
              let start = groundPoint(at: pc.point, z: b.lo.z) else { return false }
        let p = model.project
        guard let levelId = p.instance(grabbed)?.levelId else { return false }
        let expanded = Array(expand(Set(t.ids)))
        var bases: [(entity: Entity, matrix: simd_float4x4)] = []
        for id in expanded { if let n = instNodes[id] { bases.append((n.root, n.root.transform.matrix)) } }
        guard !bases.isEmpty else { return false }
        let snap = p.settings.snap
        let eye = camera.rig
        let rest = RestingDrag(project: p, levelId: levelId, ids: Set(expanded), showLamps: options.showLamps)
        model.store.beginInteraction(expanded, reason: "Moving in 3D")
        drag = .furnitureMove(FurnitureMoveDrag(
            ids: t.ids, expanded: expanded, bases: bases, planeZ: b.lo.z, startGround: start, gizmoStart: gizmoOrigin,
            bodies: MoveContact.bodies(project: p, levelId: levelId, ids: Set(expanded)),
            obstacles: MoveContact.obstacles(project: p, levelId: levelId, excluding: Set(expanded),
                                             toWalls: snap.toWalls, toObjects: snap.toObjects,
                                             showLamps: options.showLamps),
            depth: max(simd_dot(b.center - eye.eye, eye.forward), 100), rest: rest))
        return true
    }

    func updateFurnitureMove(at point: SIMD2<Double>, option: Bool) {
        guard case .furnitureMove(var f) = drag else { return }
        // A ray that misses the floor keeps the last valid position.
        guard let ground = groundPoint(at: point, z: f.planeZ) else { return }
        let raw = ground - f.startGround
        let settings = model.project.settings
        let snapOn = settings.snap.enabled && !option && !model.snapSuspended
        // Option switches resting off, as it does for snapping (the global snap toggle does not).
        let resting = f.rest.flatMap { option || model.snapSuspended ? nil : $0 }
        var contact = false
        f.dz = 0
        if snapOn {
            let tol = contactTolerance(depth: f.depth)
            if let rest = resting {
                let r = rest.resolve(moving: f.bodies, raw: raw, obstacles: f.obstacles, tolerance: tol, slide: true)
                f.delta = r.result.delta
                contact = r.result.contact
                f.dz = r.dz
            } else {
                let r = MoveContact.resolve(moving: f.bodies, raw: raw, obstacles: f.obstacles, tolerance: tol, slide: true)
                f.delta = r.delta
                contact = r.contact
            }
        } else {
            f.delta = V2(raw.x.rounded(), raw.y.rounded())
            if let rest = resting { f.dz = rest.z(at: f.delta) - rest.startZ }
        }
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(Float(f.delta.x), Float(f.delta.y), Float(f.dz), 1)
        for b in f.bases { b.entity.transform.matrix = m * b.matrix }
        if let o = f.gizmoStart { gizmoOrigin = o + D3(f.delta.x, f.delta.y, Double(f.dz)) }
        hudText = "Move  X \(Self.signed(f.delta.x)) mm  Y \(Self.signed(f.delta.y)) mm" + (contact ? "  (touching)" : "")
        drag = .furnitureMove(f)
        placeGizmo()
    }

    /// Ends the drag. With `commit` the move becomes ONE command; without (Esc, focus lost) nothing changes.
    func endFurnitureMove(commit: Bool) {
        guard case .furnitureMove(let f) = drag else { return }
        drag = nil
        for b in f.bases { b.entity.transform.matrix = b.matrix }
        model.store.endInteraction(f.expanded)
        hudText = nil
        if commit, f.delta != V2(0, 0) || f.dz != 0 {
            let d = P3(MM(f.delta.x), MM(f.delta.y), f.dz)
            model.perform("Move") { try $0.moveObjects(f.ids, by: d) }
        }
        updateGizmo()
    }
}
