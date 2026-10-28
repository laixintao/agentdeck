import Foundation
import SQLite3

/// Resolves a Codex TUI through its own terminal title, even when its daemon is shared.
enum CodexSessionIndex {
    struct Session: Equatable {
        var id: String
        var rollout: URL
    }

    static func resolve(title: String?, directory: String, root: URL) -> Session? {
        guard let name = threadName(title: title, directory: directory) else { return nil }
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let databases = files.compactMap { file -> (Int, URL)? in
            let name = file.lastPathComponent
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite"),
                  let version = Int(name.dropFirst(6).dropLast(7)) else { return nil }
            return (version, file)
        }
        guard let database = databases.max(by: { $0.0 < $1.0 })?.1 else { return nil }
        var connection: OpaquePointer?
        guard sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let connection { sqlite3_close(connection) }; return nil
        }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 100)
        var statement: OpaquePointer?
        // Bind the title: session names can contain quotes and SQL punctuation.
        guard sqlite3_prepare_v2(connection, "SELECT id, cwd, rollout_path FROM threads WHERE name = ? AND archived = 0 LIMIT 101", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, name, -1, transient) == SQLITE_OK else { return nil }
        func column(_ index: Int32) -> String? {
            guard let value = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: value)
        }
        let cwd = URL(fileURLWithPath: directory).resolvingSymlinksInPath().standardizedFileURL.path
        var candidates = [Session](), count = 0
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { return nil }
            count += 1
            guard count <= 100 else { return nil }
            guard let id = column(0), let path = column(1), let rollout = column(2),
                  URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path == cwd else { continue }
            guard UUID(uuidString: id) != nil else { return nil }
            candidates.append(Session(id: id, rollout: URL(fileURLWithPath: rollout)))
        }
        // Never choose the newest of several same-directory, same-name sessions.
        guard candidates.count == 1, let session = candidates.first else { return nil }
        let path = session.rollout.resolvingSymlinksInPath().standardizedFileURL
        let sessions = root.appendingPathComponent("sessions").resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard path.path.hasPrefix(sessions), path.lastPathComponent.hasPrefix("rollout-"),
              path.lastPathComponent.hasSuffix("\(session.id).jsonl"),
              let metadata = metadata(path), metadata["id"] as? String == session.id,
              let loggedDirectory = metadata["cwd"] as? String,
              URL(fileURLWithPath: loggedDirectory).resolvingSymlinksInPath().standardizedFileURL.path == cwd else { return nil }
        return Session(id: session.id, rollout: path)
    }

    static func threadName(title: String?, directory: String) -> String? {
        guard var title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !directory.isEmpty else { return nil }
        let suffix = " | " + URL(fileURLWithPath: directory).lastPathComponent
        guard title.hasSuffix(suffix) else { return nil }
        title.removeLast(suffix.count)
        // Codex prefixes its active title with a braille spinner. Removing the
        // spinner only resolves identity; it is never a completion signal.
        if let first = title.unicodeScalars.first, (0x2800...0x28ff).contains(first.value), title.dropFirst().hasPrefix(" ") {
            title = String(title.dropFirst(2))
        }
        return title.isEmpty ? nil : title
    }

    private static func metadata(_ url: URL) -> [String: Any]? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 512_000), let end = data.firstIndex(of: 10),
              let row = try? JSONSerialization.jsonObject(with: data[..<end]) as? [String: Any],
              row["type"] as? String == "session_meta" else { return nil }
        return row["payload"] as? [String: Any]
    }
}
