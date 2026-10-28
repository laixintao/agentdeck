import Foundation

public struct LaunchRequest: Sendable {
    public var kind: AgentKind
    public var directory: String
    public var title: String
    public var executable: String
    public var arguments: [String]
    public init(kind: AgentKind, directory: String, title: String, executable: String = "", arguments: [String] = []) {
        self.kind = kind; self.directory = directory; self.title = title; self.executable = executable; self.arguments = arguments
    }
}

public enum Launch {
    public static func arguments(kind: AgentKind, original: [String], helper: String, paneKey: String) throws -> [String] {
        let event = [helper, "event", "--key", paneKey]
        switch kind {
        case .codex:
            let notify = event + ["--state", "completed", "--codex"]
            let json = String(decoding: try JSONEncoder().encode(notify), as: UTF8.self)
            return ["-c", "notify=\(json)"] + original
        case .claude:
            func hook(_ state: String, matcher: String? = nil) -> [String: Any] {
                var item: [String: Any] = ["hooks": [["type": "command", "command": (event + ["--state", state]).map(Command.quote).joined(separator: " "), "timeout": 5]]]
                if let matcher { item["matcher"] = matcher }
                return item
            }
            let settings: [String: Any] = ["hooks": [
                "UserPromptSubmit": [hook("working")], "Stop": [hook("completed")],
                "Notification": [hook("waiting", matcher: "permission_prompt|idle_prompt")],
                "PreToolUse": [hook("working")]
            ]]
            let json = String(decoding: try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]), as: UTF8.self)
            return ["--settings", json] + original
        case .hermes, .custom: return original
        }
    }

    public static func create(_ request: LaunchRequest, tmux: Tmux, helper: String, socket: String? = nil) throws -> String {
        let directory = (request.directory as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else { throw DeckError.message("项目目录不存在。") }
        let executable = request.executable.isEmpty ? request.kind.executable : request.executable
        guard let resolved = Command.find(executable) else { throw DeckError.message("找不到 \(executable)，请先安装或指定完整路径。") }
        guard FileManager.default.isExecutableFile(atPath: helper) else { throw DeckError.message("找不到 agentdeck 辅助程序，请使用打包后的 App。") }
        let name = "deck-" + String(UUID().uuidString.prefix(8)).lowercased()
        let command = ([helper, "run", "--kind", request.kind.rawValue, "--title", request.title, "--", resolved] + request.arguments).map(Command.quote).joined(separator: " ")
        let args = ["new-session", "-d", "-x", "120", "-y", "40", "-P", "-F", "#{pane_id}", "-s", name, "-c", directory, "exec " + command]
        let result = try Command.run(tmux.executable, (socket.map { ["-S", $0] } ?? []) + args)
        guard result.status == 0 else { throw DeckError.message(result.stderr) }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
