#if DEBUG
import Foundation
import AppKit
import AgentDeckCore

@MainActor
enum RuntimeVerification {
    static var started = false
    static func startIfRequested(store: DeckStore) {
        guard !started, let index = CommandLine.arguments.firstIndex(of: "--verify-runtime"), CommandLine.arguments.indices.contains(index + 1) else { return }
        started = true
        let reportPath = CommandLine.arguments[index + 1]
        Task {
            var checks = [String: String]()
            let root = URL(fileURLWithPath: "/private/tmp/ad-ui-" + String(UUID().uuidString.prefix(8)))
            let socket = root.appendingPathComponent("socket").path
            let client = store.tmux
            do {
                guard ProcessInfo.processInfo.environment["AGENTDECK_DATA_DIR"] != nil, !store.demo else { throw DeckError.message("Runtime verification requires an isolated AGENTDECK_DATA_DIR") }
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let helper = store.helper
                let boot = try await Task.detached { try Command.run(client.executable, ["-f", "/dev/null", "-S", socket, "new-session", "-d", "-s", "verification"]) }.value
                guard boot.status == 0 else { throw DeckError.message(boot.stderr) }
                let script = root.appendingPathComponent("agent.sh")
                try """
                #!/bin/sh
                printf 'AgentDeck verification ready\\n'
                IFS= read -r message
                printf 'Received: %s\\n' "$message"
                \(Command.quote(helper)) event --state completed
                sleep 20
                """.write(to: script, atomically: true, encoding: .utf8)
                let request = LaunchRequest(kind: .custom, directory: root.path, title: "Runtime verification", executable: "/bin/sh", arguments: [script.path])
                _ = try await Task.detached { try Launch.create(request, tmux: client, helper: helper, socket: socket) }.value
                store.runtimeSockets = [socket]
                var record: AgentRecord?
                for _ in 0..<30 {
                    await store.refresh()
                    record = store.records.first { $0.pane.title == "Runtime verification" && $0.pane.output.contains("verification ready") }
                    if record != nil { break }
                    try await Task.sleep(for: .milliseconds(200))
                }
                guard let record else { throw DeckError.message("Native store did not discover test agent") }
                checks["discovery"] = "passed"
                store.openAgent(record.id)
                try await Task.sleep(for: .milliseconds(400))
                @MainActor func messageField(in view: NSView) -> NSTextField? {
                    if let field = view as? NSTextField, field.placeholderString == "发送消息…" { return field }
                    for child in view.subviews { if let field = messageField(in: child) { return field } }
                    return nil
                }
                guard let main = NSApp.windows.first(where: { $0.title == "AgentDeck" && $0.styleMask.contains(.titled) }),
                      let sheet = main.attachedSheet, let content = sheet.contentView,
                      let field = messageField(in: content) else { throw DeckError.message("Message input field missing") }
                sheet.makeFirstResponder(field)
                guard let editor = field.currentEditor() as? NSTextView else { throw DeckError.message("Message input did not receive focus") }
                editor.insertText("literal 'input' $(not-a-command)", replacementRange: NSRange(location: NSNotFound, length: 0))
                try await Task.sleep(for: .milliseconds(100))
                guard let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else { throw DeckError.message("Could not create Return key") }
                sheet.sendEvent(enter)
                for _ in 0..<40 {
                    await store.refresh()
                    if store.records.first(where: { $0.id == record.id })?.lastEvent?.status == .completed { break }
                    try await Task.sleep(for: .milliseconds(200))
                }
                guard let updated = store.records.first(where: { $0.id == record.id }), updated.pane.output.contains("literal 'input' $(not-a-command)") else { throw DeckError.message("Native send action failed") }
                checks["literalInput"] = "passed"
                guard field.stringValue.isEmpty else { throw DeckError.message("Submitted message was not cleared") }
                checks["returnSubmitsMessage"] = "passed"
                guard let finished = updated.lastEvent, finished.status == .completed else { throw DeckError.message("Expected a precise completion state") }
                checks["completionState"] = "passed"
                store.openAgent(record.id)
                guard store.showDetail, store.selected?.id == record.id else { throw DeckError.message("Opened the wrong card") }
                checks["detailRouting"] = "passed"
                store.showDetail = false
                await store.refresh()
                guard store.records.first(where: { $0.id == record.id })?.lastEventID == finished.id else { throw DeckError.message("Completion state changed unexpectedly") }
                checks["deduplication"] = "passed"
                let saved = EventStore().load(SavedState.self, name: "state.json")
                guard saved?.seen.contains(finished.id) == true else { throw DeckError.message("Event cursor was not persisted") }
                checks["persistence"] = "passed"
                guard let floating = store.floatingController else { throw DeckError.message("Floating controller missing") }
                let snapshot = URL(fileURLWithPath: reportPath).deletingLastPathComponent().appendingPathComponent("floating-runtime.png")
                checks.merge(try await floating.verifyBehavior(snapshot: snapshot)) { _, new in new }
                checks["result"] = "passed"
            } catch { checks["result"] = "failed"; checks["error"] = error.localizedDescription }
            _ = try? await Task.detached { try client.call(["kill-server"], socket: socket) }.value
            try? FileManager.default.removeItem(at: root)
            if let data = try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: reportPath), options: .atomic) }
            NSApp.terminate(nil)
        }
    }
}
#endif
