import Foundation
import Darwin

extension ProcessEntry {
    static func interactiveAgent(root: Int, kind: AgentKind, entries: [Self]) -> Self? {
        if kind == .custom { return entries.first { $0.pid == root } }
        var pending = [root], seen = Set<Int>(), candidates = [Self]()
        while let pid = pending.popLast() {
            guard seen.insert(pid).inserted, let entry = entries.first(where: { $0.pid == pid }) else { continue }
            let children = entries.filter { $0.parent == pid }
            if let detected = AgentKind.detect(entry.command) {
                guard detected == kind else { continue }
                let tokens = entry.command.split(whereSeparator: { $0.isWhitespace })
                if kind == .codex, tokens.contains("app-server") { continue }
                let executable = tokens.first.map { URL(fileURLWithPath: String($0)).lastPathComponent } ?? ""
                let native = children.filter { AgentKind.detect($0.command) == kind }
                if ["node", "bun", "deno"].contains(executable), !native.isEmpty {
                    pending += native.map(\.pid)
                } else { candidates.append(entry) }
                continue // Never target an agent's tools or shared background services.
            }
            pending += children.map(\.pid)
        }
        return candidates.count == 1 ? candidates.first : nil
    }
}

extension Tmux {
    static func processStart(_ pid: Int) -> String? {
        guard pid > 1, pid <= Int(Int32.max),
              let result = try? Command.run("/bin/ps", ["-p", String(pid), "-o", "lstart="], timeout: 2, environment: ["TZ": "UTC", "LC_ALL": "C"]), result.status == 0 else { return nil }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    public func attachCommand(to pane: Pane) throws -> String {
        let identity = try call(["display-message", "-p", "-t", pane.paneID, "#{pid}|#{pane_pid}|#{session_id}"], socket: pane.socket)
            .trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|")
        guard identity.count == 3, identity[0] == String(pane.serverPID), identity[1] == String(pane.pid),
              identity[2].hasPrefix("$"), Int(identity[2].dropFirst()) != nil else { throw DeckError.message("这个 pane 已被替换，请刷新后重试。") }
        // switch-client accepts a pane target and selects its session, window AND
        // pane. Use the session ID so renamed/prefix-matching names cannot misroute.
        return ["/usr/bin/env", "-u", "TMUX", "-u", "TMUX_PANE", executable, "-S", pane.socket,
                "attach-session", "-t", identity[2], ";", "switch-client", "-t", pane.paneID]
            .map(Command.quote).joined(separator: " ")
    }

    public func exitAgent(_ pane: Pane) throws {
        try validate(pane)
        let dead = try call(["display-message", "-p", "-t", pane.paneID, "#{pane_dead}"], socket: pane.socket).trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        if dead { try restoreShell(in: pane); return }
        guard let pid = pane.agentPID, let started = pane.agentStartedAt, Self.processStart(pid) == started else {
            throw DeckError.message("Agent 进程已变化，未执行退出；请刷新后重试。")
        }
        let ps = try Command.run("/bin/ps", ["-axo", "pid=,ppid=,command="])
        let entries = ProcessEntry.parse(ps.stdout)
        guard ps.status == 0, ProcessEntry.interactiveAgent(root: pane.pid, kind: pane.kind, entries: entries)?.pid == pid else {
            throw DeckError.message("无法确认这个 pane 的 Agent，未执行退出。")
        }
        let rootIsAgent = pane.kind == .custom || entries.first(where: { $0.pid == pane.pid }).flatMap { AgentKind.detect($0.command) } == pane.kind
        let originalRemain = try call(["show-options", "-p", "-qv", "-t", pane.paneID, "remain-on-exit"], socket: pane.socket).trimmingCharacters(in: .whitespacesAndNewlines)
        if rootIsAgent { _ = try call(["set-option", "-p", "-t", pane.paneID, "remain-on-exit", "on"], socket: pane.socket) }
        var expectedPane = pane
        defer {
            if rootIsAgent, (try? validate(expectedPane)) != nil {
                let args = originalRemain.isEmpty ? ["set-option", "-pu", "-t", pane.paneID, "remain-on-exit"]
                    : ["set-option", "-p", "-t", pane.paneID, "remain-on-exit", originalRemain]
                _ = try? call(args, socket: pane.socket)
            }
        }
        try validate(pane, requireAgent: true)
        // Ask the TUI to cancel its current turn before exiting its own process.
        // Never signal a process group: Codex can share its daemon across panes.
        _ = try call(["send-keys", "-t", pane.paneID, "C-c"], socket: pane.socket)
        Thread.sleep(forTimeInterval: 0.3)
        if Self.processStart(pid) == started {
            try validate(pane, requireAgent: true)
            guard Self.processStart(pid) == started else { throw DeckError.message("Agent 进程已变化，未发送退出信号。") }
            if Darwin.kill(pid_t(pid), SIGTERM) != 0, errno != ESRCH { throw DeckError.message("无法退出 Agent：\(String(cString: strerror(errno)))") }
        }
        for _ in 0..<40 {
            if Self.processStart(pid) != started { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard Self.processStart(pid) != started else { throw DeckError.message("已请求退出，但 Agent 尚未结束。请在 tmux 中检查。") }
        // A CLI started with exec (including our launcher) owns the pane's root
        // process. Keep that pane and replace the exited process with a shell.
        if rootIsAgent {
            for _ in 0..<40 {
                let value = try call(["display-message", "-p", "-t", pane.paneID, "#{pane_dead}"], socket: pane.socket)
                if value.trimmingCharacters(in: .whitespacesAndNewlines) == "1" { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            expectedPane = try restoreShell(in: pane)
        } else {
            try validate(pane)
            try clearAgentMarkers(pane)
        }
    }

    @discardableResult
    private func restoreShell(in pane: Pane) throws -> Pane {
        try validate(pane)
        let dead = try call(["display-message", "-p", "-t", pane.paneID, "#{pane_dead}"], socket: pane.socket)
        guard dead.trimmingCharacters(in: .whitespacesAndNewlines) == "1" else { throw DeckError.message("Agent 的启动进程尚未退出，未替换 pane。") }
        let shell = try call(["show-options", "-gv", "default-shell"], socket: pane.socket).trimmingCharacters(in: .whitespacesAndNewlines)
        guard shell.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: shell) else { throw DeckError.message("tmux 默认 shell 无效。") }
        // No -k: never replace a process that became live while we were checking.
        _ = try call(["respawn-pane", "-t", pane.paneID, "-c", pane.directory, shell, "-l"], socket: pane.socket)
        var restored = pane
        let pid = try call(["display-message", "-p", "-t", pane.paneID, "#{pane_pid}"], socket: pane.socket).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(pid) else { throw DeckError.message("无法确认恢复后的 shell。") }
        restored.pid = value
        try clearAgentMarkers(restored)
        return restored
    }
    private func clearAgentMarkers(_ pane: Pane) throws {
        try validate(pane)
        for option in ["@agentdeck_kind", "@agentdeck_title"] { _ = try call(["set-option", "-pu", "-t", pane.paneID, option], socket: pane.socket) }
    }
}
