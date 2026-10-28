import AppKit
import AgentDeckCore

@MainActor
enum TerminalNavigation {
    static func open(_ pane: Pane, using tmux: Tmux) async throws {
        let (clients, processes) = try await Task.detached(priority: .userInitiated) {
            let clients = try tmux.attachedClients(for: pane)
            let result = try Command.run("/bin/ps", ["-axo", "pid=,ppid=,comm="])
            guard result.status == 0 else { throw DeckError.message("无法确认 tmux client 所在的终端。") }
            return (clients, ProcessEntry.parse(result.stdout))
        }.value
        let applications = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        for client in clients {
            // Walk through shells and wrappers; the tmux client's immediate
            // parent is often not the terminal application.
            let ancestors = ProcessEntry.ancestors(of: client.pid, entries: processes)
            guard let app = ancestors.lazy.compactMap({ pid in applications.first { Int($0.processIdentifier) == pid } }).first else { continue }
            let applicationID = app.bundleIdentifier ?? ""
            try await Task.detached(priority: .userInitiated) {
                try tmux.select(pane, in: client)
                _ = try TerminalFocus.focus(tty: client.tty, applicationID: applicationID)
            }.value
            app.activate(options: [])
            return
        }
        // No local GUI terminal is attached to this socket. Do not redirect an
        // unrelated shell or steal a remote/control-mode client.
        try await Task.detached(priority: .userInitiated) {
            try TerminalFocus.openNew(command: tmux.attachCommand(to: pane))
        }.value
    }
}
