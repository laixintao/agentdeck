import XCTest
@testable import AgentDeckCore

final class LocalSessionTelemetryTests: XCTestCase {
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
