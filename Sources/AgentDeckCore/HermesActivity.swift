import Foundation
import SQLite3

enum HermesActivity {
    static let visibilityInterval: TimeInterval = 10 * 60

    struct Observation {
        var date: Date
        var status: AgentStatus
        var messageCount: Int?

        mutating func update(saved: Date?, status: AgentStatus, messageCount: Int?, newEvent: Bool, now: Date) {
            let messagesChanged = self.messageCount != nil && messageCount != nil && self.messageCount != messageCount
            if newEvent || self.status != status || messagesChanged { date = now }
            if let saved { date = max(date, saved) }
            self.status = status; self.messageCount = messageCount
        }
    }

    static func isInteraction(_ type: String) -> Bool {
        ["message.", "reasoning.", "thinking.", "tool.", "approval.", "clarify.", "subagent."].contains(where: type.hasPrefix)
            || ["agent.print", "agent.terminal.output", "voice.transcript"].contains(type)
    }

    static func date(_ value: Any?, now: Date) -> Date? {
        guard let seconds = value as? Double, seconds.isFinite, seconds > 0,
              seconds <= now.timeIntervalSince1970 + 60 else { return nil }
        return min(Date(timeIntervalSince1970: seconds), now)
    }

    /// Read timestamps only, for sessions already authenticated by the Gateway.
    /// Its active_list.last_active can be just the creation time. A local receipt
    /// points to the current physical transcript after resume/reset/compaction.
    static func savedDates(profile: String, sessionIDs: [String], now: Date) -> [String: Date] {
        guard profile.hasPrefix("/"), !sessionIDs.isEmpty else { return [:] }
        let database = URL(fileURLWithPath: profile).appendingPathComponent("state.db")
        var connection: OpaquePointer?
        guard sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let connection { sqlite3_close(connection) }; return [:]
        }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 100)
        let sql = """
        WITH targets(id) AS (
            SELECT ?1 UNION SELECT CASE WHEN json_valid(value) THEN json_extract(value, '$.entry.session_id') END
            FROM state_meta WHERE key = 'gateway.local_policy.v1:' || ?1
        ), stamps(value) AS (
            SELECT started_at FROM sessions WHERE id IN targets
            UNION ALL SELECT last_activity_at FROM sessions WHERE id IN targets
            UNION ALL SELECT MAX(timestamp) FROM messages WHERE session_id IN targets
                AND typeof(timestamp) IN ('integer', 'real') AND timestamp > 0 AND timestamp <= ?2
        )
        SELECT MAX(value) FROM stamps
        WHERE typeof(value) IN ('integer', 'real') AND value > 0 AND value <= ?2
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var result = [String: Date]()
        for id in sessionIDs {
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            guard sqlite3_bind_text(statement, 1, id, -1, transient) == SQLITE_OK,
                  sqlite3_bind_double(statement, 2, now.timeIntervalSince1970 + 60) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL,
                  let date = date(sqlite3_column_double(statement, 0), now: now) else { continue }
            result[id] = date
        }
        return result
    }
}
