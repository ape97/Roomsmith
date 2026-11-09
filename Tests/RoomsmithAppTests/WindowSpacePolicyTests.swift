import AppKit
import Testing
@testable import Roomsmith

@MainActor
@Suite struct WindowSpacePolicyTests {
    @Test func presenterWindowNeitherFloatsNorJoinsAllSpaces() {
        let w = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces]
        PresenterWindowController.applyWindowPolicy(to: w)
        #expect(w.level == .normal)
        #expect(!w.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(!w.collectionBehavior.contains(.stationary))
    }
}
