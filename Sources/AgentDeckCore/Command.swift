import Foundation
import Darwin

public struct CommandResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
}

public enum DeckError: LocalizedError {
    case message(String)
    public var errorDescription: String? { switch self { case .message(let message): message } }
}

public enum Command {
    public static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = [env["PATH"] ?? "", "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        return env
    }
    public static func find(_ name: String) -> String? {
        if name.contains("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        return (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    public static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 8, input: Data? = nil, environment overrides: [String: String] = [:]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment.merging(overrides) { _, new in new }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out; process.standardError = err
        let stdin = input == nil ? nil : Pipe()
        process.standardInput = stdin ?? FileHandle.nullDevice as Any
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if let stdin, let input {
            DispatchQueue.global(qos: .utility).async {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
        }
        let group = DispatchGroup()
        let stdout = LockedData(), stderr = LockedData()
        for (pipe, data) in [(out, stdout), (err, stderr)] {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                data.set(pipe.fileHandleForReading.readDataToEndOfFile())
                group.leave()
            }
        }
        let timedOut = done.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 0.5) == .timedOut { kill(process.processIdentifier, SIGKILL); _ = done.wait(timeout: .now() + 1) }
        }
        // Children must not keep the app waiting indefinitely on inherited pipes.
        _ = group.wait(timeout: .now() + 1)
        if timedOut { throw DeckError.message("命令超时：\(URL(fileURLWithPath: executable).lastPathComponent)") }
        return CommandResult(status: process.terminationStatus, stdout: stdout.string, stderr: stderr.string)
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
