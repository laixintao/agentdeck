import Foundation
import Darwin
import AgentDeckCore

let args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String, in values: [String] = args) -> String? {
    guard let index = values.firstIndex(of: name), values.indices.contains(index + 1) else { return nil }
    return values[index + 1]
}
func currentPaneKey() throws -> String {
    let env = ProcessInfo.processInfo.environment
    guard let tmuxEnv = env["TMUX"], let socket = Tmux.socketFromEnvironment(tmuxEnv), let pane = env["TMUX_PANE"] else { throw DeckError.message("请在 tmux pane 中运行，或使用 --key 指定 pane。") }
    let identity = try Tmux().call(["display-message", "-p", "-t", pane, "#{pid}|#{pane_pid}"], socket: socket).trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|")
    guard identity.count == 2 else { throw DeckError.message("无法读取 tmux pane。") }
    return "\(Tmux.canonicalSocket(socket))|\(identity[0])|\(pane)|\(identity[1])"
}
do {
    switch args.first {
    case "hermes-hook":
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let payload = try JSONSerialization.jsonObject(with: input) as? [String: Any],
              let eventName = payload["hook_event_name"] as? String, let status = Hermes.status(for: eventName),
              let session = payload["session_id"] as? String, !session.isEmpty else { exit(0) }
        let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HERMES_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes").path)
        let configuredSockets = (UserDefaults(suiteName: "app.agentdeck.mac")?.string(forKey: "extraSockets") ?? "").components(separatedBy: .newlines)
        let sockets = option("--socket").map { [$0] } ?? Tmux.sockets(extra: configuredSockets)
        // Explicit key is useful for older in-process Hermes hook runtimes.
        if let key = option("--key") ?? Hermes.paneKey(sessionID: session, home: home, sockets: sockets) {
            try EventStore().write(AgentEvent(paneKey: key, status: status, summary: "Hermes 报告：\(status.title)", source: "hermes-hook"))
        }
    case "event":
        guard let raw = option("--state"), let status = AgentStatus(rawValue: raw) else { throw DeckError.message("event --state working|waiting|completed|failed|idle [--key PANE_KEY]") }
        if args.contains("--codex") {
            guard let json = args.last?.data(using: .utf8), let data = try JSONSerialization.jsonObject(with: json) as? [String: Any], data["type"] as? String == "agent-turn-complete" else { exit(0) }
        }
        let key = try option("--key") ?? currentPaneKey()
        try EventStore().write(AgentEvent(paneKey: key, status: status, summary: "Agent 报告：\(status.title)"))
    case "run":
        guard let delimiter = args.firstIndex(of: "--"), args.count > delimiter + 1 else { throw DeckError.message("run --kind codex|claude|hermes|custom [--title 名称] -- COMMAND [ARG…]") }
        let options = Array(args[..<delimiter])
        let kind = AgentKind(rawValue: option("--kind", in: options) ?? "custom") ?? .custom
        let key = try currentPaneKey()
        let parts = key.components(separatedBy: "|")
        let tmux = Tmux()
        _ = try tmux.call(["set-option", "-p", "-t", parts[2], "@agentdeck_kind", kind.rawValue], socket: parts[0])
        _ = try tmux.call(["set-option", "-p", "-t", parts[2], "@agentdeck_title", option("--title", in: options) ?? ""], socket: parts[0])
        _ = try tmux.call(["set-option", "-p", "-t", parts[2], "remain-on-exit", "on"], socket: parts[0])
        let helper = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        let executable = args[delimiter + 1]
        guard let path = Command.find(executable) else { throw DeckError.message("找不到命令：\(executable)") }
        let commandArgs = try Launch.arguments(kind: kind, original: Array(args.dropFirst(delimiter + 2)), helper: helper, paneKey: key)
        try EventStore().write(AgentEvent(paneKey: key, status: .unknown, summary: "会话已启动，等待任务状态", source: "launcher"))
        setenv("PATH", Command.environment["PATH"]!, 1)
        let cargs = ([path] + commandArgs).map { strdup($0) } + [nil]
        execv(path, cargs)
        throw DeckError.message("启动失败：\(String(cString: strerror(errno)))")
    case "scan":
        if args.contains("--hermes") {
            let scan = await HermesGateway().scan(home: option("--home") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes").path)
            if args.contains("--json") { print(String(decoding: try JSONEncoder().encode(scan.panes), as: UTF8.self)) }
            else { for pane in scan.panes { print("\(pane.kind.title)\t\(pane.location)\t\(pane.reportedStatus?.title ?? "未知")\tcontext: \(pane.contextUsage?.label ?? "未提供")") } }
            for error in scan.errors { FileHandle.standardError.write(Data((error + "\n").utf8)) }
            exit(scan.errors.isEmpty ? 0 : 1)
        }
        let scan = Tmux().scan(extraSockets: option("--socket").map { [$0] } ?? [])
        if args.contains("--json") { print(String(decoding: try JSONEncoder().encode(scan.panes), as: UTF8.self)) }
        else {
            for pane in scan.panes {
                print("\(pane.kind.title)\t\(pane.location)\t\(ScreenSignal.read(pane.output, kind: pane.kind)?.status.title ?? "观察中")\t\(pane.directory)")
            }
        }
        if !scan.errors.isEmpty { FileHandle.standardError.write(Data((scan.errors.joined(separator: "\n") + "\n").utf8)); exit(1) }
    default:
        print("""
        AgentDeck — local agent companion
          agentdeckctl scan [--json] [--socket PATH]
          agentdeckctl scan --hermes [--json] [--home PATH]
          agentdeckctl run --kind codex|claude|hermes|custom [--title NAME] -- COMMAND [ARG…]
          agentdeckctl event --state working|waiting|completed|failed|idle [--key PANE_KEY]
          agentdeckctl hermes-hook  (reads Hermes hook JSON from stdin)

        run 在当前 tmux pane 中启动 agent，为 Codex / Claude 注入本次会话的完成 hook。
        event 仅写入本机事件，不读取或保存提示词、回复和凭证。
        """)
    }
} catch {
    FileHandle.standardError.write(Data(("AgentDeck: \(error.localizedDescription)\n").utf8))
    exit(1)
}
