import AppKit
import Combine
import Foundation
import os
import RealityKit
import RoomsmithCore
import simd

extension Duration {
    /// Milliseconds as a Double.
    var ms: Double { Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15 }
}

/// Timing output behind `ROOMSMITH_PERF=1` (stdout lines plus signposts for Instruments).
enum PerfLog {
    static let signposter = OSSignposter(subsystem: "app.roomsmith", category: "scene")

    static func line(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    static func sync(_ name: String, ms: Double, objects: Int) {
        signposter.emitEvent("scene sync")
        line("ROOMSMITH_PERF sync name=\(name) objects=\(objects) ms=\(String(format: "%.3f", ms))")
    }
}

// MARK: - Attaching to a view, frame loop

extension SceneRenderer {
    /// Puts the scene graph into an `ARView` and starts the per-frame update.
    func attach(to view: ARView) {
        arView = view
        let anchor = AnchorEntity(world: .zero)
        anchor.addChild(worldRoot)
        view.scene.addAnchor(anchor)
        applyAppearance(dark: SceneEnvironment.isDark(view.effectiveAppearance))
        let sub = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            let dt = event.deltaTime
            MainActor.assumeIsolated { self?.tick(dt: dt) }
        }
        subscriptions.append(sub)
        installMeasureOverlay(in: view)
        applyCamera()
        runPerfProbeIfRequested()
    }

    /// Called once per rendered frame (RealityKit `SceneEvents.Update`).
    func tick(dt rawDt: Double) {
        frameTicks += 1
        guard !stopped else { return }
        let dt = min(max(rawDt, 0), 0.1)

        if interactive { walk.tick(dt: dt); tickFlight(dt: dt); refreshMeasureOverlay() }

        if !animations.isEmpty {
            var finished: [UUID] = []
            for (id, var anim) in Array(animations) {
                guard let node = instNodes[id] else { animations[id] = nil; continue }
                let poses = anim.advance(dt)
                applyPoses(node, poses)
                if anim.finished { animations[id] = nil; finished.append(id) } else { animations[id] = anim }
            }
            // The last frame is the resolver's own pose, so the end transforms are exact.
            for id in finished { syncInstance(id, force: true) }
        }
    }

    // MARK: Camera

    func applyCamera() {
        let rig = camera.rig
        cameraEntity.transform.matrix = rig.entityMatrix
        cameraEntity.camera.fieldOfViewInDegrees = Float(rig.viewFov)
        let nf = rig.nearFar
        cameraEntity.camera.near = nf.near
        cameraEntity.camera.far = nf.far
        followGround(rig, far: Double(nf.far))
    }

    /// The ground plane is centred under the eye and always reaches past the far plane, so its edge is never
    /// visible (only the horizon cut by the far plane). The shadow range grows with the view distance in steps.
    func followGround(_ rig: CameraRig, far: Double) {
        let eye = SceneCoords.world(rig.eye)
        ground.position.x = eye.x
        ground.position.z = eye.z
        let scale = Float(max(1, far * 2.2 / SceneRenderer.groundSize))
        if abs(ground.scale.x - scale) > 0.01 { ground.scale = SIMD3(scale, 1, scale) }
        let wanted = SceneRenderer.shadowRange(viewDistanceMM: rig.viewDistance)
        if sunShadowsOn, sun.shadow?.maximumDistance != wanted {
            sun.shadow = DirectionalLightComponent.Shadow(maximumDistance: wanted, depthBias: 2)
        }
    }

    /// Every change of the rig: camera entity, gizmo size, mode picker, and (debounced) the stored camera.
    func cameraChanged() {
        if camera.rig.mode != lastRigMode {
            let old = lastRigMode
            lastRigMode = camera.rig.mode
            modeDidChange(from: old, to: lastRigMode)
        }
        applyCamera()
        placeGizmo()
        updateViewMode()
        schedulePersist()
    }

    func updateViewMode() {
        let r = camera.rig
        let mode: SceneViewMode
        switch r.mode {
        case .firstPerson: mode = .firstPerson
        case .top: mode = .top
        case .free: mode = .free
        case .orbit: mode = abs(r.pitch - SceneCameraController.aerialPitch) < 0.5 ? .aerial : .orbit
        }
        if let ui, ui.viewMode != mode { ui.viewMode = mode }
    }

    /// Free camera: flies with the held keys; the velocity coasts out after release (`FreeFlight`).
    func tickFlight(dt: Double) {
        guard camera.rig.mode == .free else {
            if flight.isMoving { flight.stop() }
            return
        }
        let keys = pressedKeys
        func axis(_ plus: UInt16, _ minus: UInt16) -> Double { (keys.contains(plus) ? 1.0 : 0) - (keys.contains(minus) ? 1.0 : 0) }
        let flags = NSEvent.modifierFlags
        let step: FlightSpeedStep = flags.contains(.shift) ? .fast : (flags.contains(.option) ? .slow : .normal)
        let input = FreeFlightInput(forward: axis(KeyCode.w, KeyCode.s), strafe: axis(KeyCode.d, KeyCode.a),
                                    vertical: axis(KeyCode.e, KeyCode.q), step: step)
        guard flight.isMoving || input.forward != 0 || input.strafe != 0 || input.vertical != 0 else { return }
        var r = camera.rig
        let d = flight.advance(dt: dt, input: input, yawDeg: r.yaw, pitchDeg: r.pitch)
        guard d != .zero else { return }
        r.target += d
        camera.set(r)
    }

    /// The camera mode changed (view picker, agent, undo, open). Free flight stops; leaving or entering first
    /// person switches gizmo, selection tint and hover off or on again.
    func modeDidChange(from old: CameraMode, to new: CameraMode) {
        guard interactive else { return }
        pressedKeys.removeAll()
        // Space held as the temporary Hand tool must not carry over into first person, where Space walks through walls.
        if new == .firstPerson, spaceHeld { spaceHeld = false; handModeDidChange() }
        flight.stop()
        if case .gizmo = drag { endGizmoDrag(commit: false) }
        pendingClick = nil
        if !new.allowsSelectionEditing, model.hoveredId != nil { model.hoveredId = nil }
        if old.allowsSelectionEditing != new.allowsSelectionEditing {
            refreshSelectionTints()
            applyTints(selectedExpanded.union(hoveredExpanded))
        }
        updateGizmo()
    }

    // MARK: Camera persistence

    /// The view follows the project camera (open, undo, agent): do not write it back.
    func adoptProjectCamera() {
        persistPending = false
        lastPersisted = camera.rig.state
    }

    /// Writes the camera into the document after the movement has been quiet for `TrackpadTuning.persistDelay`.
    /// Never per frame; clicks, pinch ends and mode changes flush immediately. Every change only moves the deadline; one
    /// task waits for it (not one sleeping task per change, which piles up at 60 changes a second while walking).
    func schedulePersist() {
        guard interactive, !stopped else { return }
        persistPending = true
        persistDeadline = ContinuousClock.now + .seconds(TrackpadTuning.persistDelay)
        guard persistTask == nil else { return }
        persistTask = Task { @MainActor [weak self] in
            // The renderer is only held between sleeps, so a closed view is not kept alive by its pending write.
            while let wait = self?.persistWait() {
                try? await Task.sleep(for: wait)
                if Task.isCancelled { return }
            }
        }
    }

    /// How long the persist task still has to wait; nil when it is done (it has written, or nothing is pending any more).
    private func persistWait() -> Duration? {
        guard !stopped, persistPending else { persistTask = nil; return nil }
        let wait = persistDeadline - ContinuousClock.now
        if wait > .zero { return wait }
        persistPending = false
        persistTask = nil
        persistCamera()
        return nil
    }

    func flushCameraPersistence() {
        persistPending = false
        persistCamera()
    }

    private func persistCamera() {
        guard interactive else { return }
        let state = camera.rig.state
        guard state != lastPersisted else { return }
        lastPersisted = state
        _ = try? model.store.run("Camera", options: CommandOptions(origin: .system, recordUndo: false)) { $0.setCamera(state) }
    }

    // MARK: Collision warnings

    func scheduleCollisions() {
        guard interactive, !stopped else { return }
        collisionGeneration += 1
        let gen = collisionGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !self.stopped, gen == self.collisionGeneration else { return }
            self.runCollisions(gen: gen)
        }
    }

    private func runCollisions(gen: Int) {
        let p = model.project
        guard p.settings.collisionWarnings else {
            if !colliding.isEmpty {
                let old = colliding
                colliding = []
                applyTints(old)
            }
            return
        }
        // Content revision: the camera write of a walking user must not discard a check that is still running.
        let revision = model.store.contentRevision
        Task.detached(priority: .utility) { [weak self] in
            var ids = Set<UUID>()
            for level in p.levels {
                ids.formUnion(CollisionChecker.warnedIds(CollisionChecker.check(p, levelId: level.id), in: p))
            }
            let found = ids
            await MainActor.run {
                guard let self, !self.stopped, gen == self.collisionGeneration else { return }
                // The document moved on while the check ran: this result is stale, so plan a fresh one instead of dropping it.
                guard self.model.store.contentRevision == revision else { self.scheduleCollisions(); return }
                self.collisionRevision = revision
                let changed = self.colliding.symmetricDifference(found)
                self.colliding = found
                self.applyTints(changed)
            }
        }
    }

    // MARK: Benchmark line

    private func countEntities(_ e: Entity) -> Int {
        e.children.reduce(1) { $0 + countEntities($1) }
    }

    /// `ROOMSMITH_BENCHMARK=1`: one stdout line after the first full build of a project with furniture:
    /// `ROOMSMITH_SCENE entities=<n> buildMs=<ms> fps=<measured over ~3 s or n/a>`.
    func reportSceneLineIfNeeded() {
        guard interactive, AppDefaults.isTestMode, env["ROOMSMITH_BENCHMARK"] == "1", !Self.didPrintSceneLine, !instNodes.isEmpty else { return }
        let build = lastBuildMs
        let entities = countEntities(contentRoot)
        let startTicks = frameTicks
        let t0 = ContinuousClock.now
        Task { @MainActor [self] in
            try? await Task.sleep(for: .seconds(3.2))
            // SwiftUI may have replaced this renderer meanwhile; only a live one reports, and only once.
            guard !self.stopped, !Self.didPrintSceneLine else { return }
            Self.didPrintSceneLine = true
            let seconds = (ContinuousClock.now - t0).ms / 1000
            let ticks = self.frameTicks - startTicks
            let fps = ticks >= 2 ? String(format: "%.1f", Double(ticks) / seconds) : "n/a"
            let line = "ROOMSMITH_SCENE entities=\(entities) buildMs=\(String(format: "%.1f", build)) fps=\(fps)\n"
            FileHandle.standardOutput.write(Data(line.utf8))
        }
    }

    // MARK: Latency probe

    /// `ROOMSMITH_PERF_PROBE=1`: moves the first piece of furniture 30 times through the command engine and prints
    /// the time from the command to the finished scene sync and to the next frame update. Undoes the moves.
    func runPerfProbeIfRequested() {
        guard interactive, AppDefaults.isTestMode, env["ROOMSMITH_PERF_PROBE"] == "1" else { return }
        Task { @MainActor [weak self] in
            let deadline = ContinuousClock.now + .seconds(15)
            while ContinuousClock.now < deadline {
                guard let self else { return }
                if !self.instNodes.isEmpty, self.frameTicks >= 10 { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let self, let first = self.model.project.instances.first else {
                PerfLog.line("ROOMSMITH_PERF probe skipped (no furniture or no frames)")
                return
            }
            var command: [Double] = [], sync: [Double] = [], frame: [Double] = []
            var done = 0
            for _ in 0..<30 {
                let before = self.frameTicks
                let t0 = ContinuousClock.now
                guard self.model.perform("Probe move", { try $0.moveObjects([first.id], by: P3(10, 0, 0)) }) else { break }
                command.append((ContinuousClock.now - t0).ms)
                sync.append(self.lastSyncMs)
                while self.frameTicks == before, (ContinuousClock.now - t0).ms < 1000 {
                    try? await Task.sleep(for: .milliseconds(1))
                }
                frame.append((ContinuousClock.now - t0).ms)
                done += 1
                try? await Task.sleep(for: .milliseconds(30))
            }
            for _ in 0..<done { self.model.undo() }
            func stat(_ v: [Double]) -> String {
                guard !v.isEmpty else { return "n/a" }
                let s = v.sorted()
                return String(format: "median=%.2f p95=%.2f max=%.2f", s[s.count / 2], s[min(s.count - 1, Int(Double(s.count) * 0.95))], s.last!)
            }
            PerfLog.line("ROOMSMITH_PERF probe instances=\(self.model.project.instances.count) entities=\(self.countEntities(self.contentRoot)) moves=\(done)")
            PerfLog.line("ROOMSMITH_PERF probe syncMs \(stat(sync))")
            PerfLog.line("ROOMSMITH_PERF probe commandMs \(stat(command))")
            let rendering = self.frameTicks > 0
            PerfLog.line("ROOMSMITH_PERF probe commandToNextFrameMs \(rendering ? stat(frame) : "n/a (no frame updates: window not visible)")")
        }
    }
}

/// Key codes used by the first-person controls.
enum KeyCode {
    static let a: UInt16 = 0, s: UInt16 = 1, d: UInt16 = 2, w: UInt16 = 13, e: UInt16 = 14, c: UInt16 = 8, q: UInt16 = 12
    static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
    static let escape: UInt16 = 53, space: UInt16 = 49, v: UInt16 = 9, h: UInt16 = 4
    static let backspace: UInt16 = 51, forwardDelete: UInt16 = 117
    static func isDelete(_ code: UInt16) -> Bool { code == backspace || code == forwardDelete }
    /// Held keys that move the walker (E opens a door and is handled as a single press).
    static let walking: Set<UInt16> = [a, s, d, w, c, left, right, down, up]
    /// Held keys that fly the free camera (W S forward/back, A D sideways, Q down, E up).
    static let flying: Set<UInt16> = [w, a, s, d, q, e]
}
