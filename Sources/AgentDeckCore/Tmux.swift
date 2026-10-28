import Foundation
import Darwin

public struct ScanResult: Sendable {
    public var panes: [Pane]
    public var errors: [String]
    public var successfulSockets: Set<String>
    public var socketCount: Int
}

public struct ProcessEntry: Sendable {
    public var pid: Int
    public var parent: Int
    public var command: String
    public static func parse(_ text: String) -> [Self] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
            guard parts.count == 3, let pid = Int(parts[0]), let parent = Int(parts[1]) else { return nil }
            return Self(pid: pid, parent: parent, command: String(parts[2]))
        }
    }
    public static func agent(root: Int, entries: [Self]) -> AgentKind? {
        var pending = [root], seen = Set<Int>()
        for _ in 0..<12 {
            if pending.isEmpty { break }
            var next = [Int]()
            for pid in pending where seen.insert(pid).inserted {
                if let entry = entries.first(where: { $0.pid == pid }), let kind = AgentKind.detect(entry.command) { return kind }
                next += entries.filter { $0.parent == pid }.map(\.pid)
            }
            pending = next
        }
        return nil
    }
    public static func descendants(root: Int, entries: [Self]) -> [Self] {
        var ids: Set<Int> = [root]
        for _ in 0..<12 {
            let next = ids.union(entries.filter { ids.contains($0.parent) }.map(\.pid))
            if next == ids { break }; ids = next
        }
        return entries.filter { ids.contains($0.pid) }
    }
}

public struct Tmux: Sendable {
    public var executable: String
    public init(executable: String? = nil) { self.executable = executable ?? Command.find("tmux") ?? "/opt/homebrew/bin/tmux" }
    public static let separator = "\u{1f}"
    public static let format = ["#{pid}", "#{session_name}", "#{window_index}", "#{pane_id}", "#{pane_pid}", "#{pane_current_command}", "#{pane_current_path}", "#{@agentdeck_title}", "#{@agentdeck_kind}", "#{pane_dead}", "#{pane_dead_status}"].joined(separator: separator)

    public static func canonicalSocket(_ path: String) -> String {
        if let resolved = realpath(path, nil) { defer { free(resolved) }; return String(cString: resolved) }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if let parent = realpath(url.deletingLastPathComponent().path, nil) {
            defer { free(parent) }; return String(cString: parent) + "/" + url.lastPathComponent
        }
        return url.standardizedFileURL.path
    }

    public static func sockets(extra: [String] = []) -> [String] {
        let fm = FileManager.default
        var paths = Set(extra.filter { !$0.isEmpty }.map(canonicalSocket))
        let bases = Set(["/private/tmp", "/tmp", ProcessInfo.processInfo.environment["TMUX_TMPDIR"] ?? "/tmp"])
        for base in bases {
            let directory = URL(fileURLWithPath: base).appendingPathComponent("tmux-\(getuid())").resolvingSymlinksInPath()
            for url in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                if let attrs = try? fm.attributesOfItem(atPath: url.path), attrs[.type] as? FileAttributeType == .typeSocket { paths.insert(canonicalSocket(url.path)) }
            }
        }
        if let env = ProcessInfo.processInfo.environment["TMUX"], let socket = socketFromEnvironment(env) { paths.insert(canonicalSocket(socket)) }
        return paths.sorted()
    }
    public static func socketFromEnvironment(_ value: String) -> String? {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        return parts.dropLast(2).joined(separator: ",")
    }
    public func call(_ args: [String], socket: String, timeout: TimeInterval = 5, input: Data? = nil) throws -> String {
        let result = try Command.run(executable, ["-S", socket] + args, timeout: timeout, input: input)
        guard result.status == 0 else { throw DeckError.message(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return result.stdout
    }
    public static func parse(_ line: String, socket: String, processes: [ProcessEntry], tracked: [String: AgentKind]) -> Pane? {
        let socket = canonicalSocket(socket)
        let p = line.components(separatedBy: separator)
        guard p.count == 11, let server = Int(p[0]), let pid = Int(p[4]), p[3].hasPrefix("%") else { return nil }
        let key = "\(socket)|\(server)|\(p[3])|\(pid)"
        let detected = AgentKind.detect(p[5]) ?? ProcessEntry.agent(root: pid, entries: processes)
        let marked = AgentKind(rawValue: p[8])
        guard let kind = marked ?? detected ?? tracked[key] else { return nil }
        var pane = Pane(socket: socket, serverPID: server, session: p[1], window: p[2], paneID: p[3], pid: pid, command: p[5], directory: p[6], title: p[7], kind: kind, dead: p[9] == "1", exitCode: Int(p[10]))
        pane.agentRunning = detected != nil || marked != nil
        return pane
    }
    public func scan(extraSockets: [String] = [], tracked: [String: AgentKind] = [:], onlySockets: [String]? = nil, captureOutput: Bool = true) -> ScanResult {
        var result = ScanResult(panes: [], errors: [], successfulSockets: [], socketCount: 0)
        guard FileManager.default.isExecutableFile(atPath: executable) else { result.errors = ["找不到 tmux。请安装：brew install tmux，或在设置中指定路径。"]; return result }
        var processes = [ProcessEntry]()
        do {
            let ps = try Command.run("/bin/ps", ["-axo", "pid=,ppid=,command="])
            if ps.status == 0 { processes = ProcessEntry.parse(ps.stdout) } else { result.errors.append("进程树读取失败：\(ps.stderr)") }
        } catch { result.errors.append(error.localizedDescription) }
        let sockets = onlySockets?.map(Self.canonicalSocket) ?? Self.sockets(extra: extraSockets)
        result.socketCount = sockets.count
        for socket in sockets {
            do {
                let text = try call(["list-panes", "-a", "-F", Self.format], socket: socket)
                result.successfulSockets.insert(socket)
                for line in text.components(separatedBy: "\n") {
                    guard var pane = Self.parse(line, socket: socket, processes: processes, tracked: tracked) else { continue }
                    if captureOutput {
                        do { pane.output = try call(["capture-pane", "-p", "-J", "-t", pane.paneID, "-S", "-120"], socket: socket) }
                        catch { pane.captureOK = false; result.errors.append("\(pane.location)：\(error.localizedDescription)") }
                        pane.contextUsage = TerminalTelemetry.context(pane.output)
                        pane.currentWork = TerminalTelemetry.work(pane.output, kind: pane.kind)
                        LocalSessionTelemetry.enrich(&pane, processes: processes)
                    }
                    result.panes.append(pane)
                }
            } catch {
                let message = error.localizedDescription
                if message.contains("no server running") || message.contains("No such file") || message.contains("Connection refused") { result.successfulSockets.insert(socket) }
                else { result.errors.append("\(URL(fileURLWithPath: socket).lastPathComponent)：\(message)") }
            }
        }
        // A deleted socket is authoritative evidence that that server is gone.
        for key in tracked.keys {
            if let socket = key.components(separatedBy: "|").first, !FileManager.default.fileExists(atPath: socket) { result.successfulSockets.insert(socket) }
        }
        return result
    }
    public func validate(_ pane: Pane, requireAgent: Bool = false) throws {
        let value = try call(["display-message", "-p", "-t", pane.paneID, "#{pid}|#{pane_pid}|#{pane_dead}|#{pane_current_command}"], socket: pane.socket).trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|")
        guard value.count == 4, value[0] == String(pane.serverPID), value[1] == String(pane.pid) else { throw DeckError.message("这个 pane 已被替换，请刷新后重试。") }
        if requireAgent {
            guard value[2] != "1", pane.agentRunning else { throw DeckError.message("Agent 已退出，未发送输入。") }
            if pane.kind != .custom, AgentKind.detect(value[3]) == nil {
                let ps = try Command.run("/bin/ps", ["-axo", "pid=,ppid=,command="])
                guard ps.status == 0, ProcessEntry.agent(root: pane.pid, entries: ProcessEntry.parse(ps.stdout)) != nil else { throw DeckError.message("Agent 已退出或无法确认进程，未向 shell 发送输入。") }
            }
        }
    }
    public func send(_ text: String, to pane: Pane) throws {
        guard !text.isEmpty, !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw DeckError.message("请发送单行文本；多行代码请在终端粘贴。") }
        try validate(pane, requireAgent: true)
        // Explicit paste boundaries keep prompt text out of typing shortcuts and
        // paste-burst heuristics. Use a private buffer without changing the clipboard.
        let buffer = "agentdeck-" + UUID().uuidString
        _ = try call(["load-buffer", "-b", buffer, "-"], socket: pane.socket, input: Data(text.utf8))
        defer { _ = try? call(["delete-buffer", "-b", buffer], socket: pane.socket) }
        try validate(pane, requireAgent: true)
        _ = try call(["paste-buffer", "-p", "-d", "-b", buffer, "-t", pane.paneID], socket: pane.socket)
        // Codex and other TUIs suppress submission briefly after rapid text input.
        // Submit as a separate key after that window, never as part of the paste.
        Thread.sleep(forTimeInterval: 0.25)
        try validate(pane, requireAgent: true)
        _ = try call(["send-keys", "-t", pane.paneID, "Enter"], socket: pane.socket)
    }
    public func interrupt(_ pane: Pane) throws { try validate(pane, requireAgent: true); _ = try call(["send-keys", "-t", pane.paneID, "C-c"], socket: pane.socket) }
}
