import Foundation

public struct EventStore: Sendable {
    public var root: URL
    public init(root: URL? = nil) {
        self.root = root ?? ProcessInfo.processInfo.environment["AGENTDECK_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AgentDeck")
    }
    public var eventsDirectory: URL { root.appendingPathComponent("events") }
    public func write(_ event: AgentEvent) throws {
        try FileManager.default.createDirectory(at: eventsDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = eventsDirectory.appendingPathComponent(event.id + ".json")
        try JSONEncoder().encode(event).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    public func read(excluding ids: Set<String> = []) -> [AgentEvent] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: eventsDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "json" && !ids.contains($0.deletingPathExtension().lastPathComponent) }.compactMap { url -> AgentEvent? in
            guard let attrs = try? url.resourceValues(forKeys: [.fileSizeKey]), (attrs.fileSize ?? 0) < 65536,
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(AgentEvent.self, from: data)
        }.sorted { $0.date < $1.date }
    }
    public func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-7 * 86400)
        for event in read() where event.date < cutoff {
            // Only delete our UUID-named event files.
            guard UUID(uuidString: event.id) != nil else { continue }
            try? FileManager.default.removeItem(at: eventsDirectory.appendingPathComponent(event.id + ".json"))
        }
    }
    public func save<T: Encodable>(_ value: T, name: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = root.appendingPathComponent(name)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func load<T: Decodable>(_ type: T.Type, name: String) -> T? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
