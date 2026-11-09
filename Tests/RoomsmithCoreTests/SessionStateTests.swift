import Testing
import Foundation
@testable import RoomsmithCore

// The last-session file and the "Open Recent" list: order, duplicates, limit, missing files, round trip, broken input.

private func tempFile(_ name: String = "session.json") -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("roomsmith-session-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent(name)
}

struct RecentProjectsTests {
    @Test func newestFirst() {
        var r = RecentProjects()
        r.note("/a/one.roomsmith"); r.note("/a/two.roomsmith"); r.note("/a/three.roomsmith")
        #expect(r.entries == ["/a/three.roomsmith", "/a/two.roomsmith", "/a/one.roomsmith"])
    }

    @Test func noteAgainMovesToFrontWithoutDuplicate() {
        var r = RecentProjects(entries: ["/a/one.roomsmith", "/a/two.roomsmith"])
        r.note("/a/two.roomsmith")
        #expect(r.entries == ["/a/two.roomsmith", "/a/one.roomsmith"])
    }

    @Test func duplicatesAreFoundOverTheStandardizedPath() {
        var r = RecentProjects()
        r.note("/a/b/../one.roomsmith")
        r.note("/a/./one.roomsmith")
        #expect(r.entries == ["/a/one.roomsmith"])
        #expect(RecentProjects(entries: ["/x/y/../p.roomsmith", "/x/p.roomsmith"]).entries == ["/x/p.roomsmith"])
    }

    @Test func keepsAtMostTen() {
        var r = RecentProjects()
        for i in 0..<14 { r.note("/a/p\(i).roomsmith") }
        #expect(r.entries.count == RecentProjects.limit)
        #expect(r.entries.first == "/a/p13.roomsmith")
        #expect(r.entries.last == "/a/p4.roomsmith")
        #expect(RecentProjects(entries: (0..<30).map { "/a/q\($0).roomsmith" }).entries.count == 10)
    }

    @Test func clearAndRemove() {
        var r = RecentProjects(entries: ["/a/one.roomsmith", "/a/two.roomsmith"])
        r.remove("/a/./one.roomsmith")
        #expect(r.entries == ["/a/two.roomsmith"])
        r.clear()
        #expect(r.isEmpty)
    }

    @Test func missingFilesAreFilteredOnLoad() throws {
        let url = tempFile("recent.json")
        try RecentProjects(entries: ["/a/here.roomsmith", "/a/gone.roomsmith", "/a/also.roomsmith"]).save(to: url)
        let r = RecentProjects.load(from: url, fileExists: { $0 != "/a/gone.roomsmith" })
        #expect(r.entries == ["/a/here.roomsmith", "/a/also.roomsmith"])
    }

    @Test func realExistenceCheckDropsDeletedFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roomsmith-recent-\(UUID().uuidString)", isDirectory: true)
        let pkg = dir.appendingPathComponent("Real.roomsmith", isDirectory: true)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("recent.json")
        try RecentProjects(entries: [pkg.path, dir.appendingPathComponent("Nope.roomsmith").path]).save(to: url)
        #expect(RecentProjects.load(from: url).entries == [pkg.standardizedFileURL.path])
    }

    @Test func roundTrip() throws {
        let url = tempFile("recent.json")
        let r = RecentProjects(entries: ["/a/one.roomsmith", "/b/two.roomsmith"])
        try r.save(to: url)
        #expect(RecentProjects.load(from: url, fileExists: { _ in true }) == r)
    }

    @Test func brokenOrNewerFileIsEmpty() throws {
        let url = tempFile("recent.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(RecentProjects.load(from: url, fileExists: { _ in true }).isEmpty)  // missing
        try Data("{ not json".utf8).write(to: url)
        #expect(RecentProjects.load(from: url, fileExists: { _ in true }).isEmpty)
        try Data(#"{"version":99,"entries":["/a/x.roomsmith"]}"#.utf8).write(to: url)
        #expect(RecentProjects.load(from: url, fileExists: { _ in true }).isEmpty)
    }

    @Test func menuTitlesUseFileNameAndParentOnlyForClashes() {
        let r = RecentProjects(entries: ["/home/Flat.roomsmith", "/work/Flat.roomsmith", "/work/Office.roomsmith"])
        let items = r.items()
        #expect(items.map(\.title) == ["Flat.roomsmith — home", "Flat.roomsmith — work", "Office.roomsmith"])
        #expect(items.map(\.path) == r.entries)
    }
}

struct SessionStateTests {
    private let split = SessionState.Split(rightIndex: 1, axis: .stacked, leftContent: .scene, rightContent: .plan, focus: .right)

    @Test func roundTrip() throws {
        let url = tempFile()
        let s = SessionState(tabs: ["/a/one.roomsmith", "/b/two.roomsmith", "/c/three.roomsmith"], activeIndex: 2,
                             split: SessionState.Split(rightIndex: 0, axis: .stacked, leftContent: .scene, rightContent: .plan, focus: .right))
        try s.save(to: url)
        #expect(SessionState.load(from: url) == s)
    }

    @Test func missingFileBrokenJSONAndNewerVersionAreEmpty() throws {
        let url = tempFile()
        #expect(SessionState.load(from: url) == .empty)  // no file, no folder
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
        #expect(SessionState.load(from: url) == .empty)
        try Data("{ not json".utf8).write(to: url)
        #expect(SessionState.load(from: url) == .empty)
        try Data(#"{"version":1,"tabs":"nope"}"#.utf8).write(to: url)
        #expect(SessionState.load(from: url) == .empty)
        try Data(#"{"version":2,"tabs":["/a"],"activeIndex":0}"#.utf8).write(to: url)
        #expect(SessionState.load(from: url) == .empty)
    }

    @Test func oneUnknownValueDoesNotDiscardTheWholeSession() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A pane/axis value from another version: the tabs and the split position survive, the unknown field uses its default.
        try Data(#"{"version":1,"tabs":["/a","/b"],"activeIndex":1,"split":{"rightIndex":0,"axis":"diagonal","leftContent":"hologram","rightContent":"scene","focus":"right"}}"#.utf8).write(to: url)
        let s = SessionState.load(from: url)
        #expect(s.tabs == ["/a", "/b"])
        #expect(s.activeIndex == 1)
        let sp = try #require(s.split)
        #expect(sp.rightIndex == 0 && sp.axis == .sideBySide && sp.leftContent == .plan)
        #expect(sp.rightContent == .scene && sp.focus == .right)
        // A broken split or active index costs only itself; a non-string tab entry costs only that tab.
        try Data(#"{"version":1,"tabs":["/a",7,"/b"],"activeIndex":"x","split":{"axis":"stacked"}}"#.utf8).write(to: url)
        let t = SessionState.load(from: url)
        #expect(t.tabs == ["/a", "/b"] && t.activeIndex == 0 && t.split == nil)
    }

    @Test func recentListKeepsValidEntriesWhenOneIsDamaged() throws {
        let url = tempFile("recent.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":1,"entries":["/a/x.roomsmith",{"path":"/b"},42,"/c/y.roomsmith"]}"#.utf8).write(to: url)
        #expect(RecentProjects.load(from: url, fileExists: { _ in true }).entries == ["/a/x.roomsmith", "/c/y.roomsmith"])
    }

    @Test func splitIndexOutOfRangeIsDroppedOnLoad() throws {
        let url = tempFile()
        try SessionState(tabs: ["/a", "/b"], activeIndex: 0, split: .init(rightIndex: 5)).save(to: url)
        let s = SessionState.load(from: url)
        #expect(s.split == nil)
        #expect(s.tabs == ["/a", "/b"])
        try SessionState(tabs: ["/a", "/b"], activeIndex: 0, split: .init(rightIndex: -1)).save(to: url)
        #expect(SessionState.load(from: url).split == nil)
    }

    @Test func splitWithSameTabOnBothSidesIsDropped() {
        #expect(SessionState(tabs: ["/a", "/b"], activeIndex: 1, split: .init(rightIndex: 1)).sanitized().split == nil)
    }

    @Test func activeIndexIsClamped() {
        #expect(SessionState(tabs: ["/a", "/b"], activeIndex: 9).sanitized().activeIndex == 1)
        #expect(SessionState(tabs: ["/a", "/b"], activeIndex: -3).sanitized().activeIndex == 0)
        #expect(SessionState(tabs: [], activeIndex: 4).sanitized().activeIndex == 0)
    }

    @Test func makeLeavesOutUntitledTabsAndMovesIndices() {
        let s = SessionState.make(tabs: [nil, "/a", nil, "/b", "/c"], active: 3, split: .init(rightIndex: 4, axis: .stacked))
        #expect(s.tabs == ["/a", "/b", "/c"])
        #expect(s.activeIndex == 1)
        #expect(s.split == SessionState.Split(rightIndex: 2, axis: .stacked))
    }

    @Test func makeWithUntitledActiveTabPicksNextSavedAndDropsSplit() {
        let s = SessionState.make(tabs: ["/a", nil, "/b"], active: 1, split: split)
        #expect(s.activeIndex == 1)  // "/b"
        #expect(s.split == nil)
        #expect(SessionState.make(tabs: ["/a", "/b", nil], active: 2, split: nil).activeIndex == 1)  // last saved
    }

    @Test func makeDropsSplitToUntitledOrOutOfRangeTab() {
        #expect(SessionState.make(tabs: ["/a", nil], active: 0, split: .init(rightIndex: 1)).split == nil)
        #expect(SessionState.make(tabs: ["/a", "/b"], active: 0, split: .init(rightIndex: 7)).split == nil)
    }

    @Test func makeOfOnlyUntitledTabsIsEmpty() {
        #expect(SessionState.make(tabs: [nil, nil], active: 0, split: nil) == .empty)
        #expect(SessionState.make(tabs: [], active: 0, split: nil).isEmpty)
    }

    @Test func pathIsStandardized() {
        #expect(SessionState.path(for: URL(fileURLWithPath: "/a/b/../c.roomsmith")) == "/a/c.roomsmith")
    }

    @Test func saveOverwritesAtomicallyWithoutLeftovers() throws {
        let url = tempFile()
        try SessionState(tabs: ["/a"], activeIndex: 0).save(to: url)
        try SessionState(tabs: ["/b", "/c"], activeIndex: 1).save(to: url)
        #expect(SessionState.load(from: url).tabs == ["/b", "/c"])
        let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(files == ["session.json"])
    }
}
