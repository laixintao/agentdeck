import XCTest
@testable import AgentDeckCore

final class TelemetryTests: XCTestCase {
    func testContextUsesOccupancyNotCumulativeUsage() {
        let usage = HermesGateway.context(["total_tokens": 9_000_000, "input_tokens": 500_000, "context_tokens": 32000, "last_prompt_tokens": 28000, "context_length": 128000])
        XCTAssertEqual(usage?.used, 32000)
        XCTAssertEqual(usage?.percent, 25)
        XCTAssertNil(HermesGateway.context(["total_tokens": 9000000, "context_length": 128000]))
        XCTAssertNil(HermesGateway.context(["context_tokens": 0, "context_length": NSNull()]))
        XCTAssertEqual(HermesGateway.context(["context_used": 64000, "context_max": 128000])?.percent, 50)
    }
    func testContextValidityAndBounds() {
        XCTAssertNil(ContextUsage(used: -1, capacity: 100, source: "test"))
        XCTAssertNil(ContextUsage(used: 0, capacity: 0, source: "test"))
        XCTAssertNil(ContextUsage(percent: .nan, source: "test"))
        XCTAssertEqual(ContextUsage(used: 200, capacity: 100, source: "test")?.percent, 100)
        XCTAssertEqual(ContextUsage(used: 0, capacity: 100, source: "test")?.percent, 0)
    }
    func testTerminalContextFooter() {
        XCTAssertEqual(TerminalTelemetry.context("gpt-6 · 81% context left")?.percent, 19)
        XCTAssertEqual(TerminalTelemetry.context("Context usage: 42% used")?.percent, 42)
        XCTAssertEqual(TerminalTelemetry.context("context: 12.5k / 200k")?.used, 12500)
        XCTAssertEqual(TerminalTelemetry.context("Context: 12,500 / 200,000 tokens")?.percent, 6.25)
        XCTAssertEqual(TerminalTelemetry.context("10% context used\n20% context used")?.percent, 20)
        XCTAssertNil(TerminalTelemetry.context("Tests 99% passed · 21000 total tokens"))
        XCTAssertNil(TerminalTelemetry.context("120% context used"))
        XCTAssertNil(TerminalTelemetry.context("25% context used\n" + Array(repeating: "output", count: 20).joined(separator: "\n")))
    }
    func testWorkAvoidsInputAndMeter() {
        XCTAssertEqual(TerminalTelemetry.work("• Running swift test\n• Working (esc to interrupt)\n› Ask Codex to do anything\n80% context left", kind: .codex), "Running swift test")
        XCTAssertNil(TerminalTelemetry.work("› Ask Codex to do anything\n80% context left", kind: .codex))
        XCTAssertEqual(HermesGateway.work(type: "tool.start", payload: ["name": "terminal", "args": ["command": "swift test"]]), "terminal · swift test")
    }
    func testHermesCompletionOutcomes() {
        XCTAssertEqual(HermesGateway.completion(["status": "complete", "error": NSNull()]), .completed)
        XCTAssertEqual(HermesGateway.completion(["status": "interrupted"]), .failed)
        XCTAssertEqual(HermesGateway.completion(["error": "provider failed"]), .failed)
        XCTAssertEqual(HermesGateway.status("waiting"), .waiting)
        XCTAssertEqual(HermesGateway.status("starting"), .working)
    }
    func testOnlyLiteralLoopbackWebsocketOrigins() {
        XCTAssertEqual(HermesControl.websocketURL("http://127.0.0.1:55265")?.absoluteString, "ws://127.0.0.1:55265/api/ws")
        XCTAssertNotNil(HermesControl.websocketURL("http://[::1]:55265"))
        for origin in ["https://example.com:443", "http://127.0.0.1.evil:80", "http://user@127.0.0.1:80", "http://127.0.0.1:80/path", "http://127.0.0.1:80?x=1", "file:///tmp/test"] {
            XCTAssertNil(HermesControl.websocketURL(origin), origin)
        }
    }
    func testGatewayWorkingSurvivesSilenceAndOldCompletion() {
        var pane = Pane(socket: "hermes:/profile", serverPID: 0, session: "default", window: "GUI", paneID: "session", pid: 0, command: "Hermes GUI", directory: "", kind: .hermes)
        pane.hermesSession = HermesSessionReference(controlHome: "/profile", profileID: "/profile", sessionID: "session")
        pane.reportedStatus = .working
        var monitor = Monitor()
        let now = Date()
        let scan = ScanResult(panes: [pane], errors: [], successfulSockets: [pane.socket], socketCount: 0)
        _ = monitor.ingest(scan, events: [], now: now)
        _ = monitor.ingest(scan, events: [], now: now.addingTimeInterval(300))
        XCTAssertEqual(monitor.records[pane.id]?.status, .working)
        let previousTurn = AgentEvent(paneKey: pane.id, status: .completed, summary: "Previous turn")
        _ = monitor.ingest(scan, events: [previousTurn], now: now.addingTimeInterval(301))
        XCTAssertEqual(monitor.records[pane.id]?.status, .working)
        pane.reportedStatus = .waiting
        let waiting = ScanResult(panes: [pane], errors: [], successfulSockets: [pane.socket], socketCount: 0)
        XCTAssertEqual(monitor.ingest(waiting, events: [], now: now.addingTimeInterval(302)).map(\.status), [.waiting])
        XCTAssertTrue(monitor.ingest(waiting, events: [], now: now.addingTimeInterval(304)).isEmpty)
        XCTAssertEqual(pane.id, "hermes|/profile|session")
        XCTAssertFalse(pane.project.isEmpty)
    }
    func testGatewayDisconnectedVsAuthoritativelyClosed() {
        var pane = Pane(socket: "hermes:/profile", serverPID: 0, session: "default", window: "GUI", paneID: "session", pid: 0, command: "Hermes GUI", directory: "", kind: .hermes)
        pane.hermesSession = HermesSessionReference(controlHome: "/profile", profileID: "/profile", sessionID: "session")
        pane.reportedStatus = .working
        var monitor = Monitor()
        _ = monitor.ingest(ScanResult(panes: [pane], errors: [], successfulSockets: [pane.socket], socketCount: 0), events: [])
        _ = monitor.ingest(ScanResult(panes: [], errors: ["timeout"], successfulSockets: [], socketCount: 0), events: [])
        XCTAssertEqual(monitor.records[pane.id]?.status, .working)
        let result = monitor.ingest(ScanResult(panes: [], errors: [], successfulSockets: [pane.socket], socketCount: 0), events: [])
        XCTAssertEqual(result.map(\.status), [.offline])
        XCTAssertFalse(result.contains { $0.status == .completed })
    }
}
