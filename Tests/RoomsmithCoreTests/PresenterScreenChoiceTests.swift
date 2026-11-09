import Testing
@testable import RoomsmithCore

@Suite struct PresenterScreenChoiceTests {
    typealias C = PresenterScreenChoice.Candidate
    let main = C(id: 1, name: "Built-in Display", isMain: true)

    @Test func noExternalDisplayGivesNil() {
        #expect(PresenterScreenChoice.choose([main]) == nil)
        #expect(PresenterScreenChoice.added([main], known: []) == nil)
    }

    @Test func mainIsNeverChosen() {
        let ext = C(id: 2, name: "DELL", isMain: false)
        #expect(PresenterScreenChoice.choose([main, ext])?.id == 2)
    }

    @Test func airPlayNamePreferredOverLaterDisplay() {
        let tv = C(id: 2, name: "Living Room Apple TV", isMain: false)
        let other = C(id: 3, name: "DELL", isMain: false)
        #expect(PresenterScreenChoice.choose([main, tv, other], known: [1, 2])?.id == 2)
    }

    @Test func lastAddedWinsWithoutAirPlayName() {
        let a = C(id: 2, name: "A", isMain: false), b = C(id: 3, name: "B", isMain: false)
        #expect(PresenterScreenChoice.choose([main, a, b], known: [1, 3])?.id == 2)
        #expect(PresenterScreenChoice.choose([main, a, b], known: [1, 2, 3])?.id == 3)
    }

    @Test func addedOnlyReportsNewExternalDisplays() {
        let a = C(id: 2, name: "A", isMain: false), b = C(id: 3, name: "B", isMain: false)
        #expect(PresenterScreenChoice.added([main, a], known: [1, 2]) == nil)
        #expect(PresenterScreenChoice.added([main, a, b], known: [1, 2])?.id == 3)
    }

    @Test func airPlayDetectionIsCaseInsensitive() {
        #expect(PresenterScreenChoice.looksLikeAirPlay("AIRPLAY Display"))
        #expect(!PresenterScreenChoice.looksLikeAirPlay("DELL U2720"))
    }
}
