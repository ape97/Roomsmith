import AppKit
import CoreGraphics
import Foundation
import GameController
import RealityKit
import RoomsmithCore
import simd

/// Walk mode of one 3D view: input, motion, collision, doors, pointer lock and game controller.
///
/// Motion and collision live in `RoomsmithCore` (`WalkMotion`, `WalkCollider`); this class feeds them from the keyboard,
/// the mouse and the controller once per frame and writes the result into the camera rig.
@MainActor
final class WalkController {
    static let doorReach = 1500.0
    static let doorSeconds = 0.6

    private unowned let renderer: SceneRenderer
    let store = WalkSettingsStore.shared

    private(set) var motion = WalkMotion(position: .zero)
    private var collider: WalkCollider?
    private var colliderKey: ColliderKey?
    private var active = false
    /// Space was held in the previous frame (collision off).
    private var wasPassing = false
    private var lastWritten: D3?

    /// Door and window state is view state (see `OpeningMotion`).
    private(set) var openings = OpeningMotion()

    private(set) var pointerLocked = false
    private var pendingLook = SIMD2<Double>.zero
    private var padDoorDown = false
    private var lastHud: WalkHUDInfo?
    private var scaleClock = 1.0
    private var scaleDepth = 3000.0

    private struct ColliderKey: Equatable {
        /// Revision of the last content change: camera writes (every pause while walking) do not change what blocks the way.
        var contentRevision: Int64
        var project: UUID
        var level: UUID
        var eye: Double
        var radius: Double
        var showLamps: Bool
    }

    init(renderer: SceneRenderer) { self.renderer = renderer }

    var settings: WalkSettings { store.settings }
    /// Doors heading to open, sorted by id.
    var openDoorIds: [UUID] {
        let p = renderer.model.project
        return openings.openList.filter { p.opening($0.id)?.kind == .door }.map(\.id)
    }
    /// Windows and balcony doors heading to an open pose, with their mode.
    var openWindowList: [(id: UUID, mode: OpeningMode)] {
        let p = renderer.model.project
        return openings.openList.filter { p.opening($0.id)?.kind != .door }
    }

    // MARK: Display facts

    /// What the calibrated field of view needs from the display. Asking the system for it is not free, so it is read once
    /// per window and display and refreshed when the window changes screen or the display setup changes (not every frame).
    private struct ScreenFacts {
        var autoHeightMm: Double?
        var heightPoints: Double
        weak var window: NSWindow?
    }
    private var screenFacts: ScreenFacts?
    private var screenObservers: [NSObjectProtocol] = []
    private var isShutDown = false

    private func facts() -> ScreenFacts {
        let window = renderer.arView?.window
        if let f = screenFacts, f.window === window { return f }
        var mm: Double?
        if let n = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            let size = CGDisplayScreenSize(CGDirectDisplayID(n.uint32Value))
            mm = size.height > 0 ? Double(size.height) : nil
        }
        let f = ScreenFacts(autoHeightMm: mm, heightPoints: Double(window?.screen?.frame.height ?? 0), window: window)
        // After `shutdown()` the answer is still right but nothing is cached or observed again (no leaked observers).
        guard !isShutDown else { return f }
        screenFacts = f
        observeScreen(of: window)
        return f
    }

    private func observeScreen(of window: NSWindow?) {
        screenObservers.forEach { NotificationCenter.default.removeObserver($0) }
        screenObservers = []
        func forget(_ name: Notification.Name, _ object: Any?) -> NSObjectProtocol {
            NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenFacts = nil }
            }
        }
        if let window { screenObservers.append(forget(NSWindow.didChangeScreenNotification, window)) }
        screenObservers.append(forget(NSApplication.didChangeScreenParametersNotification, nil))
    }

    var autoScreenHeightMm: Double? { facts().autoHeightMm }

    func fovDeg(_ s: WalkSettings) -> Double {
        let f = facts()
        return WalkFOV.verticalDeg(s, autoScreenHeightMm: f.autoHeightMm, viewHeightPoints: Double(renderer.camera.viewSize.height),
                                   screenHeightPoints: f.heightPoints)
    }

    var currentEyeHeightMm: Double { motion.eyeHeightMm(settings: settings) }
    var speedMps: Double { motion.speedMmPerSecond / 1000 }

    // MARK: Frame update

    func tick(dt: Double) {
        animateDoors(dt: dt)
        let rig = renderer.camera.rig
        guard rig.mode == .firstPerson else {
            if active { leave() }
            return
        }
        let s = settings
        ensureCollider(s)
        // Space held: walk through walls and furniture (no setting, no document change). On release inside an obstacle
        // the walker is pushed out to the nearest free spot.
        let keys = renderer.pressedKeys
        let passing = keys.contains(KeyCode.space)
        let activeCollider = WalkPassThrough.activeCollider(collider, setting: s.collision, spaceHeld: passing)
        if wasPassing, !passing {
            motion.place(WalkPassThrough.settled(motion.position, collider: collider, setting: s.collision))
        }
        wasPassing = passing
        if !active {
            active = true
            motion.place(resolved(V2(rig.target.x, rig.target.y), activeCollider))
        } else if let w = lastWritten, simd_length(V2(rig.target.x - w.x, rig.target.y - w.y)) > 1 {
            // Moved from outside (pinch, reset, agent): continue from there, but not inside a wall.
            motion.place(resolved(V2(rig.target.x, rig.target.y), activeCollider))
        }

        func down(_ codes: UInt16...) -> Bool { codes.contains { keys.contains($0) } }
        var forward = (down(KeyCode.w, KeyCode.up) ? 1.0 : 0) - (down(KeyCode.s, KeyCode.down) ? 1.0 : 0)
        var strafe = (down(KeyCode.d) ? 1.0 : 0) - (down(KeyCode.a) ? 1.0 : 0)
        let turn = (down(KeyCode.right) ? 1.0 : 0) - (down(KeyCode.left) ? 1.0 : 0)
        var crouch = down(KeyCode.c)
        var r = rig
        r.yaw -= turn * 90 * dt

        if let pad = Self.gamepad() {
            let dz = s.controllerDeadzone
            let (mx, my) = Self.stick(Double(pad.leftThumbstick.xAxis.value), Double(pad.leftThumbstick.yAxis.value), deadzone: dz)
            let (lx, ly) = Self.stick(Double(pad.rightThumbstick.xAxis.value), Double(pad.rightThumbstick.yAxis.value), deadzone: dz)
            forward = min(max(forward + my, -1), 1)
            strafe = min(max(strafe + mx, -1), 1)
            r.yaw -= lx * s.controllerSensitivity * dt
            r.pitch += ly * s.controllerSensitivity * dt * (s.invertY ? -1 : 1)
            if pad.buttonB.isPressed { crouch = true }
            let a = pad.buttonA.isPressed
            if a, !padDoorDown { _ = toggleNearestOpening() }
            padDoorDown = a
        }

        if pendingLook != .zero {
            r.yaw -= pendingLook.x * s.mouseSensitivity
            r.pitch -= pendingLook.y * s.mouseSensitivity * (s.invertY ? -1 : 1)
            pendingLook = .zero
        }
        r.pitch = min(max(r.pitch, -89), 89)

        let flags = NSEvent.modifierFlags
        let step: WalkSpeedStep = flags.contains(.shift) ? .fast : (flags.contains(.option) ? .slow : .normal)
        motion.advance(dt: dt, input: WalkInput(forward: forward, strafe: strafe, yawDeg: r.yaw, step: step, crouch: crouch),
                       settings: s, collider: activeCollider)
        let pos = motion.renderedPosition(collider: activeCollider, settings: s)
        r.target = D3(pos.x, pos.y, renderer.activeElevation + motion.eyeHeightMm(settings: s))
        r.fov = fovDeg(s)
        lastWritten = r.target
        renderer.camera.set(r)
        updateHud(s, crouching: crouch, dt: dt)
    }

    private func resolved(_ p: V2, _ c: WalkCollider?) -> V2 { c?.resolve(p) ?? p }

    private func leave() {
        active = false
        wasPassing = false
        lastWritten = nil
        motion.place(.zero)
        releasePointerLock()
        pendingLook = .zero
        lastHud = nil
        renderer.ui?.walk = nil
    }

    func shutdown() {
        isShutDown = true
        screenObservers.forEach { NotificationCenter.default.removeObserver($0) }
        screenObservers = []
        screenFacts = nil
        releasePointerLock()
        renderer.ui?.walk = nil
    }

    private static func gamepad() -> GCExtendedGamepad? {
        (GCController.current ?? GCController.controllers().first)?.extendedGamepad
    }

    /// Radial deadzone with the live range rescaled to 0...1.
    static func stick(_ x: Double, _ y: Double, deadzone: Double) -> (Double, Double) {
        let m = (x * x + y * y).squareRoot()
        guard m > deadzone, m > 0 else { return (0, 0) }
        let k = min((m - deadzone) / max(1 - deadzone, 0.01), 1) / m
        return (x * k, y * k)
    }

    // MARK: Collision

    private func ensureCollider(_ s: WalkSettings) {
        let p = renderer.model.project
        let key = ColliderKey(contentRevision: renderer.model.store.contentRevision, project: p.id, level: renderer.model.activeLevelId, eye: s.eyeHeightMm, radius: s.bodyRadiusMm,
                             showLamps: renderer.options.showLamps)
        guard key != colliderKey else { return }
        colliderKey = key
        var c = WalkCollider(project: p, levelId: key.level, eyeHeightMm: s.eyeHeightMm, bodyRadiusMm: s.bodyRadiusMm,
                              showLamps: key.showLamps)
        pruneOpenings()
        c.setOpenDoors(openings.turnedIds)
        collider = c
    }

    // MARK: Doors

    /// Takes over the open states of another view (offscreen pictures show what the user sees).
    func adopt(_ m: OpeningMotion) {
        let ids = Set(openings.entries.keys).union(m.entries.keys)
        openings = m
        collider?.setOpenDoors(openings.turnedIds)
        for id in ids { applyPose(id) }
    }

    /// Drops open states of openings that are gone or changed shape or size (they show closed again).
    func pruneOpenings() {
        guard !openings.isEmpty else { return }
        openings.prune(current: OpeningSignature.map(renderer.model.project))
    }

    /// Opens, closes (`open` true / false) or toggles (nil) an opening in `mode`. Doors only turn. Returns the mode it is
    /// heading to (`.closed` when shut or when it cannot move).
    @discardableResult
    func setOpening(_ id: UUID, mode: OpeningMode, open: Bool?) -> OpeningMode {
        let p = renderer.model.project
        guard let o = p.opening(id), let sig = OpeningSignature(o, wall: p.wall(o.wallId)) else { return .closed }
        let t = openings.request(id, mode: mode, open: open, signature: sig)
        collider?.setOpenDoors(openings.turnedIds)
        return t
    }

    /// Opens, closes (`open` true / false) or toggles (nil) a door. Returns whether it is open now.
    @discardableResult
    func setDoor(_ id: UUID, open: Bool?) -> Bool {
        setOpening(id, mode: .turn, open: open) != .closed
    }

    /// The closest openable door or window in front of the eye within reach: id, or nil.
    func nearestOpenableInView() -> UUID? {
        let p = renderer.model.project
        let rig = renderer.camera.rig
        let eye = V2(rig.target.x, rig.target.y)
        let fwd = V2(rig.flatForward.x, rig.flatForward.y)
        var best: (UUID, Double)?
        for o in p.openings where o.kind != .opening {
            guard let w = p.wall(o.wallId), w.levelId == renderer.model.activeLevelId, let level = p.level(w.levelId),
                  let sig = OpeningSignature(o, wall: w), sig.movable else { continue }
            let a: V2, b: V2
            if o.kind == .door {
                guard let pl = Meshes.doorLeafPlacement(o, wall: w, baseZ: level.elevation) else { continue }
                a = V2(pl.hinge.x, pl.hinge.y)
                b = a + V2(cos(pl.closedYawDeg * .pi / 180), sin(pl.closedYawDeg * .pi / 180)) * pl.leafWidth
            } else {
                let ps = Meshes.windowSashes(o, wall: w, baseZ: level.elevation).map(\.placement)
                guard let first = ps.first, let last = ps.last else { continue }
                let f = V2(first.pivot.x, first.pivot.y), l = V2(last.pivot.x, last.pivot.y)
                let d = V2(cos(last.closedYawDeg * .pi / 180), sin(last.closedYawDeg * .pi / 180)) * last.width
                a = f; b = (simd_length(l + d - f) > simd_length(l - f)) ? l + d : l
            }
            let ab = b - a
            let t = min(max(simd_dot(eye - a, ab) / max(simd_dot(ab, ab), 1), 0), 1)
            let near = a + ab * t
            let dist = simd_length(near - eye)
            guard dist <= Self.doorReach else { continue }
            let toMid = (a + ab * 0.5) - eye
            let len = simd_length(toMid)
            if len > 400, simd_dot(toMid / len, fwd) < 0.34 { continue }
            if best == nil || dist < best!.1 { best = (o.id, dist) }
        }
        return best?.0
    }

    /// Works the opening in view: turn, or tilt when `tilt` is set (doors only turn).
    @discardableResult
    func toggleNearestOpening(tilt: Bool = false) -> Bool {
        guard let id = nearestOpenableInView() else { return false }
        let isDoor = renderer.model.project.opening(id)?.kind == .door
        setOpening(id, mode: tilt && !isDoor ? .tilt : .turn, open: nil)
        return true
    }

    private func animateDoors(dt: Double) {
        guard !openings.isEmpty else { return }
        let before = openings.entries
        openings.advance(dt: dt, seconds: Self.doorSeconds)
        // Only openings whose entry moved (progress, mode, or gone after closing) get a new pose; one standing open is left alone.
        let after = openings.entries
        var moved: [UUID] = []
        for (id, e) in after where before[id] != e { moved.append(id) }
        for id in before.keys where after[id] == nil { moved.append(id) }
        guard !moved.isEmpty else { return }
        for id in moved { applyPose(id) }
        let wasTurned = Set(before.filter { $0.value.mode == .turn && $0.value.opening }.map(\.key))
        let turned = openings.turnedIds
        if turned != wasTurned { collider?.setOpenDoors(turned) }
    }

    /// Poses the leaf or sashes of an opening to its current state (also used when the wall entity was rebuilt).
    func applyPose(_ id: UUID) {
        guard let o = renderer.model.project.opening(id), let frame = renderer.wallNodes[o.wallId]?.frames[id] else { return }
        let pose = openings.pose(id)
        let p = pose.progress
        let e = p * p * (3 - 2 * p)
        if let leaf = frame.leaf {
            let yaw = leaf.closedYaw + (leaf.openYaw - leaf.closedYaw) * e
            leaf.pivot.orientation = simd_quatf(angle: Float(yaw * .pi / 180), axis: SIMD3(0, 0, 1))
        }
        for s in frame.sashes {
            let turn = pose.mode == .turn ? e : 0
            let tilt = pose.mode == .tilt && s.hasHandle ? e : 0
            s.turnPivot.orientation = simd_quatf(angle: Float((s.closedYaw + turn * s.turnOpenDeg) * .pi / 180), axis: SIMD3(0, 0, 1))
            s.tiltPivot.orientation = simd_quatf(angle: Float(tilt * s.tiltOpenDeg * .pi / 180), axis: SIMD3(1, 0, 0))
        }
    }

    // MARK: Pointer lock

    /// Captures the mouse: the cursor stays put and hidden, movement turns the view. Never in test mode.
    func engagePointerLock() {
        guard !pointerLocked, !AppDefaults.isTestMode, renderer.camera.rig.mode == .firstPerson,
              renderer.arView?.window?.isKeyWindow == true else { return }
        CGAssociateMouseAndMouseCursorPosition(0)
        NSCursor.hide()
        pointerLocked = true
    }

    func releasePointerLock() {
        guard pointerLocked else { return }
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        pointerLocked = false
    }

    /// Mouse delta while captured (view points); applied with the next frame.
    func look(dx: Double, dy: Double) {
        guard pointerLocked else { return }
        pendingLook += SIMD2(dx, dy)
    }

    // MARK: HUD

    private func updateHud(_ s: WalkSettings, crouching: Bool, dt: Double) {
        var scalePt: Int?
        if s.showScale {
            scaleClock += dt
            if scaleClock >= 0.1 {
                scaleClock = 0
                let c = SIMD2(Double(renderer.camera.viewSize.width) / 2, Double(renderer.camera.viewSize.height) / 2)
                scaleDepth = renderer.pickHit(at: c)?.t ?? 3000
            }
            let perPoint = renderer.camera.rig.mmPerPoint(depth: scaleDepth, viewHeight: Double(renderer.camera.viewSize.height))
            let pt = 1000 / max(perPoint, 0.001)
            if pt >= 12, pt <= Double(renderer.camera.viewSize.width) * 0.9 { scalePt = Int(pt.rounded()) }
        }
        let calibrated: Bool
        if case .calibrated = s.fovMode { calibrated = true } else { calibrated = false }
        let info = WalkHUDInfo(eyeMm: Int(motion.eyeHeightMm(settings: s).rounded()),
                               speedTenthsMps: Int((speedMps * 10).rounded()), fovDeg: Int(renderer.camera.rig.fov.rounded()),
                               calibrated: calibrated, crouching: crouching, locked: pointerLocked,
                               scalePoints: scalePt, scaleDepthDm: Int((scaleDepth / 100).rounded()))
        if info != lastHud {
            lastHud = info
            renderer.ui?.walk = info
        }
    }
}
