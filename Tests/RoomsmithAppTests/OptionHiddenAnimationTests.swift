import Foundation
import Testing
import RoomsmithCore
@testable import Roomsmith

/// A state animation drives every part from its pose; parts hidden by the instance's selected option must stay hidden.
@MainActor
struct OptionHiddenAnimationTests {
    @Test func poseVisibilityRespectsOptionHiddenParts() throws {
        let model = AppModel()
        var instId: UUID?
        var shownId = UUID(), hiddenId = UUID(), openId = UUID()
        model.perform("Setup") { p in
            let a = Component(name: "Frame", shape: .box, position: P3(0, 0, 375), size: Size3(1000, 500, 750))
            let b = Component(name: "Glass", shape: .box, position: P3(0, 0, 375), size: Size3(1000, 500, 750))
            shownId = a.id; hiddenId = b.id
            let plain = OptionChoice(name: "Plain", effects: [b.id: OptionEffect(visible: true)])
            let solid = OptionChoice(name: "Solid", effects: [b.id: OptionEffect(visible: false)])
            let group = OptionGroup(name: "Door", choices: [plain, solid], defaultChoiceId: plain.id)
            var def = FurnitureDefinition(name: "Cabinet", category: "Test", size: Size3(1000, 500, 750), components: [a, b])
            def.optionGroups = [group]
            def.states = [FurnitureState(name: "Closed"), FurnitureState(name: "Open")]
            def.tracks = [AnimationTrack(fromStateId: nil, toStateId: def.states[1].id)]
            _ = p.addDefinition(def)
            let id = try p.addInstance(definitionId: def.id, levelId: model.activeLevelId, position: P3(0, 0, 0))
            try p.updateInstance(id) { $0.optionSelection = [group.id: solid.id] }
            instId = id
            openId = def.states[1].id
        }
        let id = try #require(instId)
        let scene = SceneRenderer(model: model, interactive: true)
        scene.syncInstance(id, force: true)   // populated, merged form
        // A state change with a track starts a transition: every part is its own entity and poses drive it.
        model.perform("Open") { p in try p.updateInstance(id) { $0.stateId = openId } }
        scene.syncInstance(id)
        #expect(scene.animations[id] != nil)
        let node = try #require(scene.instNodes[id])
        let shown = try #require(node.comps[shownId])
        let hidden = try #require(node.comps[hiddenId])
        #expect(shown.entity.isEnabled)
        #expect(!hidden.entity.isEnabled)   // first frame of the transition
        let poseOn = StateAnimation.Pose(position: D3(0, 0, 375), size: D3(1000, 500, 750), rotation: D3(0, 0, 0), visible: true)
        scene.applyPoses(node, [(shownId, poseOn, nil), (hiddenId, poseOn, nil)])   // a later frame
        #expect(shown.entity.isEnabled)
        #expect(!hidden.entity.isEnabled)
    }
}
