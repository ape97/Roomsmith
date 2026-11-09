import Testing
import Foundation
@testable import RoomsmithCore

@Suite("UserMessage") struct UserMessageTests {
    private enum Plain: Error { case boom(Int) }

    @Test func structuredErrorsKeepTheirText() {
        #expect(userMessage(for: CommandError.invalid("Width must be positive")) == "Width must be positive")
        #expect(userMessage(for: AgentError(code: AgentError.invalidArgument, message: "Bad level")) == "Bad level")
        #expect(userMessage(for: LibraryError.invalid("Name is empty")) == "Name is empty")
    }

    @Test func persistenceErrorGetsNextStep() {
        let m = userMessage(for: PersistenceError("Unknown key", line: 4))
        #expect(m.contains("line 4: Unknown key"))
        #expect(m.contains("try again"))
    }

    @Test func fileErrorsAreExplained() {
        #expect(userMessage(for: CocoaError(.fileNoSuchFile)).contains("does not exist"))
        #expect(userMessage(for: CocoaError(.fileWriteNoPermission)).contains("permission"))
        #expect(userMessage(for: CocoaError(.fileWriteOutOfSpace)).contains("disk is full"))
    }

    @Test func plainSwiftErrorsNeverLeakTypeNames() {
        let m = userMessage(for: Plain.boom(7))
        #expect(!m.contains("Plain"))
        #expect(!m.contains("boom"))
        #expect(m.contains("Try again"))
    }

    @Test func sceneSummaryCountsActiveLevelOnly() throws {
        var p = Project.empty(name: "T")
        let l = try #require(p.levels.first).id
        _ = try p.addWall(levelId: l, start: P2(0, 0), end: P2(3000, 0))
        let other = p.addLevel(name: "Upper")
        _ = try p.addWall(levelId: other, start: P2(0, 0), end: P2(3000, 0))
        let t = SceneSummary.text(p, levelId: l, selected: 2, view: "Floor plan")
        #expect(t.contains("1 wall,"))
        #expect(t.contains("0 rooms"))
        #expect(t.hasSuffix("2 selected"))
        #expect(SceneSummary.text(p, levelId: l, selected: 0, view: "3D view").hasSuffix("nothing selected"))
    }

    private struct Described: LocalizedError { var errorDescription: String? { "Described failure" } }

    @Test func localizedErrorKeepsItsText() {
        #expect(userMessage(for: Described()) == "Described failure")
    }

    @Test func bridgedNSErrorIsReadableWithNextStep() {
        let e = NSError(domain: NSPOSIXErrorDomain, code: 13, userInfo: [NSLocalizedDescriptionKey: "Permission denied"])
        #expect(userMessage(for: e) == "Permission denied. Check the file and try again.")
        let other = NSError(domain: "com.example.custom", code: 5)
        #expect(!userMessage(for: other).contains("com.example"))
    }
}
