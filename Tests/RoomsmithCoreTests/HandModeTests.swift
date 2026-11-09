import Testing
@testable import RoomsmithCore

@Suite("HandMode") struct HandModeTests {
    @Test func handToolOrSpaceMakesTheViewLookOnly() {
        #expect(!HandMode.isActive(toolIsHand: false, spaceHeld: false))
        #expect(HandMode.isActive(toolIsHand: true, spaceHeld: false))
        #expect(HandMode.isActive(toolIsHand: false, spaceHeld: true))
        #expect(HandMode.isActive(toolIsHand: true, spaceHeld: true))
    }

    @Test func editingIsOnlyAllowedOutsideHandMode() {
        #expect(HandMode.allowsEditing(toolIsHand: false, spaceHeld: false))
        #expect(!HandMode.allowsEditing(toolIsHand: true, spaceHeld: false))
        #expect(!HandMode.allowsEditing(toolIsHand: false, spaceHeld: true))
        // A view that never edits (3D first person) stays look-only whatever the tool is.
        #expect(!HandMode.allowsEditing(toolIsHand: false, spaceHeld: false, cameraAllowsEditing: false))
        #expect(!HandMode.allowsEditing(toolIsHand: true, spaceHeld: false, cameraAllowsEditing: false))
    }

    @Test func leftDragNavigatesInHandMode() {
        #expect(HandMode.leftDragNavigates(toolIsHand: true, spaceHeld: false))
        #expect(HandMode.leftDragNavigates(toolIsHand: false, spaceHeld: true))
        #expect(!HandMode.leftDragNavigates(toolIsHand: false, spaceHeld: false))
    }

    @Test func plainLettersSwitchTools() {
        func key(_ c: String?, command: Bool = false, control: Bool = false, option: Bool = false) -> HandMode.Shortcut? {
            HandMode.shortcut(characters: c, command: command, control: control, option: option)
        }
        #expect(key("h") == .hand)
        #expect(key("H") == .hand)
        #expect(key("v") == .select)
        #expect(key("V") == .select)
    }

    @Test func otherKeysAndModifiedKeysDoNotSwitchTools() {
        func key(_ c: String?, command: Bool = false, control: Bool = false, option: Bool = false) -> HandMode.Shortcut? {
            HandMode.shortcut(characters: c, command: command, control: control, option: option)
        }
        #expect(key("w") == nil)
        #expect(key("r") == nil)
        #expect(key(" ") == nil)
        #expect(key("") == nil)
        #expect(key("hv") == nil)
        #expect(key(nil) == nil)
        #expect(key("h", command: true) == nil)
        #expect(key("v", command: true) == nil)
        #expect(key("h", control: true) == nil)
        #expect(key("h", option: true) == nil)
    }

    @Test func escapeLeavesOnlyTheHandTool() {
        #expect(HandMode.escapeLeavesHand(toolIsHand: true))
        #expect(!HandMode.escapeLeavesHand(toolIsHand: false))
    }
}
