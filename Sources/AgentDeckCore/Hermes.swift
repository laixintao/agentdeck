import Foundation

public enum Hermes {
    public static func status(for event: String) -> AgentStatus? {
        switch event {
        case "pre_llm_call", "on_human_input_resolved": .working
        case "post_llm_call": .completed
        case "on_human_input_request": .waiting
        default: nil
        }
    }
    public static func breadcrumbName(tty: String) -> String {
        let stripped = tty.trimmingCharacters(in: CharacterSet(charactersIn: "/").union(.whitespacesAndNewlines))
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return "tty-" + String(String.UnicodeScalarView(stripped.unicodeScalars.map { allowed.contains($0) ? $0 : UnicodeScalar(45)! }).prefix(120))
    }
    public static func paneKey(sessionID: String, home: URL, tmux: Tmux = Tmux(), sockets: [String]? = nil) -> String? {
        // Hermes' gateway may execute hooks outside the client process. Its per-TTY
        // breadcrumb binds a session ID to the actual terminal, never just the cwd.
        let scan = tmux.scan(onlySockets: sockets, captureOutput: false)
        for pane in scan.panes where pane.kind == .hermes && !pane.dead && pane.agentRunning {
            guard let tty = try? tmux.call(["display-message", "-p", "-t", pane.paneID, "#{pane_tty}"], socket: pane.socket).trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
            let file = home.appendingPathComponent("terminal-sessions").appendingPathComponent(breadcrumbName(tty: tty))
            guard let data = try? Data(contentsOf: file), let crumb = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  crumb["session_id"] as? String == sessionID,
                  let ts = crumb["ts"] as? Double, Date().timeIntervalSince1970 - ts < 30 * 86400 else { continue }
            return pane.id
        }
        return nil
    }
    public static func installerPython(executable: String) throws -> String {
        let resolved = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
        guard let file = FileHandle(forReadingAtPath: resolved.path) else { throw DeckError.message("无法读取 Hermes 可执行文件。") }
        defer { try? file.close() }
        let data = try file.read(upToCount: 1024) ?? Data()
        let first = String(decoding: data, as: UTF8.self).components(separatedBy: .newlines).first ?? ""
        guard first.hasPrefix("#!") else { throw DeckError.message("无法确定 Hermes 的 Python 环境，请按 README 手动接入 hooks。") }
        let words = first.dropFirst(2).split(whereSeparator: \.isWhitespace).map(String.init)
        if let path = words.first, path != "/usr/bin/env", FileManager.default.isExecutableFile(atPath: path) { return path }
        if let name = words.dropFirst().first, let path = Command.find(name) { return path }
        throw DeckError.message("找不到 Hermes 的 Python 解释器。")
    }
}
