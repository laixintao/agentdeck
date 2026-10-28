import XCTest
import SQLite3
@testable import AgentDeckCore

final class HermesActivityTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testVisibilityExpiresWithoutChangingStateAndOnlyForHermes() {
        for kind in AgentKind.allCases {
            var pane = Pane(socket: "fixture", serverPID: 1, session: "s", window: "0", paneID: "%0", pid: 2, command: kind.rawValue, directory: "/fixture", kind: kind)
            pane.lastInteractionAt = now
            var record = AgentRecord(pane: pane, now: now)
            for state in [AgentStatus.working, .waiting, .idle, .completed, .failed] {
                record.status = state
                XCTAssertTrue(record.isVisible(at: now.addingTimeInterval(599)))
                XCTAssertEqual(record.isVisible(at: now.addingTimeInterval(600)), kind != .hermes)
                XCTAssertEqual(record.status, state)
                XCTAssertTrue(record.isPresent)
            }
            record.inputSentAt = now.addingTimeInterval(601)
            XCTAssertTrue(record.isVisible(at: now.addingTimeInterval(601)))
            record.isPresent = false
            XCTAssertFalse(record.isVisible(at: now))
        }
    }

    func testUnknownActivityGetsOneGracePeriodAndOnlyInteractionsExtendIt() {
        var observation = HermesActivity.Observation(date: now, status: .working, messageCount: 2)
        observation.update(saved: nil, status: .working, messageCount: 2, newEvent: false, now: now.addingTimeInterval(700))
        XCTAssertEqual(observation.date, now)
        observation.update(saved: nil, status: .working, messageCount: 3, newEvent: false, now: now.addingTimeInterval(701))
        XCTAssertEqual(observation.date, now.addingTimeInterval(701))
        for event in ["message.delta", "tool.progress", "thinking.delta", "reasoning.delta", "approval.request", "clarify.settled"] {
            XCTAssertTrue(HermesActivity.isInteraction(event))
        }
        for event in ["session.usage", "session.title", "status.update", "session.replay_gap", "gateway.ready"] {
            XCTAssertFalse(HermesActivity.isInteraction(event))
        }
    }

    func testDurableTimesFollowExactTranscriptAndIgnoreUnrelatedOrInvalidDates() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ad-hermes-activity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(home.appendingPathComponent("state.db").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE sessions(id TEXT PRIMARY KEY, started_at REAL, last_activity_at REAL);
        CREATE TABLE messages(session_id TEXT, timestamp REAL);
        CREATE TABLE state_meta(key TEXT PRIMARY KEY, value TEXT);
        INSERT INTO sessions VALUES ('logical', 1799990000, 1799990100), ('physical', 1799990200, 1799999900), ('other', 1800000000, 1800000000);
        INSERT INTO messages VALUES ('physical', 1799999990), ('physical', 1e200), ('physical', -1), ('other', 1800000000);
        INSERT INTO state_meta VALUES ('gateway.local_policy.v1:logical', '{"entry":{"session_id":"physical"}}');
        INSERT INTO sessions VALUES ('legacy', 1799990000, NULL), ('broken', 1799990000, NULL);
        INSERT INTO messages VALUES ('legacy', 1799999980);
        INSERT INTO state_meta VALUES ('gateway.local_policy.v1:broken', 'invalid json');
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        let before = try Data(contentsOf: home.appendingPathComponent("state.db"))
        let dates = HermesActivity.savedDates(profile: home.path, sessionIDs: ["logical", "legacy", "broken", "' OR 1=1 --"], now: now)
        XCTAssertEqual(dates["logical"], now.addingTimeInterval(-10))
        XCTAssertEqual(dates["legacy"], now.addingTimeInterval(-20))
        XCTAssertEqual(dates["broken"], now.addingTimeInterval(-10000))
        XCTAssertNil(dates["' OR 1=1 --"])
        XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent("state.db")), before, "Observation must not modify the database")
        XCTAssertNil(HermesActivity.date(Double.infinity, now: now))
        XCTAssertNil(HermesActivity.date(-1.0, now: now))
        XCTAssertNil(HermesActivity.date(now.timeIntervalSince1970 + 10000, now: now))
        XCTAssertTrue(HermesActivity.savedDates(profile: home.appendingPathComponent("missing").path, sessionIDs: ["s"], now: now).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("missing/state.db").path))
    }
}
