import XCTest
@testable import AgentDeckCore

final class HermesGatewayTests: XCTestCase {
    func testNativeGatewayDiscoveryReplayAndControl() async throws {
        guard ProcessInfo.processInfo.environment["AGENTDECK_INTEGRATION"] == "1", let python = Command.find("python3") else { throw XCTSkip("Requires integration tests and python3") }
        let home = URL(fileURLWithPath: "/private/tmp/ad-gw-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let stateURL = home.appendingPathComponent("fixture-state.json")
        func setState(_ status: String, epoch: String = "epoch-one", messageCount: Int? = nil, source: String = "desktop", lastActive: Date? = nil, events: [[String: Any]]? = nil) throws {
            var value: [String: Any] = ["status": status, "epoch": epoch, "source": source]
            if let messageCount { value["message_count"] = messageCount }
            if let lastActive { value["last_active"] = lastActive.timeIntervalSince1970 }
            if let events { value["events"] = events }
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
        // Hermes rewrites the creation source to "local" when a desktop turn
        // starts. Keep the same agent visible across that transition.
        for (state, expected) in [("working", AgentStatus.working), ("waiting", .waiting), ("idle", .completed)] {
            try setState(state, messageCount: 2, source: "local")
            let normalized = await gateway.scan(home: home.path)
            XCTAssertTrue(normalized.errors.isEmpty)
            let local = try XCTUnwrap(normalized.panes.first)
            XCTAssertEqual(local.id, pane.id)
            XCTAssertEqual(local.reportedStatus, expected)
            XCTAssertEqual(local.contextUsage?.percent, 25)
            XCTAssertFalse(local.output.isEmpty)
        }
        try setState("idle", messageCount: 0, source: "local")
        let emptyLocal = await gateway.scan(home: home.path)
        XCTAssertTrue(emptyLocal.panes.isEmpty, "Empty normalized tabs stay hidden")
        for source in ["cli", "cron", "tool", "oneshot"] {
            try setState("working", messageCount: 2, source: source)
            let excluded = await gateway.scan(home: home.path)
            XCTAssertTrue(excluded.panes.isEmpty, "Do not add unrelated \(source) sessions")
        }
        try setState("idle", messageCount: 2, source: "local")
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        let old = clock.addingTimeInterval(-700)
        let timedGateway = HermesGateway()
        var monitor = Monitor()
        func timedRecord(_ seconds: Double) async throws -> AgentRecord {
            let now = clock.addingTimeInterval(seconds)
            let scan = await timedGateway.scan(home: home.path, now: now)
            XCTAssertTrue(scan.errors.isEmpty)
            let current = try XCTUnwrap(scan.panes.first)
            _ = monitor.ingest(ScanResult(panes: scan.panes, errors: [], successfulSockets: scan.successfulSources, socketCount: 0), events: scan.events, now: now)
            return try XCTUnwrap(monitor.records[current.id])
        }
        try setState("idle", messageCount: 2, source: "local", lastActive: old)
        let historical = try await timedRecord(0)
        XCTAssertFalse(historical.isVisible(at: clock), "Starting the app must not revive old history")
        XCTAssertEqual(historical.status, .completed)
        let polled = try await timedRecord(10)
        XCTAssertEqual(polled.pane.lastInteractionAt, old, "Polling and initial event replay are not interaction")
        try setState("working", messageCount: 3, source: "local", lastActive: old)
        let resumed = try await timedRecord(20)
        XCTAssertTrue(resumed.isVisible(at: clock.addingTimeInterval(20)))
        let nearDeadline = try await timedRecord(619)
        XCTAssertTrue(nearDeadline.isVisible(at: clock.addingTimeInterval(619)))
        let expired = try await timedRecord(620)
        XCTAssertFalse(expired.isVisible(at: clock.addingTimeInterval(620)))
        XCTAssertEqual(expired.status, .working, "Hiding is not task completion or session closure")
        let progress: [[String: Any]] = [["seq": 4, "type": "tool.progress", "payload": ["text": "Still working"]]]
        try setState("working", messageCount: 3, source: "local", lastActive: old, events: progress)
        let activeAgain = try await timedRecord(621)
        XCTAssertTrue(activeAgain.isVisible(at: clock.addingTimeInterval(621)), "Hidden sessions keep being observed")
        let usage = progress + [["seq": 5, "type": "session.usage", "payload": ["usage": ["context_used": 32000, "context_max": 128000]]]]
        try setState("working", messageCount: 3, source: "local", lastActive: old, events: usage)
        let onlyUsage = try await timedRecord(1221)
        XCTAssertFalse(onlyUsage.isVisible(at: clock.addingTimeInterval(1221)), "Usage ticks do not keep a quiet session visible")
        try setState("working", epoch: "restarted", messageCount: 3, source: "local", lastActive: old, events: progress)
        let replayed = try await timedRecord(1222)
        XCTAssertFalse(replayed.isVisible(at: clock.addingTimeInterval(1222)), "A new replay epoch does not revive historical activity")
        let passiveAfterTimeout = try String(contentsOf: callsURL, encoding: .utf8)
        XCTAssertFalse(passiveAfterTimeout.contains("session.resume"))
        XCTAssertFalse(passiveAfterTimeout.contains("session.close"))
        try setState("idle", messageCount: 2, source: "local")
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
