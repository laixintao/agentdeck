import Foundation

/// Read only data attributable to the exact process/session, never guess by shared cwd.
public enum LocalSessionTelemetry {
    public static func enrich(_ pane: inout Pane, processes: [ProcessEntry], home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let children = ProcessEntry.descendants(root: pane.pid, entries: processes)
        let agents = children.filter { AgentKind.detect($0.command) == pane.kind }
        guard !agents.isEmpty else { return }
        if pane.kind == .codex {
            let pids = agents.map { String($0.pid) }.joined(separator: ",")
            guard let result = try? Command.run("/usr/sbin/lsof", ["-a", "-p", pids, "-Fn"], timeout: 2), result.status == 0 else { return }
            let paths = Set(result.stdout.split(separator: "\n").compactMap { line -> String? in
                guard line.hasPrefix("n/") else { return nil }
                let path = String(line.dropFirst()), url = URL(fileURLWithPath: path)
                return url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" ? path : nil
            })
            // A shared server can own many sessions. Ambiguous attribution is not telemetry.
            guard paths.count == 1, let path = paths.first, let rows = tail(URL(fileURLWithPath: path)) else { return }
            if let usage = codexContext(rows) { pane.contextUsage = usage }
            pane.sessionEvent = codexEvent(rows, paneKey: pane.id)
        } else if pane.kind == .claude {
            let root = home.appendingPathComponent(".claude")
            for agent in agents {
                guard let session = object(root.appendingPathComponent("sessions/\(agent.pid).json")),
                      session["pid"] as? Int == agent.pid, let sid = session["sessionId"] as? String, UUID(uuidString: sid) != nil,
                      let cwd = session["cwd"] as? String, let start = session["procStart"] as? String,
                      let actual = try? Command.run("/bin/ps", ["-p", String(agent.pid), "-o", "lstart="], timeout: 2, environment: ["TZ": "UTC", "LC_ALL": "C"]),
                      actual.status == 0, actual.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == start else { continue }
                // Claude encodes non-alphanumeric path characters as hyphens.
                let key = cwd.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "-", options: .regularExpression)
                let path = root.appendingPathComponent("projects/\(key)/\(sid).jsonl")
                guard let rows = tail(path) else { continue }
                let matching = rows.filter { ($0["sessionId"] as? String) == sid && ($0["isSidechain"] as? Bool) != true }
                pane.sessionEvent = claudeEvent(matching, paneKey: pane.id)
                let assistant = matching.reversed().first { $0["type"] as? String == "assistant" && ($0["message"] as? [String: Any])?["usage"] is [String: Any] }
                if let message = assistant?["message"] as? [String: Any], let model = message["model"] as? String {
                    var capacity = claudeCapacity(model: model, root: root)
                    // Honor the live process's explicit context override without logging its environment.
                    if let environment = try? Command.run("/bin/ps", ["eww", "-p", String(agent.pid), "-o", "command="], timeout: 2) {
                        if let override = environmentValue("CLAUDE_CODE_MAX_CONTEXT_TOKENS", in: environment.stdout).flatMap(Int.init), override > 0 { capacity = capacity.map { min($0, override) } ?? override }
                        if environmentValue("CLAUDE_CODE_DISABLE_1M_CONTEXT", in: environment.stdout) == "1", (capacity ?? 0) > 200000 { capacity = nil }
                    }
                    if let usage = claudeContext(message: message, capacity: capacity) { pane.contextUsage = usage }
                }
                let output = claudeOutput(matching)
                if !output.isEmpty { pane.previewOutput = output }
                if pane.title.isEmpty, let name = session["name"] as? String, !name.isEmpty { pane.title = name }
                break
            }
        }
    }
    public static func codexEvent(_ rows: [[String: Any]], paneKey: String) -> AgentEvent? {
        for row in rows.reversed() {
            guard row["type"] as? String == "event_msg", let payload = row["payload"] as? [String: Any], let type = payload["type"] as? String else { continue }
            let states: [String: AgentStatus] = ["task_started": .working, "task_complete": .completed, "turn_aborted": .failed]
            guard let status = states[type] else { continue }
            return lifecycleEvent(row, status: status, paneKey: paneKey, source: "codex-session", identity: (payload["turn_id"] as? String ?? "") + ":" + type)
        }
        return nil
    }
    public static func claudeEvent(_ rows: [[String: Any]], paneKey: String) -> AgentEvent? {
        for row in rows.reversed() where row["isSidechain"] as? Bool != true && row["isMeta"] as? Bool != true {
            // Claude can compact an already finished turn while idle. Its summary
            // is stored as a user message, but must not start another turn.
            guard row["isCompactSummary"] as? Bool != true,
                  row["isVisibleInTranscriptOnly"] as? Bool != true else { continue }
            let type = row["type"] as? String
            let status: AgentStatus
            if type == "system", row["subtype"] as? String == "turn_duration" { status = .completed }
            else if type == "user" || type == "assistant" { status = .working }
            else { continue }
            // An assistant end_turn can still be followed by a Stop hook or more
            // work. Only the CLI's final turn_duration record closes the turn.
            return lifecycleEvent(row, status: status, paneKey: paneKey, source: "claude-session", identity: row["uuid"] as? String ?? type ?? "")
        }
        return nil
    }
    private static func lifecycleEvent(_ row: [String: Any], status: AgentStatus, paneKey: String, source: String, identity: String) -> AgentEvent? {
        guard let timestamp = row["timestamp"] as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = formatter.date(from: timestamp)
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = fractional ?? formatter.date(from: timestamp) else { return nil }
        return AgentEvent(id: "\(source)|\(paneKey)|\(identity)|\(timestamp)", paneKey: paneKey, date: date, status: status, summary: "会话报告：\(status.title)", source: source)
    }
    public static func codexContext(_ rows: [[String: Any]]) -> ContextUsage? {
        for row in rows.reversed() {
            guard row["type"] as? String == "event_msg", let payload = row["payload"] as? [String: Any], payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any], let last = info["last_token_usage"] as? [String: Any],
                  let used = last["total_tokens"] as? Int, let capacity = info["model_context_window"] as? Int else { continue }
            return ContextUsage(used: used, capacity: capacity, source: "Codex 当前进程的会话日志 · 最近一次请求")
        }
        return nil
    }
    public static func claudeContext(message: [String: Any], capacity: Int?) -> ContextUsage? {
        guard let usage = message["usage"] as? [String: Any], let input = usage["input_tokens"] as? Int else { return nil }
        let used = input + (usage["cache_read_input_tokens"] as? Int ?? 0) + (usage["cache_creation_input_tokens"] as? Int ?? 0)
        if let capacity { return ContextUsage(used: used, capacity: capacity, source: "Claude 会话最近一次输入（含缓存） / 本机模型目录上限") }
        return ContextUsage(used: used, source: "Claude 会话最近一次输入（含缓存）；上限尚未提供")
    }
    public static func claudeOutput(_ rows: [[String: Any]]) -> String {
        var lines = [String]()
        for row in rows.suffix(60) where row["type"] as? String == "assistant" {
            guard let message = row["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] else { continue }
            for block in content {
                if block["type"] as? String == "text", let text = block["text"] as? String { lines.append(text) }
                if block["type"] as? String == "tool_use", let name = block["name"] as? String {
                    let input = block["input"] as? [String: Any] ?? [:]
                    let detail = input["command"] as? String ?? input["file_path"] as? String ?? input["pattern"] as? String ?? ""
                    lines.append("→ " + name + (detail.isEmpty ? "" : " · " + String(detail.prefix(240))))
                }
            }
        }
        return String(lines.suffix(10).joined(separator: "\n\n").suffix(6000))
    }
    static func claudeCapacity(model: String, root: URL) -> Int? {
        let folder = root.appendingPathComponent("cache/model-catalog")
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent.hasSuffix("-cc.json") }
        var capacities = Set<Int>()
        for file in files {
            guard let object = object(file), let catalog = object["catalog"] as? [String: Any],
                  let state = catalog["state"] as? [String: Any], state["model"] as? String == model,
                  let config = catalog["config"] as? [String: Any], let models = config["models"] as? [[String: Any]] else { continue }
            for row in models where row["id"] as? String == model {
                if let runtime = row["runtime"] as? [String: Any], let maximum = runtime["max_input_tokens"] as? Int, maximum > 0 { capacities.insert(maximum) }
            }
        }
        return capacities.count == 1 ? capacities.first : nil
    }
    static func tail(_ url: URL) -> [[String: Any]]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > 2_000_000 ? size - 2_000_000 : 0
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd() else { return nil }
        return data.split(separator: 10).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
    }
    private static func object(_ url: URL) -> [String: Any]? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 4_000_000, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    private static func environmentValue(_ key: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "(?:^|\\s)" + NSRegularExpression.escapedPattern(for: key) + "=([^\\s]+)"),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
