import AppKit
import Foundation
import RoomsmithCore

/// Launch hooks: agent server, open-on-launch (tests), autosave.
@MainActor
enum AppLaunch {
    private static var started = false

    static func start(_ workspace: Workspace) {
        guard !started else { return }
        started = true
        let env = ProcessInfo.processInfo.environment
        let model = workspace.active
        // These hooks change view state or load a project, so they only act under ROOMSMITH_TEST_MODE=1.
        let hooks = AppDefaults.isTestMode
        if hooks, let l = env["ROOMSMITH_LAYOUT"].flatMap(ViewLayout.init(rawValue:)) { workspace.prefs.layout = l }
        if hooks, let path = env["ROOMSMITH_OPEN"], !path.isEmpty {
            workspace.open(URL(fileURLWithPath: path))
            // Second project next to the first one, for the compare snapshot check.
            if let second = env["ROOMSMITH_OPEN_COMPARE"], !second.isEmpty {
                let left = workspace.active
                workspace.open(URL(fileURLWithPath: second))
                let right = workspace.active
                if left !== right {
                    workspace.activate(left.id)
                    workspace.startCompare(with: right.id)
                    if env["ROOMSMITH_COMPARE_STACKED"] == "1" { workspace.compare?.axis = .stacked }
                }
            }
        } else if hooks, env["ROOMSMITH_BENCHMARK"] != nil {
            loadBenchmark(model)
        } else {
            // Last session first (tab order), then recovered unsaved changes, which merge into a tab of the same file.
            let session = AppDefaults.persistsSession ? SessionState.load() : .empty
            let opened = workspace.openSessionTabs(session)
            var problems: [String] = []
            workspace.restore(Autosave.offerRecovery(problems: &problems))
            workspace.finishSessionRestore(session, opened: opened)
            if let first = problems.first { workspace.active.lastError = first }
        }
        let host = AgentHost(workspace: workspace)
        do { try host.start() } catch { workspace.active.lastError = "Agent server could not start: \(userMessage(for: error))" }
    }

    /// `ROOMSMITH_BENCHMARK=1` opens the generated stress project (P01); prints the build time.
    static func loadBenchmark(_ model: AppModel) {
        let t0 = Date()
        do {
            let p = try BenchmarkProject.make()
            model.load(p, url: nil)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            model.statusMessage = "Benchmark: \(p.walls.count) walls, \(p.instances.count) furniture, \(p.groups.count) groups (\(ms) ms)"
            // Unbuffered: scripts/benchmark.sh reads this line while the app is still running.
            let line = "ROOMSMITH_BENCHMARK walls=\(p.walls.count) furniture=\(p.instances.count) groups=\(p.groups.count) buildMs=\(ms)\n"
            FileHandle.standardOutput.write(Data(line.utf8))
        } catch {
            model.lastError = "Benchmark project failed: \(userMessage(for: error))"
        }
    }
}
