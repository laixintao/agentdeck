import XCTest
import Darwin
@testable import AgentDeckCore

final class TerminalActionsTests: XCTestCase {
    var root: URL!
    var socket: String!
    let client = Tmux()
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["AGENTDECK_INTEGRATION"] == "1" else { throw XCTSkip("Requires isolated tmux") }
        root = URL(fileURLWithPath: "/private/tmp/ad-actions-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        socket = root.appendingPathComponent("sock'et").path
        let result = try Command.run(client.executable, ["-f", "/dev/null", "-S", socket, "new-session", "-d", "-s", "test", "-c", root.path, "/bin/sh"])
        XCTAssertEqual(result.status, 0)
        _ = try client.call(["set-option", "-g", "default-shell", "/bin/sh"], socket: socket)
    }
    override func tearDownWithError() throws {
        if let socket { _ = try? client.call(["kill-server"], socket: socket) }
        if let root { try? FileManager.default.removeItem(at: root) }
    }
    func fixtureCommand() throws -> String {
        guard let python = Command.find("python3") else { throw XCTSkip("Requires Python") }
        let directory = root.appendingPathComponent("hermes-agent")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("cli.py")
        try """
        import signal, time
        signal.signal(signal.SIGINT, lambda *_: print('cancelled', flush=True))
        print('fixture-ready', flush=True)
        while True: time.sleep(1)
        """.write(to: script, atomically: true, encoding: .utf8)
        return [python, script.path].map(Command.quote).joined(separator: " ")
    }
    func waitForAgent(_ paneID: String) throws -> Pane {
        for _ in 0..<80 {
            if let pane = client.scan(onlySockets: [socket]).panes.first(where: { $0.paneID == paneID && $0.output.contains("fixture-ready") && $0.agentStartedAt != nil }) { return pane }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw DeckError.message("Fixture agent did not start")
    }
    func display(_ pane: String, _ format: String) throws -> String {
        try client.call(["display-message", "-p", "-t", pane, format], socket: socket).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func testExitPreservesTheShellAndOtherAgentsAndRejectsStaleIdentity() throws {
        let command = try fixtureCommand()
        let shellPID = try display("%0", "#{pane_pid}")
        _ = try client.call(["send-keys", "-t", "%0", "-l", command], socket: socket)
        _ = try client.call(["send-keys", "-t", "%0", "Enter"], socket: socket)
        let target = try waitForAgent("%0")
        let siblingID = try client.call(["new-window", "-d", "-P", "-F", "#{pane_id}", "-t", "test", "exec " + command], socket: socket).trimmingCharacters(in: .whitespacesAndNewlines)
        let sibling = try waitForAgent(siblingID)
        var stale = target; stale.agentStartedAt = "a previous process"
        XCTAssertThrowsError(try client.exitAgent(stale))
        XCTAssertEqual(Darwin.kill(pid_t(try XCTUnwrap(target.agentPID)), 0), 0)
        stale = target; stale.pid += 1
        XCTAssertThrowsError(try client.exitAgent(stale))
        try client.exitAgent(target)
        XCTAssertEqual(try display(target.paneID, "#{pane_pid}|#{pane_dead}"), shellPID + "|0")
        XCTAssertEqual(Darwin.kill(pid_t(try XCTUnwrap(sibling.agentPID)), 0), 0)
        XCTAssertFalse(client.scan(onlySockets: [socket]).panes.contains(where: { $0.paneID == target.paneID }))
    }
    func testExitOfRootAgentRestoresAShellInTheSamePane() throws {
        let command = try fixtureCommand()
        let id = try client.call(["new-window", "-d", "-P", "-F", "#{pane_id}", "-t", "test", "exec " + command], socket: socket).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try client.call(["set-option", "-p", "-t", id, "@agentdeck_kind", "hermes"], socket: socket)
        let target = try waitForAgent(id)
        XCTAssertEqual(target.agentPID, target.pid)
        let remain = try client.call(["show-options", "-p", "-qv", "-t", id, "remain-on-exit"], socket: socket)
        try client.exitAgent(target)
        XCTAssertEqual(try display(id, "#{pane_dead}"), "0")
        XCTAssertNotEqual(try display(id, "#{pane_pid}"), String(target.pid))
        XCTAssertEqual(try display(id, "#{@agentdeck_kind}"), "")
        XCTAssertEqual(try client.call(["show-options", "-p", "-qv", "-t", id, "remain-on-exit"], socket: socket), remain)
        XCTAssertFalse(client.scan(onlySockets: [socket]).panes.contains(where: { $0.paneID == id }))
    }
    func testInteractiveAgentSelectionExcludesDaemonAndAmbiguousTargets() {
        let entries = ProcessEntry.parse("1 0 zsh\n2 1 node /opt/codex.js\n3 2 /opt/bin/codex\n4 3 /opt/bin/codex app-server --listen unix://\n5 3 codex exec nested-task")
        XCTAssertEqual(ProcessEntry.interactiveAgent(root: 1, kind: .codex, entries: entries)?.pid, 3)
        XCTAssertNil(ProcessEntry.interactiveAgent(root: 4, kind: .codex, entries: entries))
        let ambiguous = entries + ProcessEntry.parse("6 1 codex")
        XCTAssertNil(ProcessEntry.interactiveAgent(root: 1, kind: .codex, entries: ambiguous))
    }
    func testExistingClientReusesConnectionAndSelectsExactPaneWithoutMovingOtherClient() throws {
        guard let python = Command.find("python3") else { throw XCTSkip("Requires Python") }
        _ = try client.call(["new-session", "-d", "-s", "other", "/bin/sh"], socket: socket)
        let window = try client.call(["new-window", "-d", "-P", "-F", "#{pane_id}", "-t", "other", "/bin/sh"], socket: socket).trimmingCharacters(in: .whitespacesAndNewlines)
        let split = try client.call(["split-window", "-d", "-P", "-F", "#{pane_id}", "-t", window, "/bin/sh"], socket: socket).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try client.call(["set-option", "-p", "-t", split, "@agentdeck_kind", "custom"], socket: socket)
        let pane = try XCTUnwrap(client.scan(onlySockets: [socket]).panes.first { $0.paneID == split })
        XCTAssertTrue(try client.attachedClients(for: pane).isEmpty)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/tmux_clients.py")
        process.arguments = [fixture.path, client.executable, socket, "test", "test"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        var attached = [TmuxClient]()
        for _ in 0..<100 {
            attached = try client.attachedClients(for: pane)
            if attached.count == 2 { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(attached.count, 2)
        let original = try XCTUnwrap(attached.first)
        let other = try XCTUnwrap(attached.last)
        _ = try client.call(["rename-session", "-t", "other", "renamed"], socket: socket)
        _ = try client.call(["resize-pane", "-Z", "-t", window], socket: socket)
        try client.select(pane, in: original)
        let after = try client.attachedClients(for: pane)
        XCTAssertEqual(Set(after.map(\.pid)), Set(attached.map(\.pid)), "Do not start or detach any client")
        XCTAssertEqual(after.first?.pid, original.pid, "Prefer a client already showing the exact pane")
        XCTAssertEqual(after.first?.paneID, pane.paneID)
        XCTAssertEqual(try display(split, "#{pane_active}"), "1")
        XCTAssertEqual(after.first(where: { $0.pid == other.pid })?.sessionID, other.sessionID)
        XCTAssertEqual(after.first(where: { $0.pid == other.pid })?.paneID, other.paneID)
        var stale = original; stale.pid += 1
        XCTAssertThrowsError(try client.select(pane, in: stale))
        stale = original; stale.created += 1
        XCTAssertThrowsError(try client.select(pane, in: stale))
        var replacedPane = pane; replacedPane.serverPID += 1
        XCTAssertThrowsError(try client.select(replacedPane, in: original))
    }

    func testClientFilteringAndTerminalAncestorResolution() {
        var fields = ["123", "/dev/ttys001", "/dev/ttys001", "$0", "%1", "1800000000", "1799990000", "0", "attached,UTF-8"]
        XCTAssertNotNil(TmuxClient.parse(fields.joined(separator: Tmux.separator)))
        fields[7] = "1"
        XCTAssertNil(TmuxClient.parse(fields.joined(separator: Tmux.separator)), "Control-mode clients are not terminal windows")
        fields[7] = "0"; fields[8] = "attached,suspended,UTF-8"
        XCTAssertNil(TmuxClient.parse(fields.joined(separator: Tmux.separator)))
        let entries = ProcessEntry.parse("50 1 /Applications/Ghostty.app/Contents/MacOS/ghostty\n51 50 login\n52 51 zsh\n53 52 python\n54 53 tmux\n60 1 Terminal")
        XCTAssertEqual(ProcessEntry.ancestors(of: 54, entries: entries), [54, 53, 52, 51, 50])
        XCTAssertTrue(ProcessEntry.ancestors(of: 999, entries: entries).isEmpty)
        XCTAssertEqual(ProcessEntry.ancestors(of: 2, entries: ProcessEntry.parse("2 3 x\n3 2 y")), [2, 3])
    }
    func testNewTmuxClientSelectsTheExactSocketAndPaneAfterSessionRename() throws {
        guard let python = Command.find("python3") else { throw XCTSkip("Requires Python") }
        let id = try client.call(["new-window", "-d", "-P", "-F", "#{pane_id}", "-t", "test", "/bin/sh"], socket: socket).trimmingCharacters(in: .whitespacesAndNewlines)
        let split = try client.call(["split-window", "-d", "-P", "-F", "#{pane_id}", "-t", id, "/bin/sh"], socket: socket).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try client.call(["set-option", "-p", "-t", split, "@agentdeck_kind", "custom"], socket: socket)
        let pane = try XCTUnwrap(client.scan(onlySockets: [socket]).panes.first { $0.paneID == split })
        _ = try client.call(["rename-session", "-t", "test", "renamed"], socket: socket)
        let command = try client.attachCommand(to: pane)
        var stale = pane; stale.serverPID += 1
        XCTAssertThrowsError(try client.attachCommand(to: stale))
        let script = """
        import os, pty, signal, subprocess, sys, time
        pid, master = pty.fork()
        if pid == 0:
            os.environ['TERM'] = 'xterm-256color'
            os.execl('/bin/sh', 'sh', '-c', sys.argv[1])
        try:
            for _ in range(100):
                result = subprocess.run([sys.argv[2], '-S', sys.argv[3], 'list-clients', '-F', '#{pane_id}'], capture_output=True, text=True)
                if sys.argv[4] in result.stdout.splitlines():
                    print('selected:' + sys.argv[4]); break
                time.sleep(0.05)
            else: raise RuntimeError('Client did not select the requested pane')
        finally:
            try: os.kill(pid, signal.SIGTERM)
            except ProcessLookupError: pass
            os.close(master)
            os.waitpid(pid, 0)
        """
        let result = try Command.run(python, ["-c", script, command, client.executable, socket, pane.paneID], timeout: 10)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("selected:" + pane.paneID))
    }
}
