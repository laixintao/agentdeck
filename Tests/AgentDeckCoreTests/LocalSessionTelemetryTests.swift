import XCTest
@testable import AgentDeckCore

final class LocalSessionTelemetryTests: XCTestCase {
    func testCodexLifecycleUsesTaskEventsAndNotIndividualToolCompletions() {
        func row(_ type: String, _ timestamp: String = "2026-10-28T00:00:00.000Z") -> [String: Any] {
            ["type": "event_msg", "timestamp": timestamp, "payload": ["type": type, "turn_id": "test-turn"]]
        }
        let started = row("task_started")
        XCTAssertEqual(LocalSessionTelemetry.codexEvent([started, row("item_completed"), row("token_count")], paneKey: "test")?.status, .working)
        let done = row("task_complete", "2026-10-28T00:01:00Z")
        let event = LocalSessionTelemetry.codexEvent([started, done], paneKey: "test")
        XCTAssertEqual(event?.status, .completed)
        XCTAssertEqual(event?.id, LocalSessionTelemetry.codexEvent([started, done, row("token_count")], paneKey: "test")?.id)
        XCTAssertEqual(LocalSessionTelemetry.codexEvent([done, started], paneKey: "test")?.status, .working)
        XCTAssertEqual(LocalSessionTelemetry.codexEvent([started, row("turn_aborted")], paneKey: "test")?.status, .failed)
        XCTAssertNil(LocalSessionTelemetry.codexEvent([done, row("task_started", "invalid")], paneKey: "test"))
    }
    func testClaudeCompletionRequiresFinalTurnRecord() {
        let timestamp = "2026-10-28T00:00:00Z"
        let assistant: [String: Any] = ["type": "assistant", "timestamp": timestamp, "uuid": "assistant", "message": ["stop_reason": "end_turn"]]
        let done: [String: Any] = ["type": "system", "subtype": "turn_duration", "timestamp": timestamp, "uuid": "done"]
        XCTAssertEqual(LocalSessionTelemetry.claudeEvent([assistant], paneKey: "test")?.status, .working)
        XCTAssertEqual(LocalSessionTelemetry.claudeEvent([assistant, done], paneKey: "test")?.status, .completed)
        XCTAssertEqual(LocalSessionTelemetry.claudeEvent([done, ["type": "system", "subtype": "away_summary"]], paneKey: "test")?.status, .completed)
        XCTAssertEqual(LocalSessionTelemetry.claudeEvent([done, ["type": "user", "timestamp": timestamp, "uuid": "next"]], paneKey: "test")?.status, .working)
        XCTAssertEqual(LocalSessionTelemetry.claudeEvent([done, ["type": "assistant", "timestamp": timestamp, "isSidechain": true]], paneKey: "test")?.status, .completed)
    }
    func testClaudeCompactionPreservesTheActualTurnLifecycle() {
        let done: [String: Any] = ["type": "system", "subtype": "turn_duration", "timestamp": "2026-10-28T00:00:00Z", "uuid": "done"]
        let prompt: [String: Any] = ["type": "user", "timestamp": "2026-10-28T00:01:00Z", "uuid": "next-prompt"]
        let boundary: [String: Any] = ["type": "system", "subtype": "compact_boundary", "timestamp": "2026-10-28T00:02:00Z"]
        // Idle compaction writes a synthetic user row, not a new user request.
        for flags: [String: Any] in [["isCompactSummary": true], ["isVisibleInTranscriptOnly": true], ["isCompactSummary": true, "isVisibleInTranscriptOnly": true]] {
            let summary = ["type": "user", "timestamp": "2026-10-28T00:02:00Z", "uuid": "summary"] as [String: Any]
            let maintenance = [boundary, summary.merging(flags) { _, value in value }]
            let completed = LocalSessionTelemetry.claudeEvent([done], paneKey: "test")
            XCTAssertEqual(LocalSessionTelemetry.claudeEvent([done] + maintenance, paneKey: "test"), completed)
            XCTAssertEqual(LocalSessionTelemetry.claudeEvent([done, prompt] + maintenance, paneKey: "test")?.status, .working)
            XCTAssertNil(LocalSessionTelemetry.claudeEvent(maintenance, paneKey: "test"))
            XCTAssertEqual(LocalSessionTelemetry.claudeEvent([done] + maintenance + [prompt], paneKey: "test")?.status, .working)
        }
    }
    func testClaudeIdleCompactionDoesNotRestartTheMonitor() {
        var pane = Pane(socket: "/tmp/fixture", serverPID: 1, session: "test", window: "0", paneID: "%0", pid: 2, command: "claude", directory: "/test", kind: .claude, output: "Finished\n❯")
        var rows: [[String: Any]] = [["type": "system", "subtype": "turn_duration", "timestamp": "2026-10-28T00:00:00Z", "uuid": "done"]]
        var monitor = Monitor()
        func ingest() {
            pane.sessionEvent = LocalSessionTelemetry.claudeEvent(rows, paneKey: pane.id)
            _ = monitor.ingest(ScanResult(panes: [pane], errors: [], successfulSockets: [pane.socket], socketCount: 1), events: [])
        }
        ingest()
        XCTAssertEqual(monitor.records[pane.id]?.status, .completed)
        rows.append(["type": "user", "timestamp": "2026-10-28T00:01:00Z", "uuid": "summary", "isCompactSummary": true, "isVisibleInTranscriptOnly": true])
        pane.output = "Compacted while idle, before the prompt cache expired\n❯"
        ingest()
        XCTAssertEqual(monitor.records[pane.id]?.status, .completed)
        ingest()
        XCTAssertEqual(monitor.records[pane.id]?.status, .completed)
        rows.append(["type": "user", "timestamp": "2026-10-28T00:02:00Z", "uuid": "new-request"])
        ingest()
        XCTAssertEqual(monitor.records[pane.id]?.status, .working)
    }
    func testCodexLastRequestRatherThanLifetimeTokens() {
        let row: [String: Any] = ["type": "event_msg", "payload": ["type": "token_count", "info": ["total_token_usage": ["total_tokens": 10000000], "last_token_usage": ["total_tokens": 50000], "model_context_window": 200000]]]
        let usage = LocalSessionTelemetry.codexContext([row, ["type": "unrelated"]])
        XCTAssertEqual(usage?.percent, 25)
        XCTAssertEqual(usage?.used, 50000)
    }
    func testClaudeCacheTokensAndUnknownCapacity() {
        let message: [String: Any] = ["usage": ["input_tokens": 2, "cache_read_input_tokens": 289991, "cache_creation_input_tokens": 1081, "output_tokens": 561]]
        let usage = LocalSessionTelemetry.claudeContext(message: message, capacity: 1000000)
        XCTAssertEqual(usage?.used, 291074)
        XCTAssertEqual(usage?.percent ?? 0, 29.1074, accuracy: 0.0001)
        let unknown = LocalSessionTelemetry.claudeContext(message: message, capacity: nil)
        XCTAssertEqual(unknown?.used, 291074)
        XCTAssertNil(unknown?.percent)
        XCTAssertTrue(unknown?.label.contains("tokens") == true)
    }
    func testRealProcessAttributionWithUTCRegistryAndStalePIDRejection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ad-telemetry-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sleep"); process.arguments = ["60"]
        try process.run()
        defer { process.terminate(); process.waitUntilExit(); try? FileManager.default.removeItem(at: root) }
        let pid = Int(process.processIdentifier), sid = UUID().uuidString, cwd = "/test/shared_project"
        let start = try Command.run("/bin/ps", ["-p", String(pid), "-o", "lstart="], environment: ["TZ": "UTC", "LC_ALL": "C"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let claude = root.appendingPathComponent(".claude")
        func write(_ object: [String: Any], _ relative: String) throws {
            let path = claude.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: object).write(to: path)
        }
        let registry = "sessions/\(pid).json"
        try write(["pid": pid, "sessionId": sid, "cwd": cwd, "procStart": start, "name": "Exact session"], registry)
        try write(["sessionId": sid, "type": "assistant", "message": ["model": "fixture-model", "content": [["type": "text", "text": "Running tests"]], "usage": ["input_tokens": 400, "cache_read_input_tokens": 600]]], "projects/-test-shared-project/\(sid).jsonl")
        try write(["catalog": ["state": ["model": "fixture-model"], "config": ["models": [["id": "fixture-model", "runtime": ["max_input_tokens": 10000]]]]]], "cache/model-catalog/test-cc.json")
        var pane = Pane(socket: "/tmp/fixture", serverPID: 1, session: "test", window: "0", paneID: "%0", pid: pid, command: "claude", directory: cwd, kind: .claude)
        let entries = ProcessEntry.parse("\(pid) 1 claude")
        LocalSessionTelemetry.enrich(&pane, processes: entries, home: root)
        XCTAssertEqual(pane.contextUsage?.percent, 10)
        XCTAssertEqual(pane.previewOutput, "Running tests")
        XCTAssertEqual(pane.title, "Exact session")
        try write(["pid": pid, "sessionId": sid, "cwd": cwd, "procStart": "stale"], registry)
        pane.contextUsage = nil; pane.previewOutput = nil
        LocalSessionTelemetry.enrich(&pane, processes: entries, home: root)
        XCTAssertNil(pane.contextUsage)
        XCTAssertNil(pane.previewOutput)
    }
    func testPreviewRemovesChromeAndKeepsRealOutput() {
        let preview = TerminalTelemetry.preview("Running tests\nTests passed\n+ 4 lines (^t to expand)\n› Ask Codex to do anything\n⏵⏵ auto mode on (shift+tab to cycle) · ← 2 agents\nGPT-6 · project\n← for agents · ? for shortcuts")
        XCTAssertEqual(preview, "Running tests\nTests passed")
        XCTAssertNil(AgentKind.detect("/Applications/Hermes.app/Contents/MacOS/Hermes"))
        XCTAssertEqual(AgentKind.detect("/usr/local/bin/hermes"), .hermes)
    }
}
