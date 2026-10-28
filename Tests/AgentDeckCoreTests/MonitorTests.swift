import XCTest
@testable import AgentDeckCore

final class MonitorTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    func pane(_ output: String = "", pid: Int = 20, kind: AgentKind = .codex) -> Pane {
        Pane(socket: "/tmp/deck-test", serverPID: 10, session: "project", window: "1", paneID: "%1", pid: pid, command: kind.rawValue, directory: "/tmp/project", kind: kind, output: output)
    }
    func scan(_ panes: [Pane], success: Bool = true) -> ScanResult {
        ScanResult(panes: panes, errors: success ? [] : ["Disconnected"], successfulSockets: success ? ["/tmp/deck-test"] : [], socketCount: 1)
    }
    func testSilenceIsNotCompletion() {
        var monitor = Monitor()
        let p = pane("Thinking…")
        _ = monitor.ingest(scan([p]), events: [], now: start)
        let result = monitor.ingest(scan([p]), events: [], now: start.addingTimeInterval(46))
        XCTAssertEqual(monitor.records[p.id]?.status, .idle)
        XCTAssertEqual(result.map(\.status), [.idle])
        XCTAssertFalse(result.contains { $0.status == .completed })
    }
    func testBusyFooterBeatsAlwaysVisibleCodexPrompt() {
        let signal = ScreenSignal.read("• Working (2m • esc to interrupt)\n\n› Ask Codex to do anything\nGPT-6", kind: .codex)
        XCTAssertEqual(signal?.status, .working)
    }
    func testQueuedQuestionsOverrideWorkingAndResolve() {
        var monitor = Monitor()
        for count in [1, 2] {
            var p = pane("• Working (1m 56s • esc to interrupt)\n• Queued follow-up inputs\n  ? \(count) question\(count == 1 ? "" : "s")\n    ⌥e to answer\n› Ask Codex to do anything")
            _ = monitor.ingest(scan([p]), events: [], now: start)
            XCTAssertEqual(monitor.records[p.id]?.status, .waiting)
            p.output = "• Working (esc to interrupt)\n› Ask Codex to do anything"
            _ = monitor.ingest(scan([p]), events: [], now: start.addingTimeInterval(2))
            XCTAssertEqual(monitor.records[p.id]?.status, .working)
        }
    }
    func testHistoricalQuestionsAndQueuedMessagesDoNotLookLikeWaiting() {
        let old = "Queued follow-up inputs\n? 1 question\n⌥e to answer\n" + Array(repeating: "output", count: 20).joined(separator: "\n")
        XCTAssertEqual(ScreenSignal.read(old + "\nWorking (esc to interrupt)", kind: .codex)?.status, .working)
        XCTAssertEqual(ScreenSignal.read("Working (esc to interrupt)\nQueued follow-up inputs\n1 message\n⌥e to edit", kind: .codex)?.status, .working)
        XCTAssertEqual(ScreenSignal.read("Working (esc to interrupt)\nQueued follow-up inputs\n0 questions\n⌥e to answer", kind: .codex)?.status, .working)
    }
    func testNewQuestionOverridesPreviousCompletionGracePeriod() {
        var monitor = Monitor(); var p = pane("› prompt")
        let event = AgentEvent(paneKey: p.id, date: start, status: .completed, summary: "Done")
        _ = monitor.ingest(scan([p]), events: [event], now: start)
        p.output = "Working (esc to interrupt)\nQueued follow-up inputs\n? 1 question\n⌥e to answer"
        _ = monitor.ingest(scan([p]), events: [event], now: start.addingTimeInterval(1))
        XCTAssertEqual(monitor.records[p.id]?.status, .waiting)
    }
    func testReadyAtInitialDiscoveryDoesNotClaimCompletion() {
        var monitor = Monitor(); let p = pane("› Ask Codex to do anything")
        XCTAssertTrue(monitor.ingest(scan([p]), events: [], now: start).isEmpty)
        XCTAssertEqual(monitor.records[p.id]?.status, .idle)
    }
    func testWorkingToPromptNotifiesExactlyOnce() {
        var monitor = Monitor(); var p = pane("• Working (esc to interrupt)\n› prompt")
        _ = monitor.ingest(scan([p]), events: [], now: start)
        p.output = "Finished all tests.\n› prompt"
        XCTAssertEqual(monitor.ingest(scan([p]), events: [], now: start.addingTimeInterval(2)).map(\.status), [.completed])
        XCTAssertTrue(monitor.ingest(scan([p]), events: [], now: start.addingTimeInterval(4)).isEmpty)
    }
    func testPermissionRequestAndResolution() {
        var monitor = Monitor(); var p = pane("Do you want to proceed?\n❯ 1. Yes\n2. No", kind: .claude)
        XCTAssertEqual(monitor.ingest(scan([p]), events: [], now: start).map(\.status), [.waiting])
        p.output = "Working… (esc to interrupt)"
        _ = monitor.ingest(scan([p]), events: [], now: start.addingTimeInterval(3))
        XCTAssertEqual(monitor.records[p.id]?.status, .working)
    }
    func testOldPromptInScrollbackDoesNotOverrideCurrentWork() {
        let output = "Do you want to proceed?\n" + Array(repeating: "output", count: 30).joined(separator: "\n") + "\nWorking (esc to interrupt)"
        XCTAssertEqual(ScreenSignal.read(output, kind: .claude)?.status, .working)
    }
    func testFreshHookSurvivesTrailingBusyScreen() {
        var monitor = Monitor(); let p = pane("Working (esc to interrupt)")
        _ = monitor.ingest(scan([p]), events: [], now: start)
        let event = AgentEvent(paneKey: p.id, date: start.addingTimeInterval(2), status: .completed, summary: "Done")
        _ = monitor.ingest(scan([p]), events: [event], now: start.addingTimeInterval(2))
        XCTAssertEqual(monitor.records[p.id]?.status, .completed)
        _ = monitor.ingest(scan([p]), events: [event], now: start.addingTimeInterval(4))
        XCTAssertEqual(monitor.records[p.id]?.status, .completed)
        _ = monitor.ingest(scan([p]), events: [event], now: start.addingTimeInterval(30))
        XCTAssertEqual(monitor.records[p.id]?.status, .completed)
    }
    func testNewTurnAfterHookCompletion() {
        var monitor = Monitor(); var p = pane("› prompt")
        let event = AgentEvent(paneKey: p.id, date: start, status: .completed, summary: "Done")
        _ = monitor.ingest(scan([p]), events: [event], now: start)
        p.output = "Working (esc to interrupt)"
        _ = monitor.ingest(scan([p]), events: [event], now: start.addingTimeInterval(5))
        XCTAssertEqual(monitor.records[p.id]?.status, .working)
    }
    func testDeadProcessExitCode() {
        for (exit, expected) in [(0, AgentStatus.completed), (1, .failed)] {
            var monitor = Monitor(); var p = pane("working")
            _ = monitor.ingest(scan([p]), events: [], now: start)
            p.dead = true; p.exitCode = exit
            XCTAssertEqual(monitor.ingest(scan([p]), events: [], now: start.addingTimeInterval(3)).map(\.status), [expected])
        }
    }
    func testDisconnectedScanDoesNotClaimAgentExited() {
        var monitor = Monitor(); let p = pane("Working (esc to interrupt)")
        _ = monitor.ingest(scan([p]), events: [], now: start)
        XCTAssertTrue(monitor.ingest(scan([], success: false), events: [], now: start.addingTimeInterval(2)).isEmpty)
        XCTAssertEqual(monitor.records[p.id]?.status, .working)
        XCTAssertEqual(monitor.ingest(scan([]), events: [], now: start.addingTimeInterval(4)).map(\.status), [.offline])
    }
    func testCaptureFailureIsNotCompletion() {
        var monitor = Monitor(); var p = pane("Working (esc to interrupt)")
        _ = monitor.ingest(scan([p]), events: [], now: start)
        p.captureOK = false; p.output = ""
        XCTAssertTrue(monitor.ingest(scan([p]), events: [], now: start.addingTimeInterval(60)).isEmpty)
        XCTAssertEqual(monitor.records[p.id]?.status, .unknown)
    }
    func testPaneReuseDoesNotInheritOldCompletion() {
        var monitor = Monitor(); let old = pane(), new = pane("› prompt", pid: 21)
        let event = AgentEvent(paneKey: old.id, date: start, status: .completed, summary: "Done")
        _ = monitor.ingest(scan([new]), events: [event], now: start)
        XCTAssertEqual(monitor.records[new.id]?.status, .idle)
    }
    func testAgentReturningToShellIsNotCompletion() {
        var monitor = Monitor(); var p = pane("Working (esc to interrupt)")
        _ = monitor.ingest(scan([p]), events: [], now: start)
        p.agentRunning = false; p.command = "zsh"; p.output = "$"
        _ = monitor.ingest(scan([p]), events: [], now: start.addingTimeInterval(2))
        XCTAssertEqual(monitor.records[p.id]?.status, .offline)
    }
    func testNewestHookWinsEvenWithUnorderedFiles() {
        var monitor = Monitor(); let p = pane()
        let completed = AgentEvent(paneKey: p.id, date: start, status: .completed, summary: "Done")
        let working = AgentEvent(paneKey: p.id, date: start.addingTimeInterval(1), status: .working, summary: "Next")
        _ = monitor.ingest(scan([p]), events: [working, completed], now: start.addingTimeInterval(2))
        XCTAssertEqual(monitor.records[p.id]?.status, .working)
    }
}
