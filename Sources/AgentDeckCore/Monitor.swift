import Foundation

public struct ScreenSignal: Equatable, Sendable {
    public var status: AgentStatus
    public var reason: String
    public static func read(_ output: String, kind: AgentKind) -> Self? {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        let tail = lines.suffix(14).joined(separator: "\n")
        // Only inspect the current footer; never search old scrollback for an error or prompt.
        if kind == .codex, tail.contains("queued follow-up inputs"), tail.contains("to answer"),
           tail.range(of: #"(?m)^[\s?│└•]*[1-9][0-9]* questions?\s*$"#, options: .regularExpression) != nil {
            return Self(status: .waiting, reason: "Agent 有问题等待回答 · 屏幕识别")
        }
        let waiting = ["would you like to run the following command", "do you want to proceed?", "do you want to allow", "allow claude to", "permission required", "waiting for your approval", "approve this action", "[y/n]", "[y/n/", "需要你的批准"]
        if waiting.contains(where: tail.contains) { return Self(status: .waiting, reason: "终端出现确认请求 · 屏幕识别") }
        let busy = lines.suffix(10).contains { line in
            (line.contains("esc to interrupt") && !line.hasPrefix("›")) || line.contains("ctrl+c to interrupt") || line.contains("ctrl-c to interrupt") || line.contains("esc to cancel")
        }
        if busy { return Self(status: .working, reason: "Agent 正在处理任务 · 屏幕识别") }
        let ready: Bool
        switch kind {
        case .codex: ready = lines.suffix(7).contains { $0.hasPrefix("›") }
        case .claude: ready = lines.suffix(7).contains { $0 == "❯" || $0.hasPrefix("❯ ") || $0 == ">" } && !tail.contains("…")
        case .hermes: ready = lines.suffix(6).contains { $0.hasPrefix("you ❯") || $0.hasPrefix("you ›") || $0 == "❯" || $0.hasPrefix("hermes ❯") }
        case .custom: ready = false
        }
        if ready { return Self(status: .idle, reason: "Agent 已回到输入提示符 · 屏幕识别") }
        return nil
    }
}

public struct Monitor: Sendable {
    public private(set) var records: [String: AgentRecord] = [:]
    public init() {}
    public mutating func ingest(_ scan: ScanResult, events: [AgentEvent], now: Date = Date()) -> [Activity] {
        var activities = [Activity]()
        let newest = Dictionary(grouping: events, by: \.paneKey).compactMapValues { $0.max { $0.date < $1.date } }
        for pane in scan.panes {
            let existed = records[pane.id] != nil
            var record = records[pane.id] ?? AgentRecord(pane: pane, now: now)
            let previous = record.status
            let changed = pane.captureOK && record.pane.output != pane.output
            record.isPresent = true; record.lastSeen = now
            if changed { record.lastChanged = now }
            let event = [newest[pane.id], pane.sessionEvent].compactMap { $0 }.max { $0.date < $1.date }
            let freshEvent = event.map { candidate in
                candidate.id != record.lastEventID
                    && candidate.date >= (record.lastEvent?.date ?? .distantPast)
                    && candidate.date >= (record.inputSentAt ?? .distantPast)
            } ?? false
            if let event, freshEvent {
                record.lastEvent = event; record.lastEventID = event.id
                record.status = event.status; record.reason = "\(event.summary) · 精确事件"
                record.inputSentAt = nil
                if event.status == .working { record.hasWorked = true }
            }
            // The gateway owns execution state; terminal silence or an older completion
            // must never override a new running/waiting turn.
            if let status = pane.reportedStatus {
                if record.inputSentAt == nil || [.working, .waiting, .failed].contains(status) {
                    record.status = status; record.reason = "Hermes Gateway · \(status.title)"
                    record.inputSentAt = nil
                }
            } else if freshEvent {
                // Already applied the precise terminal hook above.
            } else if pane.dead {
                record.status = pane.exitCode == 0 ? .completed : .failed
                record.reason = "进程已退出，退出码 \(pane.exitCode.map(String.init) ?? "未知")"
            } else if !pane.agentRunning {
                record.status = .offline; record.reason = "Agent 进程已退出；未收到完成信号"
            } else if !pane.captureOK {
                record.reason = "暂时无法读取终端；保留上次状态"
            } else if let signal = ScreenSignal.read(pane.output, kind: pane.kind) {
                if signal.status == .idle {
                    if [.unknown, .idle].contains(record.status) {
                        record.status = .idle; record.reason = signal.reason
                    } else if record.status == .waiting, record.lastEvent?.status != .waiting {
                        record.status = record.hasWorked ? .working : .idle
                        record.reason = "确认提示已消失；等待明确的任务结束信号"
                    }
                } else if signal.status == .waiting {
                    record.status = signal.status; record.reason = signal.reason
                } else if ![.completed, .failed].contains(record.status)
                            || (pane.sessionEvent == nil && changed && ScreenSignal.read(record.pane.output, kind: pane.kind)?.status == .idle) {
                    record.status = signal.status; record.reason = signal.reason
                }
            } else if changed && existed && ![.completed, .failed, .waiting].contains(record.status) {
                record.status = .working; record.reason = "终端正在产生新输出 · 活动检测"
            }
            // A live question takes priority over a simultaneous terminal start
            // event. Gateway status remains authoritative for GUI sessions.
            if pane.reportedStatus == nil, !pane.dead, pane.agentRunning, pane.captureOK,
               let signal = ScreenSignal.read(pane.output, kind: pane.kind), signal.status == .waiting,
               !freshEvent || event?.status == .working {
                record.status = .waiting; record.reason = signal.reason
            }
            if record.status == .working { record.hasWorked = true }
            if previous != record.status { record.statusSince = now }
            record.pane = pane
            records[pane.id] = record
            if !freshEvent && previous != record.status && (existed || record.status == .waiting || record.status == .failed) && [.completed, .waiting, .failed, .idle].contains(record.status) {
                activities.append(Activity(paneKey: pane.id, title: "\(pane.kind.title) · \(pane.project)", status: record.status, summary: record.reason, date: now))
            }
        }
        let current = Set(scan.panes.map(\.id))
        for key in Array(records.keys) where !current.contains(key) {
            guard var record = records[key], record.isPresent, scan.successfulSockets.contains(record.pane.socket) else { continue }
            record.isPresent = false; record.status = .offline; record.statusSince = now
            record.reason = "会话已关闭；未收到完成信号"
            records[key] = record
            activities.append(Activity(paneKey: key, title: "\(record.pane.kind.title) · \(record.pane.project)", status: .offline, summary: record.reason, date: now))
        }
        return activities
    }
    public mutating func forget(_ key: String) { records.removeValue(forKey: key) }
    public mutating func sentInput(_ key: String, now: Date = Date()) {
        guard var record = records[key] else { return }
        record.status = .working; record.reason = "已发送输入，等待 Agent 响应"; record.hasWorked = true; record.lastChanged = now; record.statusSince = now
        record.inputSentAt = now
        records[key] = record
    }
}
