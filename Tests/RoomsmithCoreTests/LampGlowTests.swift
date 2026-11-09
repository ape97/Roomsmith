import Foundation
import Testing
@testable import RoomsmithCore

private func lamp() -> FurnitureDefinition {
    FurnitureDefinition(name: "Lamp", category: "Lighting", size: Size3(400, 400, 1600), components: [
        Component(name: "Base", shape: .cylinder, position: P3(0, 0, 15), size: Size3(300, 300, 30)),
        Component(name: "Pole", shape: .cylinder, position: P3(0, 0, 700), size: Size3(30, 30, 1300)),
        Component(name: "Shade", shape: .taper, position: P3(0, 0, 1450), size: Size3(400, 400, 300))])
}

struct LampGlowTests {
    @Test func noEmitterNoGlow() {
        #expect(LampGlow.glow(definition: lamp(), state: nil) == nil)
    }

    @Test func theLargestPartAroundTheEmitterGlowsInItsColour() throws {
        var d = lamp()
        var e = LightEmitter(name: "Bulb", kind: .point, position: P3(0, 0, 1340))   // inside the shade and the pole top
        e.color = RGBColor(255, 200, 100)
        d.lights = [e]
        let g = try #require(LampGlow.glow(definition: d, state: nil))
        #expect(g.componentIds == [d.components[2].id])
        #expect(abs(g.color.x - 1) < 1e-9 && abs(g.color.y - 200.0 / 255) < 1e-9)
    }

    @Test func anEmitterJustBelowTheShadeOpeningStillFindsIt() throws {
        var d = lamp()
        d.lights = [LightEmitter(name: "Bulb", position: P3(0, 150, 1290))]   // 10 mm under the shade, outside the pole
        #expect(LampGlow.glow(definition: d, state: nil)?.componentIds == [d.components[2].id])
        d.lights = [LightEmitter(name: "Far", position: P3(0, 0, 2000))]
        #expect(LampGlow.glow(definition: d, state: nil) == nil)
    }

    @Test func aHiddenShadeDoesNotGlow() {
        var d = lamp()
        d.lights = [LightEmitter(name: "Bulb", position: P3(0, 150, 1400))]
        let st = FurnitureState(name: "Bare", poses: [d.components[2].id: ComponentPose(visible: false)])
        #expect(LampGlow.glow(definition: d, state: st) == nil)
    }
}
