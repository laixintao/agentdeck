import XCTest
@testable import AgentDeckCore

final class HermesGatewayTests: XCTestCase {
    func testNativeGatewayDiscoveryReplayAndControl() async throws {
        guard ProcessInfo.processInfo.environment["AGENTDECK_INTEGRATION"] == "1", let python = Command.find("python3") else { throw XCTSkip("Requires integration tests and python3") }
        let home = URL(fileURLWithPath: "/private/tmp/ad-gw-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let stateURL = home.appendingPathComponent("fixture-state.json")
        func setState(_ status: String, epoch: String = "epoch-one", messageCount: Int? = nil) throws {
            var value: [String: Any] = ["status": status, "epoch": epoch]
            if let messageCount { value["message_count"] = messageCount }
            try JSONSerialization.data(withJSONObject: value).write(to: stateURL, options: .atomic)
        }
        try setState("working")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/hermes_gateway.py")
        let process = Process(); process.executableURL = URL(fileURLWithPath: python); process.arguments = [fixture.path, home.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { process.terminate(); process.waitUntilExit(); try? FileManager.default.removeItem(at: home) }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: home.appendingPathComponent("ready").path) { break }
            if !process.isRunning { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard FileManager.default.fileExists(atPath: home.appendingPathComponent("ready").path) else {
            XCTFail("Local gateway fixture did not finish starting"); return
        }
        let gateway = HermesGateway()
        let first = await gateway.scan(home: home.path)
        XCTAssertTrue(first.errors.isEmpty, first.errors.joined(separator: "\n"))
        let pane = try XCTUnwrap(first.panes.first)
        XCTAssertEqual(pane.reportedStatus, .working)
        XCTAssertEqual(pane.contextUsage?.percent, 25)
        XCTAssertEqual(pane.currentWork, "terminal · swift test")
        XCTAssertTrue(first.events.isEmpty)
        try setState("waiting")
        let waiting = await gateway.scan(home: home.path)
        XCTAssertEqual(waiting.panes.first?.reportedStatus, .waiting)
        try setState("idle")
        let done = await gateway.scan(home: home.path)
        XCTAssertEqual(done.panes.first?.reportedStatus, .completed)
        XCTAssertEqual(done.events.map(\.status), [.completed])
        let repeated = await gateway.scan(home: home.path)
        XCTAssertTrue(repeated.events.isEmpty)
        try setState("idle", epoch: "epoch-two")
        let restarted = await gateway.scan(home: home.path)
        XCTAssertTrue(restarted.events.isEmpty, "Replayed historical completions must not notify")
        let callsURL = home.appendingPathComponent("calls.jsonl")
        let passiveCalls = try String(contentsOf: callsURL, encoding: .utf8)
        XCTAssertFalse(passiveCalls.contains("session.resume"), "Passive discovery must not attach or refresh policies")
        try setState("idle", messageCount: 0)
        let empty = await gateway.scan(home: home.path)
        XCTAssertTrue(empty.errors.isEmpty)
        XCTAssertTrue(empty.panes.isEmpty, "Empty idle GUI tabs should not appear as agents")
        XCTAssertTrue(empty.events.isEmpty)
        XCTAssertTrue(empty.successfulSources.contains(pane.socket), "Previously displayed empty sessions must disappear")
        let afterEmpty = try String(contentsOf: callsURL, encoding: .utf8)
        let emptyCalls = afterEmpty.dropFirst(passiveCalls.count).split(separator: "\n")
        XCTAssertEqual(emptyCalls.count, 1, "Empty sessions need no stats or event requests")
        XCTAssertTrue(emptyCalls.first?.contains("session.active_list") == true)
        for (state, expected) in [("starting", AgentStatus.working), ("working", .working), ("waiting", .waiting)] {
            try setState(state, messageCount: 0)
            let active = await gateway.scan(home: home.path)
            XCTAssertTrue(active.errors.isEmpty)
            XCTAssertEqual(active.panes.first?.reportedStatus, expected, "A zero-message \(state) task must remain visible")
        }
        try setState("idle", messageCount: 2)
        let withHistory = await gateway.scan(home: home.path)
        XCTAssertEqual(withHistory.panes.count, 1, "An idle session with messages must remain visible")
        let ref = try XCTUnwrap(pane.hermesSession)
        try await gateway.send("literal $(do-not-execute)", to: ref)
        try await gateway.interrupt(ref)
        let calls = try String(contentsOf: callsURL, encoding: .utf8).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        let submission = try XCTUnwrap(calls.first { $0["method"] as? String == "prompt.submit" }?["params"] as? [String: Any])
        XCTAssertEqual(submission["text"] as? String, "literal $(do-not-execute)")
        XCTAssertNotNil(submission["submission_id"] as? String)
        let interruption = try XCTUnwrap(calls.first { $0["method"] as? String == "session.interrupt" }?["params"] as? [String: Any])
        XCTAssertEqual(interruption["execution_generation"] as? Int, 12)
        try await gateway.close(ref)
        let closingCalls = try String(contentsOf: callsURL, encoding: .utf8)
        XCTAssertTrue(closingCalls.contains("session.close"))
        XCTAssertFalse(closingCalls.contains("session.delete"), "Closing must preserve saved conversations")
        let closed = await gateway.scan(home: home.path)
        XCTAssertTrue(closed.panes.isEmpty)
        XCTAssertTrue(closed.successfulSources.contains(pane.socket))
        // A permissive control socket must be rejected before a session ticket is requested.
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: home.appendingPathComponent("gateway.sock").path)
        XCTAssertThrowsError(try HermesControl.request(home: home.path, verb: "identify"))
    }
}
