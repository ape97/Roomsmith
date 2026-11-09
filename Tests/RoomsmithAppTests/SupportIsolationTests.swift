import Foundation
import Testing
import RoomsmithCore
@testable import Roomsmith

/// Hosted tests must never write into the user's real Application Support folder (recovery dialogs at next launch).
struct SupportIsolationTests {
    @Test @MainActor func testsNeverUseTheRealSupportFolder() {
        let real = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Roomsmith").standardizedFileURL.path
        for url in [AgentPaths.supportDirectory, Autosave.root, SessionState.defaultURL, AgentPaths.socketURL, AgentPaths.tokenURL] {
            #expect(!url.standardizedFileURL.path.hasPrefix(real), "\(url.path) is inside the real support folder")
        }
    }
}
