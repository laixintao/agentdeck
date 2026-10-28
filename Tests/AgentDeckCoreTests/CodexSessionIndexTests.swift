import XCTest
import SQLite3
@testable import AgentDeckCore

final class CodexSessionIndexTests: XCTestCase {
    var home: URL!
    var root: URL { home.appendingPathComponent(".codex") }
    var database: OpaquePointer?
    let directory = "/test/shared-project"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("ad-codex-index-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("state_5.sqlite").path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE threads (id TEXT, cwd TEXT, rollout_path TEXT, name TEXT, archived INTEGER)", nil, nil, nil), SQLITE_OK)
    }
    override func tearDownWithError() throws {
        sqlite3_close(database); database = nil
        try FileManager.default.removeItem(at: home)
    }
    @discardableResult
    func session(name: String, cwd: String? = nil, metadataID: String? = nil, status: String = "task_complete") throws -> CodexSessionIndex.Session {
        let id = UUID().uuidString.lowercased(), cwd = cwd ?? directory
        let file = root.appendingPathComponent("sessions/rollout-test-\(id).jsonl")
        let rows: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": metadataID ?? id, "cwd": cwd]],
            ["type": "event_msg", "timestamp": "2026-10-28T00:01:00Z", "payload": ["type": status, "turn_id": UUID().uuidString]]
        ]
        try rows.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "INSERT INTO threads VALUES (?, ?, ?, ?, 0)", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in [id, cwd, file.path, name].enumerated() {
            XCTAssertEqual(sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient), SQLITE_OK)
        }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        return CodexSessionIndex.Session(id: id, rollout: file.resolvingSymlinksInPath())
    }
    func testSharedDaemonSessionsAreMatchedByFullTitleAndDirectory() throws {
        let first = try session(name: "Build app", status: "task_started")
        let second = try session(name: "Review tests")
        try session(name: "Build app", cwd: "/other/shared-project")
        XCTAssertEqual(CodexSessionIndex.resolve(title: "⠸ Build app | shared-project", directory: directory, root: root), first)
        XCTAssertEqual(CodexSessionIndex.resolve(title: "Review tests | shared-project", directory: directory, root: root), second)
        XCTAssertNil(CodexSessionIndex.resolve(title: "Unrelated | shared-project", directory: directory, root: root))
        XCTAssertNil(CodexSessionIndex.resolve(title: "Build app | wrong-project", directory: directory, root: root))
        XCTAssertNil(CodexSessionIndex.resolve(title: nil, directory: directory, root: root))
    }
    func testDuplicateNamesAndMismatchedMetadataAreRejected() throws {
        try session(name: "Duplicate")
        try session(name: "Duplicate")
        XCTAssertNil(CodexSessionIndex.resolve(title: "Duplicate | shared-project", directory: directory, root: root))
        try session(name: "Stale index", metadataID: UUID().uuidString)
        XCTAssertNil(CodexSessionIndex.resolve(title: "Stale index | shared-project", directory: directory, root: root))
    }
    func testQuotedTitleIsBoundLiterallyAndCannotMatchOtherSessions() throws {
        let name = "Review ' OR 1=1 -- | notes"
        let expected = try session(name: name)
        try session(name: "Another session")
        XCTAssertEqual(CodexSessionIndex.resolve(title: name + " | shared-project", directory: directory, root: root), expected)
    }
    func testExistingTerminalEnrichmentFindsCompletionWithoutAnOwnedRollout() throws {
        let completed = try session(name: "Review tests")
        let running = try session(name: "Build app", status: "task_started")
        let entries = ProcessEntry.parse("101 1 zsh\n102 101 codex\n103 102 codex app-server --listen unix://\n201 1 zsh\n202 201 codex")
        for (pid, title, session, status) in [(101, "Build app", running, AgentStatus.working), (201, "Review tests", completed, .completed)] {
            var pane = Pane(socket: "/tmp/fixture", serverPID: 1, session: "test", window: "0", paneID: "%\(pid)", pid: pid, command: "codex", directory: directory, kind: .codex)
            pane.terminalTitle = title + " | shared-project"
            LocalSessionTelemetry.enrich(&pane, processes: entries, home: home)
            XCTAssertEqual(pane.sessionID, session.id)
            XCTAssertEqual(pane.sessionEvent?.status, status)
        }
    }
    func testLegacyLookupNeverUsesSharedDaemonOrNestedAgentFiles() {
        let entries = ProcessEntry.parse("1 0 zsh\n2 1 node /opt/codex.js\n3 2 /opt/bin/codex\n4 3 /opt/bin/codex app-server --listen unix://\n5 3 zsh\n6 5 codex exec task\n7 1 zsh")
        XCTAssertEqual(Set(LocalSessionTelemetry.codexOwners(root: 1, processes: entries).map(\.pid)), [2, 3])
        XCTAssertTrue(LocalSessionTelemetry.codexOwners(root: 4, processes: entries).isEmpty)
    }
}
