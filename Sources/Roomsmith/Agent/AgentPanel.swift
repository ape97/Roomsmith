import AppKit
import RoomsmithCore
import SwiftUI

/// Agent access switch, connection help and activity log.
struct AgentPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var copiedReset: Task<Void, Never>?

    private var host: AgentHost? { model.agentHost as? AgentHost }

    /// The helper ships in `Roomsmith.app/Contents/Helpers` (`scripts/bundle.sh`); a bare development build has it next
    /// to the app executable.
    private var setupCommand: String {
        let bundle = Bundle.main.bundleURL
        let tool = bundle.pathExtension == "app"
            ? bundle.appendingPathComponent("Contents/Helpers/roomsmith-mcp").path
            : (Bundle.main.executableURL?.deletingLastPathComponent() ?? bundle).appendingPathComponent("roomsmith-mcp").path
        return "claude mcp add roomsmith -- \(shellQuoted(tool))"
    }

    var body: some View {
        @Bindable var store = model.store
        VStack(alignment: .leading, spacing: 14) {
            Text("Agents").font(.title2.bold())

            Toggle(isOn: $store.agentWriteEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow agents to change the project").font(.headline)
                    Text("When off, agents can only look. Every agent change can be undone with Edit > Undo.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.large)
            .accessibilityIdentifier("agentWriteToggle")

            TimelineView(.periodic(from: .now, by: 5)) { context in
                statusLine(now: context.date)
            }

            GroupBox("Connect an agent") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(setupCommand)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        Button(copied ? "Copied" : "Copy setup command") { copySetup() }
                            .accessibilityIdentifier("copySetupCommand")
                        Button("Copy socket path") { copy(host?.socketPath ?? AgentPaths.socketURL.path) }
                        Spacer()
                    }
                    Text("Socket: \(host?.socketPath ?? AgentPaths.socketURL.path)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if host?.isRunning != true {
                        Text("The agent server is not running.").font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(4)
            }

            HStack(alignment: .top, spacing: 12) {
                GroupBox("Clients") { clientList.padding(4) }
                    .frame(width: 200)
                GroupBox("Recent calls") { callList.padding(4) }
            }
            .frame(maxHeight: .infinity)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("agentPanelDone")
            }
        }
        .padding(20)
    }

    // MARK: Parts

    private func statusLine(now: Date) -> some View {
        let connected = host?.isConnected(at: now) ?? false
        let writing = model.store.agentWriteEnabled
        return HStack(spacing: 14) {
            Label(connected ? "Agent connected" : "No agent connected", systemImage: connected ? "circle.fill" : "circle")
                .foregroundStyle(connected ? Color.green : Color.secondary)
            Label(writing ? "Write access on" : "Write access off", systemImage: writing ? "pencil" : "lock")
                .foregroundStyle(writing ? Color.orange : Color.secondary)
            Spacer()
        }
        .font(.callout)
        .accessibilityIdentifier("agentStatusLine")
    }

    @ViewBuilder
    private var clientList: some View {
        let clients = host?.clients ?? []
        if clients.isEmpty {
            Text("No agent has called yet. Copy the setup command above, run it in your agent tool, then restart the agent.").font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            List(clients) { c in
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.id).lineLimit(1)
                    Text("\(c.calls) calls, last \(c.lastSeen.formatted(date: .omitted, time: .standard))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private var callList: some View {
        let calls = host?.recentCalls ?? []
        if calls.isEmpty {
            Text("No calls yet. Ask a connected agent to look at the project; its calls appear here.").font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            List(calls) { c in
                HStack(spacing: 6) {
                    Image(systemName: c.ok ? "checkmark.circle" : "xmark.octagon")
                        .foregroundStyle(c.ok ? Color.green : Color.red)
                    Text(c.tool).font(.system(.caption, design: .monospaced)).lineLimit(1)
                    if let code = c.code { Text(code).font(.caption2).foregroundStyle(.red) }
                    Spacer()
                    Text(c.time.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
        }
    }

    // MARK: Actions

    private func copySetup() {
        copy(setupCommand)
        copied = true
        copiedReset?.cancel()
        copiedReset = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func shellQuoted(_ path: String) -> String {
        path.contains(where: { " '\"\\$`()&;".contains($0) }) ? "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" : path
    }
}
