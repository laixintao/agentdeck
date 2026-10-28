import Foundation
import Darwin

// Same-user Unix control socket -> short-lived session ticket -> loopback JSON-RPC.
// Never starts/restarts Hermes, reads provider credentials, or changes its settings.
public enum HermesControl {
    public static func request(home: String, verb: String, params: [String: Any] = [:]) throws -> [String: Any] {
        let root = URL(fileURLWithPath: (home as NSString).expandingTildeInPath)
        var path = root.appendingPathComponent("gateway.sock").path
        if !FileManager.default.fileExists(atPath: path) {
            let pointer = root.appendingPathComponent("gateway.sock.path")
            try validateOwner(pointer.path, socket: false)
            let data = try Data(contentsOf: pointer)
            guard data.count < 4096, let target = String(data: data, encoding: .utf8), target.hasPrefix("/") else { throw DeckError.message("Hermes socket 路径无效") }
            path = target.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try validateOwner(path, socket: true)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DeckError.message("无法连接 Hermes 本地服务") }
        defer { Darwin.close(fd) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0), noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw DeckError.message("Hermes socket 路径过长") }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in buffer.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard connected == 0 else { throw DeckError.message("Hermes 服务连接失败（\(errno)）") }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw DeckError.message("Hermes 服务不属于当前用户") }
        var data = try JSONSerialization.data(withJSONObject: ["protocol": 1, "id": 1, "verb": verb, "params": params]); data.append(10)
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.send(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                guard count > 0 else { throw DeckError.message("Hermes 控制请求发送失败") }; offset += count
            }
        }
        var reply = Data(), chunk = [UInt8](repeating: 0, count: 4096)
        while !reply.contains(10) && reply.count <= 524288 {
            let count = Darwin.recv(fd, &chunk, chunk.count, 0)
            guard count > 0 else { throw DeckError.message("Hermes 控制服务未响应") }
            reply.append(contentsOf: chunk.prefix(count))
        }
        guard reply.count <= 524288, let line = reply.split(separator: 10).first,
              let envelope = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              envelope["ok"] as? Bool == true, envelope["protocol"] as? Int == 1,
              let result = envelope["result"] as? [String: Any] else { throw DeckError.message("Hermes 控制协议不兼容") }
        return result
    }
    private static func validateOwner(_ path: String, socket: Bool) throws {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_mode & S_IFMT == (socket ? S_IFSOCK : S_IFREG) else { throw DeckError.message("Hermes 本地 socket 未就绪或权限不安全") }
    }
    public static func websocketURL(_ origin: String) -> URL? {
        guard var url = URLComponents(string: origin), url.scheme == "http", ["127.0.0.1", "::1", "[::1]"].contains(url.host ?? ""), url.port != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.path.isEmpty else { return nil }
        url.scheme = "ws"; url.path = "/api/ws"; return url.url
    }
}

private final class HermesRPC {
    let session: URLSession
    let task: URLSessionWebSocketTask
    private var sequence = 0
    init(home: String, profileID: String, identify: [String: Any]) throws {
        guard let origin = identify["api_origin"] as? String, let url = HermesControl.websocketURL(origin),
              let instance = identify["instance_id"] as? String,
              (identify["capabilities"] as? [String])?.contains("session-authority-v1") == true else { throw DeckError.message("Hermes 未提供本机会话接口") }
        let grant = try HermesControl.request(home: home, verb: "session-ticket", params: ["profile_id": profileID, "instance_id": instance, "purpose": "interactive"])
        guard grant["profile_id"] as? String == profileID, grant["instance_id"] as? String == instance, let ticket = grant["ticket"] as? String else { throw DeckError.message("Hermes 会话认证失败") }
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 5; config.timeoutIntervalForResource = 8
        config.connectionProxyDictionary = [:]
        session = URLSession(configuration: config)
        task = session.webSocketTask(with: url, protocols: ["hermes-gateway-v1", "hermes-gateway-ticket." + ticket])
        task.maximumMessageSize = 8 * 1024 * 1024; task.resume()
    }
    func close() { task.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
    func call(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        sequence += 1; let id = sequence
        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        return try await withThrowingTaskGroup(of: [String: Any].self) { group in
            group.addTask { [task] in
                try await task.send(.string(String(decoding: data, as: UTF8.self)))
                while true {
                    let message = try await task.receive()
                    let bytes: Data
                    switch message { case .data(let value): bytes = value; case .string(let value): bytes = Data(value.utf8); @unknown default: continue }
                    guard let frame = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], frame["id"] as? Int == id else { continue }
                    if let error = frame["error"] as? [String: Any] { throw DeckError.message("Hermes \(method)：\(error["message"] as? String ?? "请求失败")") }
                    return frame["result"] as? [String: Any] ?? [:]
                }
            }
            group.addTask { [task] in
                try await Task.sleep(for: .seconds(6))
                task.cancel(with: .goingAway, reason: nil)
                throw DeckError.message("Hermes \(method) 请求超时")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

public struct HermesGatewayScan: Sendable {
    public var panes: [Pane] = []
    public var events: [AgentEvent] = []
    public var successfulSources: Set<String> = []
    public var errors: [String] = []
}

public actor HermesGateway {
    private struct Cursor { var epoch: String; var sequence: Int; var output: String = ""; var work: String = ""; var status: AgentStatus?; var context: ContextUsage? }
    private var cursors: [String: Cursor] = [:]
    private var knownSources: Set<String> = []
    public init() {}
    public func scan(home: String) async -> HermesGatewayScan {
        var result = HermesGatewayScan()
        let expanded = (home as NSString).expandingTildeInPath
        let exists = ["gateway.sock", "gateway.sock.path"].contains { FileManager.default.fileExists(atPath: expanded + "/" + $0) }
        guard exists else { result.successfulSources = knownSources; return result }
        do {
            let identity = try HermesControl.request(home: expanded, verb: "identify")
            guard ["ready", "draining"].contains(identity["state"] as? String ?? "") else { throw DeckError.message("Hermes Gateway 正在启动或停止") }
            let profiles = identity["served_profiles"] as? [[String: Any]] ?? []
            let currentSources = Set(profiles.compactMap { ($0["profile_id"] as? String).map { "hermes:" + $0 } })
            result.successfulSources.formUnion(knownSources.subtracting(currentSources))
            for profile in profiles {
                guard let profileID = profile["profile_id"] as? String else { continue }
                let source = "hermes:" + profileID; knownSources.insert(source)
                do {
                    let rpc = try HermesRPC(home: expanded, profileID: profileID, identify: identity); defer { rpc.close() }
                    let response = try await rpc.call("session.active_list")
                    for row in response["sessions"] as? [[String: Any]] ?? [] {
                        // Tmux CLI sessions are already represented by the terminal adapter.
                        guard let sessionID = row["id"] as? String, ["desktop", "gui", "web", "tui"].contains(row["source"] as? String ?? "") else { continue }
                        // Desktop can retain empty tabs as active sessions. Only hide an
                        // explicitly empty, idle session; a starting task may have no messages yet.
                        if row["message_count"] as? Int == 0, row["status"] as? String == "idle" { continue }
                        let reference = HermesSessionReference(controlHome: expanded, profileID: profileID, sessionID: sessionID)
                        var pane = Pane(socket: source, serverPID: 0, session: reference.profileName, window: "GUI", paneID: sessionID, pid: 0, command: "Hermes GUI", directory: "", title: row["title"] as? String ?? "Hermes", kind: .hermes)
                        if pane.title.isEmpty { pane.title = "新会话 · " + String(sessionID.suffix(6)) }
                        pane.hermesSession = reference
                        pane.reportedStatus = Self.status(row["status"] as? String ?? "")
                        let stats = try await rpc.call("session.stats", ["session_id": sessionID])
                        pane.contextUsage = Self.context(stats)
                        var cursor = cursors[pane.id]
                        var params: [String: Any] = ["session_id": sessionID, "last_sequence": cursor?.sequence ?? 0]
                        if let cursor { params["replay_epoch"] = cursor.epoch }
                        var replay = try await rpc.call("session.events.since", params)
                        var initial = cursor == nil
                        if replay["snapshot_required"] as? Bool == true, let epoch = replay["replay_epoch"] as? String {
                            // A changed epoch or replay gap is a new baseline, not a batch
                            // of newly completed turns. Do not notify historical events.
                            initial = true
                            let latest = replay["last_sequence"] as? Int ?? 0
                            cursor = Cursor(epoch: epoch, sequence: max(0, latest - 60))
                            replay = try await rpc.call("session.events.since", ["session_id": sessionID, "replay_epoch": epoch, "last_sequence": max(0, latest - 60)])
                        }
                        if cursor == nil { cursor = Cursor(epoch: replay["replay_epoch"] as? String ?? "", sequence: 0) }
                        for frame in replay["events"] as? [[String: Any]] ?? [] {
                            let event = frame["params"] as? [String: Any] ?? frame
                            let type = event["type"] as? String ?? "", payload = event["payload"] as? [String: Any] ?? [:]
                            if let work = Self.work(type: type, payload: payload) { cursor?.work = work }
                            if let text = Self.output(type: type, payload: payload), !text.isEmpty {
                                let output = String(((cursor?.output ?? "") + text).suffix(24000)); cursor?.output = output
                            }
                            if type == "message.start" || type == "tool.start" { cursor?.status = .working }
                            if let usage = payload["usage"] as? [String: Any], let context = Self.context(usage) { cursor?.context = context }
                            if type == "message.complete" {
                                let status = Self.completion(payload)
                                cursor?.status = status
                                if !initial, let seq = event["seq"] as? Int {
                                    result.events.append(AgentEvent(id: "\(pane.id)|\(cursor!.epoch)|\(seq)", paneKey: pane.id, status: status, summary: "Hermes：\(status.title)", source: "hermes-gateway"))
                                }
                            }
                        }
                        let nextSequence = replay["last_sequence"] as? Int ?? cursor?.sequence ?? 0
                        cursor?.sequence = nextSequence
                        if pane.reportedStatus == .idle, let completed = cursor?.status, [.completed, .failed].contains(completed) { pane.reportedStatus = completed }
                        if let context = pane.contextUsage { cursor?.context = context }
                        pane.contextUsage = pane.contextUsage ?? cursor?.context
                        if pane.reportedStatus == .working {
                            let stale = cursor?.status == .completed || cursor?.status == .failed
                            pane.currentWork = !stale && cursor?.work.isEmpty == false ? cursor?.work : "正在处理任务"
                        } else if pane.reportedStatus == .waiting {
                            pane.currentWork = "等待你的确认"
                        } else {
                            pane.currentWork = cursor?.work.isEmpty == false ? cursor?.work : "暂无进行中的工作"
                        }
                        pane.output = cursor?.output ?? ""
                        cursors[pane.id] = cursor
                        result.panes.append(pane)
                    }
                    result.successfulSources.insert(source)
                } catch { result.errors.append("Hermes GUI：\(error.localizedDescription)") }
            }
        } catch { result.errors.append("Hermes GUI：\(error.localizedDescription)") }
        return result
    }
    public static func status(_ value: String) -> AgentStatus {
        switch value { case "working", "starting", "running": .working; case "waiting": .waiting; case "idle": .idle; case "failed", "error": .failed; default: .unknown }
    }
    public static func context(_ stats: [String: Any]) -> ContextUsage? {
        let capacity = (stats["context_length"] ?? stats["context_max"]) as? Int
        let used = (stats["context_tokens"] ?? stats["last_prompt_tokens"] ?? stats["context_used"]) as? Int
        guard let capacity, let used else { return nil }
        let estimated = stats["context_estimated"] as? Bool == true || (stats["context_source"] as? String).map { !["provider_usage", "api_usage"].contains($0) } == true
        return ContextUsage(used: used, capacity: capacity, source: estimated ? "Hermes Gateway（接口估算值）" : "Hermes Gateway")
    }
    public static func completion(_ payload: [String: Any]) -> AgentStatus {
        let status = payload["status"] as? String ?? ""
        if ["error", "failed", "interrupted", "cancelled"].contains(status) || !(payload["error"] as? String ?? "").isEmpty { return .failed }
        return .completed
    }
    public static func work(type: String, payload: [String: Any]) -> String? {
        if type == "tool.start" {
            let name = payload["name"] as? String ?? payload["tool_name"] as? String ?? "工具调用"
            let args = payload["args"] as? [String: Any] ?? payload["arguments"] as? [String: Any] ?? [:]
            let detail = args["command"] as? String ?? args["path"] as? String ?? args["query"] as? String ?? ""
            return String((name + (detail.isEmpty ? "" : " · " + detail)).prefix(180))
        }
        if type == "message.start" { return "正在思考" }
        if type == "status.update" || type == "message.interim" { return (payload["text"] as? String).map { String($0.prefix(180)) } }
        if type == "message.complete" { return String((payload["text"] as? String ?? payload["content"] as? String ?? "本轮任务结束").prefix(180)) }
        return nil
    }
    public static func output(type: String, payload: [String: Any]) -> String? {
        if type == "message.delta" || type == "thinking.delta" { return payload["text"] as? String ?? payload["delta"] as? String }
        if type == "tool.start" { return "\n→ " + (work(type: type, payload: payload) ?? "") + "\n" }
        if type == "message.complete" { return "\n" + (payload["text"] as? String ?? payload["content"] as? String ?? "") + "\n" }
        return nil
    }
    public func send(_ text: String, to ref: HermesSessionReference) async throws {
        let identity = try HermesControl.request(home: ref.controlHome, verb: "identify")
        let rpc = try HermesRPC(home: ref.controlHome, profileID: ref.profileID, identify: identity); defer { rpc.close() }
        _ = try await rpc.call("session.resume", ["session_id": ref.sessionID])
        _ = try await rpc.call("prompt.submit", ["session_id": ref.sessionID, "submission_id": UUID().uuidString, "text": text])
    }
    public func interrupt(_ ref: HermesSessionReference) async throws {
        let identity = try HermesControl.request(home: ref.controlHome, verb: "identify")
        let rpc = try HermesRPC(home: ref.controlHome, profileID: ref.profileID, identify: identity); defer { rpc.close() }
        let snapshot = try await rpc.call("session.resume", ["session_id": ref.sessionID])
        guard let generation = snapshot["execution_generation"] as? Int else { throw DeckError.message("无法确认 Hermes 当前任务") }
        _ = try await rpc.call("session.interrupt", ["session_id": ref.sessionID, "execution_generation": generation])
    }
    public func close(_ ref: HermesSessionReference) async throws {
        let identity = try HermesControl.request(home: ref.controlHome, verb: "identify")
        let rpc = try HermesRPC(home: ref.controlHome, profileID: ref.profileID, identify: identity); defer { rpc.close() }
        // Close the live session; do not delete its saved conversation or quit Hermes.
        _ = try await rpc.call("session.close", ["session_id": ref.sessionID])
    }
}
