import XCTest
@testable import AgentDeckCore

final class IntegrationTests: XCTestCase {
    func testMessageIsSubmittedOutsidePasteInsteadOfInsertingNewline() throws {
        guard ProcessInfo.processInfo.environment["AGENTDECK_INTEGRATION"] == "1", let python = Command.find("python3") else { throw XCTSkip("Requires isolated tmux and Python") }
        let root = URL(fileURLWithPath: "/private/tmp/ad-input-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let client = Tmux(), socket = root.appendingPathComponent("socket").path
        defer { _ = try? client.call(["kill-server"], socket: socket); try? FileManager.default.removeItem(at: root) }
        let boot = try Command.run(client.executable, ["-f", "/dev/null", "-S", socket, "new-session", "-d", "-s", "test"])
        XCTAssertEqual(boot.status, 0)
        _ = try client.call(["set-buffer", "-b", "unrelated", "keep this buffer"], socket: socket)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/prompt_input.py")
        let result = root.appendingPathComponent("submitted.json")
        let helper = FileManager.default.currentDirectoryPath + "/.build/debug/agentdeckctl"
        _ = try Launch.create(LaunchRequest(kind: .custom, directory: root.path, title: "Prompt input", executable: python, arguments: [fixture.path, result.path]), tmux: client, helper: helper, socket: socket)
        var target: Pane?
        for _ in 0..<50 {
            target = client.scan(onlySockets: [socket]).panes.first { $0.output.contains("prompt-ready") }
            if target != nil { break }; Thread.sleep(forTimeInterval: 0.05)
        }
        let pane = try XCTUnwrap(target)
        let message = "发送新消息 'quoted' $(literal) ; --flag ✅"
        try client.send(message, to: pane)
        for _ in 0..<50 {
            if FileManager.default.fileExists(atPath: result.path) { break }; Thread.sleep(forTimeInterval: 0.05)
        }
        let submitted = try JSONSerialization.jsonObject(with: Data(contentsOf: result)) as? [String: Any]
        XCTAssertEqual(submitted?["message"] as? String, message)
        XCTAssertEqual(submitted?["pastes"] as? Int, 1)
        XCTAssertEqual(try client.call(["show-buffer", "-b", "unrelated"], socket: socket), "keep this buffer")
        XCTAssertFalse(try client.call(["list-buffers", "-F", "#{buffer_name}"], socket: socket).contains("agentdeck-"))
    }
    func testExecutableDetectionAndProcessTree() {
        let entries = ProcessEntry.parse("100 1 /bin/zsh\n101 100 node /opt/bin/codex.js\n102 1 python /opt/hermes-agent/cli.py")
        XCTAssertEqual(ProcessEntry.agent(root: 100, entries: entries), .codex)
        XCTAssertEqual(ProcessEntry.agent(root: 102, entries: entries), .hermes)
        XCTAssertNil(AgentKind.detect("vim /tmp/codex-notes.md"))
        XCTAssertNil(AgentKind.detect("vim /tmp/codex"))
        XCTAssertNil(AgentKind.detect("rg codex README.md"))
    }
    func testSocketIdentityWithComma() {
        XCTAssertEqual(Tmux.socketFromEnvironment("/tmp/my,socket,123,0"), "/tmp/my,socket")
        let missing = "agentdeck-missing-" + UUID().uuidString
        XCTAssertEqual(Tmux.canonicalSocket("/tmp/\(missing)/nested/default"), Tmux.canonicalSocket("/private/tmp/\(missing)/nested/default"))
    }
    func testHermesHookContracts() {
        XCTAssertEqual(Hermes.status(for: "pre_llm_call"), .working)
        XCTAssertEqual(Hermes.status(for: "post_llm_call"), .completed)
        XCTAssertEqual(Hermes.status(for: "on_human_input_request"), .waiting)
        XCTAssertNil(Hermes.status(for: "post_tool_call"))
        XCTAssertEqual(Hermes.breadcrumbName(tty: "/dev/ttys012"), "tty-dev-ttys012")
    }
    func testShellQuotingKeepsArgumentsLiteral() throws {
        let value = "don't $(touch /tmp/should-not-exist) `whoami` ; with space\nnext"
        let result = try Command.run("/bin/sh", ["-c", "printf %s " + Command.quote(value)])
        XCTAssertEqual(result.stdout, value)
    }
    func testCommandDrainsLargeOutputAndTimesOut() throws {
        let result = try Command.run("/usr/bin/seq", ["1", "20000"])
        XCTAssertTrue(result.stdout.hasSuffix("20000\n"))
        XCTAssertThrowsError(try Command.run("/bin/sleep", ["5"], timeout: 0.05))
    }
    func testHookArgumentsDoNotModifyGlobalConfiguration() throws {
        let codex = try Launch.arguments(kind: .codex, original: ["a 'quoted' prompt"], helper: "/Applications/My App/agentdeck", paneKey: "socket|1|%1|2")
        XCTAssertEqual(codex[0], "-c")
        let data = Data(codex[1].dropFirst("notify=".count).utf8)
        let notify = try JSONDecoder().decode([String].self, from: data)
        XCTAssertEqual(notify.first, "/Applications/My App/agentdeck")
        XCTAssertEqual(notify.last, "--codex")
        let claude = try Launch.arguments(kind: .claude, original: [], helper: "/tmp/helper", paneKey: "socket|1|%1|2")
        let settings = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(claude[1].utf8)) as? [String: Any])
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["Stop"]); XCTAssertNotNil(hooks["UserPromptSubmit"])
    }
    func testAtomicEventsAndPersistentUnreadHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EventStore(root: root)
        let event = AgentEvent(paneKey: "pane", status: .completed, summary: "Done")
        try store.write(event)
        try Data("invalid".utf8).write(to: store.eventsDirectory.appendingPathComponent("partial.json"))
        XCTAssertEqual(store.read().map(\.id), [event.id])
        XCTAssertTrue(store.read(excluding: [event.id]).isEmpty)
        let activity = Activity(paneKey: "pane", title: "Project", status: .completed, summary: "Done")
        try store.save([activity], name: "history.json")
        XCTAssertEqual(store.load([Activity].self, name: "history.json")?.first?.read, false)
    }
    func testRealCodexAndClaudeHookCallbacks() throws {
        let helper = FileManager.default.currentDirectoryPath + "/.build/debug/agentdeckctl"
        guard FileManager.default.isExecutableFile(atPath: helper) else { throw XCTSkip("Build agentdeckctl first") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ad-hooks-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let env = ["AGENTDECK_DATA_DIR": root.path]
        let key = "socket|1|%2|3"
        let codex = try Launch.arguments(kind: .codex, original: [], helper: helper, paneKey: key)
        let notify = try JSONDecoder().decode([String].self, from: Data(codex[1].dropFirst("notify=".count).utf8))
        let payload = "{\"type\":\"agent-turn-complete\",\"last-assistant-message\":\"private response\"}"
        XCTAssertEqual(try Command.run(notify[0], Array(notify.dropFirst()) + [payload], environment: env).status, 0)
        let disk = EventStore(root: root)
        XCTAssertEqual(disk.read().last?.paneKey, key)
        XCTAssertEqual(disk.read().last?.status, .completed)
        XCTAssertFalse(disk.read().last?.summary.contains("private response") ?? true)
        _ = try Command.run(notify[0], Array(notify.dropFirst()) + ["{\"type\":\"unrelated-event\"}"], environment: env)
        XCTAssertEqual(disk.read().count, 1)
        let claude = try Launch.arguments(kind: .claude, original: [], helper: helper, paneKey: key)
        let settings = try JSONSerialization.jsonObject(with: Data(claude[1].utf8)) as! [String: Any]
        let hooks = settings["hooks"] as! [String: [[String: Any]]]
        let stop = (hooks["Stop"]![0]["hooks"] as! [[String: Any]])[0]["command"] as! String
        let result = try Command.run("/bin/sh", ["-c", stop], environment: env)
        XCTAssertEqual(result.status, 0); XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertEqual(disk.read().count, 2)
        XCTAssertEqual(disk.read().last?.status, .completed)
    }
    func testRealTmuxLaunchInputEventsAndExit() throws {
        guard ProcessInfo.processInfo.environment["AGENTDECK_INTEGRATION"] == "1" else { throw XCTSkip("Set AGENTDECK_INTEGRATION=1 for isolated real tmux tests") }
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("ad-test-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let socket = root.appendingPathComponent("tmux.sock").path
        let helper = FileManager.default.currentDirectoryPath + "/.build/debug/agentdeckctl"
        let client = Tmux()
        defer { _ = try? client.call(["kill-server"], socket: socket); try? FileManager.default.removeItem(at: root) }
        // Disable user tmux config on this private server only.
        let boot = try Command.run(client.executable, ["-f", "/dev/null", "-S", socket, "new-session", "-d", "-s", "bootstrap"])
        XCTAssertEqual(boot.status, 0)
        let script = root.appendingPathComponent("fake-agent.sh")
        let eventDir = root.appendingPathComponent("events-root").path
        _ = try client.call(["set-environment", "-g", "AGENTDECK_DATA_DIR", eventDir], socket: socket)
        try """
        #!/bin/sh
        export AGENTDECK_DATA_DIR=\(Command.quote(eventDir))
        printf 'Ready for literal input\\n'
        IFS= read -r answer
        printf 'RECEIVED:%s\\n' "$answer"
        \(Command.quote(helper)) event --state completed
        sleep 1
        exit 0
        """.write(to: script, atomically: true, encoding: .utf8)
        let request = LaunchRequest(kind: .custom, directory: root.path, title: "Integration", executable: "/bin/sh", arguments: [script.path])
        _ = try Launch.create(request, tmux: client, helper: helper, socket: socket)
        var panes = [Pane]()
        for _ in 0..<30 {
            panes = client.scan(onlySockets: [socket]).panes
            if panes.first?.output.contains("Ready for literal input") == true { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let pane = try XCTUnwrap(panes.first)
        XCTAssertEqual(pane.title, "Integration")
        // Exercise Hermes' gateway-to-terminal routing with a real pane + session breadcrumb.
        _ = try client.call(["set-option", "-p", "-t", pane.paneID, "@agentdeck_kind", "hermes"], socket: socket)
        let tty = try client.call(["display-message", "-p", "-t", pane.paneID, "#{pane_tty}"], socket: socket).trimmingCharacters(in: .whitespacesAndNewlines)
        let hermesHome = root.appendingPathComponent("hermes")
        let crumbs = hermesHome.appendingPathComponent("terminal-sessions")
        try FileManager.default.createDirectory(at: crumbs, withIntermediateDirectories: true)
        let crumb = try JSONSerialization.data(withJSONObject: ["session_id": "test-session", "ts": Date().timeIntervalSince1970])
        try crumb.write(to: crumbs.appendingPathComponent(Hermes.breadcrumbName(tty: tty)))
        XCTAssertEqual(Hermes.paneKey(sessionID: "test-session", home: hermesHome, tmux: client, sockets: [socket]), pane.id)
        XCTAssertNil(Hermes.paneKey(sessionID: "wrong-session", home: hermesHome, tmux: client, sockets: [socket]))
        let payload = Data("{\"hook_event_name\":\"on_human_input_request\",\"session_id\":\"test-session\"}".utf8)
        let hook = try Command.run(helper, ["hermes-hook", "--socket", socket], input: payload, environment: ["AGENTDECK_DATA_DIR": eventDir, "HERMES_HOME": hermesHome.path])
        XCTAssertEqual(hook.status, 0); XCTAssertTrue(hook.stdout.isEmpty)
        XCTAssertEqual(EventStore(root: URL(fileURLWithPath: eventDir)).read().last?.status, .waiting)
        _ = try client.call(["set-option", "-p", "-t", pane.paneID, "@agentdeck_kind", "custom"], socket: socket)
        let literal = "hello 'world' $(echo dangerous) ; --literal"
        try client.send(literal, to: pane)
        XCTAssertThrowsError(try client.send("line1\nline2", to: pane))
        var events = [AgentEvent]()
        for _ in 0..<30 {
            events = EventStore(root: URL(fileURLWithPath: eventDir)).read()
            if events.contains(where: { $0.status == .completed }) { break }; Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertEqual(events.last?.paneKey, pane.id)
        XCTAssertEqual(events.last?.status, .completed)
        var final = pane
        for _ in 0..<30 {
            final = try XCTUnwrap(client.scan(onlySockets: [socket]).panes.first)
            if final.dead { break }; Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(final.output.contains("RECEIVED:" + literal))
        XCTAssertTrue(final.dead); XCTAssertEqual(final.exitCode, 0)
        XCTAssertThrowsError(try client.send("must not reach shell", to: final))
        var stale = final; stale.pid += 1
        XCTAssertThrowsError(try client.validate(stale))
        let interruptRequest = LaunchRequest(kind: .custom, directory: root.path, title: "Interrupt check", executable: "/bin/sh", arguments: ["-c", "trap 'exit 130' INT; printf 'interrupt-ready\\n'; while :; do sleep 1; done"])
        _ = try Launch.create(interruptRequest, tmux: client, helper: helper, socket: socket)
        var target: Pane?
        for _ in 0..<30 {
            target = client.scan(onlySockets: [socket]).panes.first { $0.title == "Interrupt check" && $0.output.contains("interrupt-ready") }
            if target != nil { break }; Thread.sleep(forTimeInterval: 0.1)
        }
        let interruptPane = try XCTUnwrap(target)
        try client.interrupt(interruptPane)
        for _ in 0..<30 {
            target = client.scan(onlySockets: [socket]).panes.first { $0.id == interruptPane.id }
            if target?.dead == true { break }; Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertEqual(target?.dead, true)
        XCTAssertEqual(target?.exitCode, 130)
    }
}
