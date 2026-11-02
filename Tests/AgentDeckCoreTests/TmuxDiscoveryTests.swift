import XCTest
@testable import AgentDeckCore

final class TmuxDiscoveryTests: XCTestCase {
    func testDiscoveryPreservesFieldsAndUnicodeWithoutTerminalLocale() throws {
        guard ProcessInfo.processInfo.environment["AGENTDECK_INTEGRATION"] == "1" else { throw XCTSkip("Requires isolated tmux") }
        let root = URL(fileURLWithPath: "/private/tmp/ad-locale-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = Tmux(), socket = root.appendingPathComponent("socket").path
        defer { _ = try? original.call(["kill-server"], socket: socket); try? FileManager.default.removeItem(at: root) }
        let output = "任务正在运行 🚀"
        let boot = try Command.run(original.executable, ["-u", "-f", "/dev/null", "-S", socket, "new-session", "-d", "-s", "finder-test", "-c", root.path,
            "printf '%s\\n' " + Command.quote(output) + "; exec /bin/sleep 60"])
        XCTAssertEqual(boot.status, 0, boot.stderr)
        _ = try original.call(["set-option", "-p", "-t", "%0", "@agentdeck_kind", "custom"], socket: socket)
        _ = try original.call(["set-option", "-p", "-t", "%0", "@agentdeck_title", "中文任务 🚀"], socket: socket)
        _ = try original.call(["select-pane", "-t", "%0", "-T", "终端标题"], socket: socket)
        for _ in 0..<50 {
            if try original.call(["capture-pane", "-p", "-t", "%0"], socket: socket).contains(output) { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        // Finder supplies no locale; an explicit C locale must work too. A wrapper
        // isolates the child environment without mutating the test process globals.
        for locale in ["", "LC_ALL=C"] {
            let wrapper = root.appendingPathComponent("tmux-without-terminal-locale")
            try """
            #!/bin/sh
            exec /usr/bin/env -i PATH=/usr/bin:/bin HOME=\(Command.quote(root.path)) \(locale) \(Command.quote(original.executable)) "$@"
            """.write(to: wrapper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
            let client = Tmux(executable: wrapper.path)
            let scan = client.scan(onlySockets: [socket])
            XCTAssertTrue(scan.errors.isEmpty, scan.errors.joined(separator: "\n"))
            XCTAssertEqual(scan.panes.count, 1, "Locale '\(locale)' must not silently lose the pane")
            let pane = try XCTUnwrap(scan.panes.first)
            XCTAssertEqual(pane.title, "中文任务 🚀")
            XCTAssertEqual(pane.terminalTitle, "终端标题")
            XCTAssertTrue(pane.output.contains(output), pane.output)
            XCTAssertEqual(pane.directory, root.path)
            XCTAssertTrue(scan.successfulSockets.contains(Tmux.canonicalSocket(socket)))
        }
    }

    func testMalformedPaneDataReportsFailureInsteadOfClosingKnownAgents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ad-malformed-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("tmux")
        try "#!/bin/sh\nprintf '%s\\n' '1_session_0_%0_2_codex_/tmp___0__title'\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let socket = root.appendingPathComponent("socket").path
        let scan = Tmux(executable: executable.path).scan(onlySockets: [socket])
        XCTAssertTrue(scan.panes.isEmpty)
        XCTAssertFalse(scan.errors.isEmpty, "Malformed output must be visible in connection status")
        XCTAssertFalse(scan.successfulSockets.contains(Tmux.canonicalSocket(socket)), "An invalid scan is not evidence that sessions closed")
    }
}
