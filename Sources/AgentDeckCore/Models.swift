import Foundation

public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case codex, claude, hermes, custom
    public var title: String { switch self { case .codex: "Codex"; case .claude: "Claude Code"; case .hermes: "Hermes"; case .custom: "自定义 Agent" } }
    public var executable: String { self == .custom ? "" : rawValue }
    public static func detect(_ command: String) -> Self? {
        // Inspect the executable, or an interpreter's script argument. Do not treat
        // filenames opened by editors or agent names mentioned in prompts as agents.
        let tokens = command.split(whereSeparator: { $0.isWhitespace })
        guard let first = tokens.first else { return nil }
        let executable = URL(fileURLWithPath: String(first)).lastPathComponent.lowercased()
        if first.contains("/Hermes.app/Contents/") { return nil }
        var candidates = [first]
        if ["node", "bun", "deno"].contains(executable) || executable.hasPrefix("python") {
            if let script = tokens.dropFirst().first(where: { !$0.hasPrefix("-") }) { candidates.append(script) }
        }
        for token in candidates {
            let name = URL(fileURLWithPath: String(token)).lastPathComponent.lowercased()
            if name == "codex" || name == "codex.js" { return .codex }
            if name == "claude" || name == "claude.js" { return .claude }
            if name == "hermes" || name == "hermes-agent" || name == "hermes-tui" || (name == "cli.py" && command.contains("hermes-agent/")) || token.contains("/hermes-agent/ui-tui/") { return .hermes }
        }
        return nil
    }
}

public enum AgentStatus: String, Codable, CaseIterable, Sendable {
    case working, waiting, completed, idle, failed, offline, unknown
    public var title: String { switch self {
    case .working: "工作中"; case .waiting: "等待确认"; case .completed: "已完成"
    case .idle: "空闲"; case .failed: "出错了"; case .offline: "已离线"; case .unknown: "状态未知"
    } }
    public var symbol: String { switch self {
    case .working: "waveform.path"; case .waiting: "hand.raised.fill"; case .completed: "checkmark.circle.fill"
    case .idle: "moon.zzz.fill"; case .failed: "exclamationmark.triangle.fill"; case .offline: "power"; case .unknown: "ellipsis.circle"
    } }
    public var needsAttention: Bool { [.waiting, .completed, .failed].contains(self) }
}

public struct Pane: Codable, Identifiable, Equatable, Sendable {
    public var socket: String
    public var serverPID: Int
    public var session: String
    public var window: String
    public var paneID: String
    public var pid: Int
    public var command: String
    public var directory: String
    public var title: String
    public var kind: AgentKind
    public var dead: Bool = false
    public var exitCode: Int? = nil
    public var output: String = ""
    public var captureOK: Bool = true
    public var agentRunning: Bool = true
    public var hermesSession: HermesSessionReference? = nil
    public var contextUsage: ContextUsage? = nil
    public var currentWork: String? = nil
    public var previewOutput: String? = nil
    public var reportedStatus: AgentStatus? = nil
    public var sessionEvent: AgentEvent? = nil
    public var id: String { hermesSession.map { "hermes|\($0.profileID)|\($0.sessionID)" } ?? "\(socket)|\(serverPID)|\(paneID)|\(pid)" }
    public var location: String { hermesSession.map { "Hermes GUI · \($0.profileName)" } ?? "\(session) · \(window) · \(paneID)" }
    public var project: String { directory.isEmpty ? (hermesSession?.profileName ?? session) : URL(fileURLWithPath: directory).lastPathComponent }
    public init(socket: String, serverPID: Int, session: String, window: String, paneID: String, pid: Int, command: String, directory: String, title: String = "", kind: AgentKind, dead: Bool = false, exitCode: Int? = nil, output: String = "", captureOK: Bool = true) {
        self.socket = socket; self.serverPID = serverPID; self.session = session; self.window = window
        self.paneID = paneID; self.pid = pid; self.command = command; self.directory = directory
        self.title = title; self.kind = kind; self.dead = dead; self.exitCode = exitCode; self.output = output; self.captureOK = captureOK
    }
}

public struct ContextUsage: Codable, Equatable, Sendable {
    public var used: Int?
    public var capacity: Int?
    public var percent: Double?
    public var source: String
    public init?(used: Int, capacity: Int, source: String) {
        guard used >= 0, capacity > 0 else { return nil }
        self.used = used; self.capacity = capacity
        percent = min(100, max(0, Double(used) / Double(capacity) * 100)); self.source = source
    }
    public init?(percent: Double, source: String) {
        guard percent.isFinite, (0...100).contains(percent) else { return nil }
        used = nil; capacity = nil; self.percent = percent; self.source = source
    }
    public init?(used: Int, source: String) {
        guard used >= 0 else { return nil }
        self.used = used; capacity = nil; percent = nil; self.source = source
    }
    public var label: String {
        if let percent { return String(format: "%.0f%%", percent) }
        if let used { return used >= 1000 ? String(format: "%.1fk tokens", Double(used) / 1000) : "\(used) tokens" }
        return "—"
    }
}

public struct HermesSessionReference: Codable, Equatable, Sendable {
    public var controlHome: String
    public var profileID: String
    public var sessionID: String
    public var profileName: String { URL(fileURLWithPath: profileID).lastPathComponent == ".hermes" ? "default" : URL(fileURLWithPath: profileID).lastPathComponent }
    public init(controlHome: String, profileID: String, sessionID: String) { self.controlHome = controlHome; self.profileID = profileID; self.sessionID = sessionID }
}

public struct AgentEvent: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var paneKey: String
    public var date: Date
    public var status: AgentStatus
    public var summary: String
    public var source: String
    public init(id: String = UUID().uuidString, paneKey: String, date: Date = Date(), status: AgentStatus, summary: String, source: String = "hook") {
        self.id = id; self.paneKey = paneKey; self.date = date; self.status = status; self.summary = summary; self.source = source
    }
}

public struct AgentRecord: Identifiable, Sendable {
    public var pane: Pane
    public var status: AgentStatus = .unknown
    public var reason: String = "正在读取终端状态"
    public var lastChanged: Date
    public var lastSeen: Date
    public var statusSince: Date
    public var lastEvent: AgentEvent?
    public var lastEventID: String?
    public var inputSentAt: Date?
    public var hasWorked = false
    public var isPresent = true
    public var id: String { pane.id }
    public init(pane: Pane, now: Date) { self.pane = pane; lastChanged = now; lastSeen = now; statusSince = now }
}

public struct Activity: Codable, Identifiable, Sendable {
    public var id: String
    public var paneKey: String
    public var title: String
    public var status: AgentStatus
    public var summary: String
    public var date: Date
    public var read: Bool
    public init(id: String = UUID().uuidString, paneKey: String, title: String, status: AgentStatus, summary: String, date: Date = Date(), read: Bool = false) {
        self.id = id; self.paneKey = paneKey; self.title = title; self.status = status; self.summary = summary; self.date = date; self.read = read
    }
}
