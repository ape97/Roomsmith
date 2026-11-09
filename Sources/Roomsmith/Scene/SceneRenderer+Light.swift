import AppKit
import Foundation
import RealityKit
import RoomsmithCore

// Sun, sky and lamps of the 3D scene, driven by the document's `LightingSettings` and the lamps of the furniture designs.
// The live view and the offscreen renderer (presenter, render tools, snapshots) share this code.
//
// RealityKit limits that shape the result:
// - Point lights never cast shadows, so lamps are unshadowed (light passes through walls and furniture). Only the sun casts shadows.
// - There is no physical sky: the sky is a small generated environment image per mood; sun position and sky are not tied together.
// - Lights are expensive: at most `LightRig.maxActive` (8) lamps shine, the strongest first.
// - Lamp brightness maps lumens to RealityKit intensity with `lampGain`; that factor is a visual estimate, not photometrically calibrated.
// - The OBJ/USDZ export (SceneExport) carries geometry and materials but no lamps or sun.

/// What the last `applyLighting` pass applied, to skip identical passes.
struct AppliedLook: Equatable {
    var settings: LightingSettings
    var dark: Bool
    var lamps: [ActiveLight]
}

/// One reusable lamp entity.
struct LampSlot {
    var kind: LightKind
    var entity: Entity
}

extension SceneRenderer {
    /// RealityKit intensity of the full daylight sun (the value the scene always used).
    static let sunFullIntensity: Float = 3200
    /// RealityKit light intensity per lumen of a lamp. Estimated by eye, not calibrated.
    static let lampGain: Float = 40

    /// Applies sun, sky, ground and lamps. Cheap when nothing changed.
    func applyLighting(force: Bool = false) {
        let p = model.project
        let settings = p.settings.lighting
        let lamps = LightRig.collect(p, levelVisible: { [weak self] in self?.levelShown($0) ?? true }).active
        let now = AppliedLook(settings: settings, dark: lastDark, lamps: lamps)
        if !force, now == appliedLook { return }
        let old = appliedLook
        appliedLook = now

        let skyChanged = force || old?.settings.mood != settings.mood || old?.dark != lastDark
        if force || old?.settings != settings { applySun(settings) }
        if skyChanged || old?.settings.exposure != settings.exposure { applySky(settings, reloadImage: skyChanged) }
        if force || old?.lamps != lamps || old?.settings.exposure != settings.exposure { applyLamps(lamps, exposure: settings.exposure) }
    }

    private func applySun(_ s: LightingSettings) {
        let look = SunSkyLook(s)
        let travel = SceneCoords.worldDirection(look.sunTravel)
        let up: SIMD3<Float> = abs(travel.y) > 0.99 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
        sun.look(at: .zero, from: -travel * 10, upVector: up, relativeTo: nil)
        let c = look.sunColor
        sun.light.color = NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
        sun.light.intensity = Self.sunFullIntensity * Float(look.sunIntensity * pow(2, s.exposure))
        sun.isEnabled = look.sunIntensity > 0.001
        sunShadowsOn = look.sunShadows
        if look.sunShadows {
            if sun.shadow == nil { sun.shadow = DirectionalLightComponent.Shadow(maximumDistance: 40, depthBias: 2) }
        } else {
            sun.shadow = nil
        }
    }

    private func applySky(_ s: LightingSettings, reloadImage: Bool) {
        let dark = lastDark, mood = s.mood
        let look = SunSkyLook(s)
        ground.model?.materials = [Self.groundMaterial(dark: dark, mood: mood)]
        arView?.environment.background = .color(SceneEnvironment.backgroundColor(dark: dark, mood: mood))
        arView?.environment.lighting.intensityExponent = Float(log2(max(look.ambient, 0.001)) + look.exposureEV)
        guard reloadImage else { return }
        Task { @MainActor [weak self] in
            guard let res = await SceneEnvironment.resource(mood: mood), let self,
                  self.appliedLook?.settings.mood == mood, self.lastDark == dark else { return }   // a newer mood may have arrived
            self.arView?.environment.lighting.resource = res
        }
    }

    private func applyLamps(_ lamps: [ActiveLight], exposure: Double) {
        let gain = Self.lampGain * Float(pow(2, exposure))
        while lampSlots.count > lamps.count { lampSlots.removeLast().entity.removeFromParent() }
        let plan = LampSlotPlan.plan(current: lampSlots.map(\.kind), wanted: lamps.map(\.kind))
        for (i, l) in lamps.enumerated() {
            if plan[i] == .create {
                let e: Entity = l.kind == .spot ? SpotLight() : PointLight()
                lampRoot.addChild(e)
                let slot = LampSlot(kind: l.kind, entity: e)
                if i < lampSlots.count {
                    lampSlots[i].entity.removeFromParent()
                    lampSlots[i] = slot
                } else {
                    lampSlots.append(slot)
                }
            }
            let color = NSColor(srgbRed: CGFloat(l.color.x), green: CGFloat(l.color.y), blue: CGFloat(l.color.z), alpha: 1)
            let intensity = Float(l.lumens) * gain
            let radius = Float(l.rangeMm / 1000)
            let pos = SceneCoords.world(l.position)
            let e = lampSlots[i].entity
            if let light = e as? PointLight {
                light.light.color = color; light.light.intensity = intensity; light.light.attenuationRadius = radius
                light.position = pos
            } else if let light = e as? SpotLight {
                light.light.color = color; light.light.intensity = intensity; light.light.attenuationRadius = radius
                let outer = Float(l.coneDeg)
                light.light.outerAngleInDegrees = outer
                light.light.innerAngleInDegrees = outer * 0.7
                let dir = SceneCoords.worldDirection(l.direction)
                let up: SIMD3<Float> = abs(dir.y) > 0.99 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
                light.look(at: pos + dir, from: pos, upVector: up, relativeTo: nil)
            }
        }
    }
}
