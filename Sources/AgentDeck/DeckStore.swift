import AppKit
import SwiftUI
import AgentDeckCore

struct SavedState: Codable {
    var seen: Set<String> = []
}

@MainActor
final class DeckStore: NSObject, ObservableObject {
    @Published var records: [AgentRecord] = []
    @Published var selection: String?
    @Published var errors: [String] = []
    @Published var lastRefresh: Date?
    @Published var refreshing = false
    @Published var actionBusy = false
    @Published var actionError: String?
    @Published var socketCount = 0
    @Published var showSettings = false
    @Published var showDetail = false
    @Published var hermesSetupMessage: String?
    @AppStorage("tmuxPath") var tmuxPath = ""
    @AppStorage("extraSockets") var extraSockets = ""
    @AppStorage("hermesHome") var hermesHome = "~/.hermes"
    private var monitor = Monitor()
    private let hermesGateway = HermesGateway()
    private var seen = Set<String>()
    private var loadedEvents = false
    private var latestEvents: [String: AgentEvent] = [:]
    private let persistence = EventStore()
    private var polling: Task<Void, Never>?
    var runtimeSockets: [String] = []
    let demo: Bool
    var hasAppBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    var onReveal: (() -> Void)?

    init(demo: Bool = false) {
        self.demo = demo
        super.init()
        if demo { loadDemo(); return }
        let saved = persistence.load(SavedState.self, name: "state.json") ?? SavedState()
        seen = saved.seen
        polling = Task { [weak self] in
            await Task.detached(priority: .utility) { EventStore().prune() }.value
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
    var tmux: Tmux { Tmux(executable: tmuxPath.isEmpty ? nil : tmuxPath) }
    var helper: String {
        if hasAppBundle { return Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/agentdeckctl").path }
        return URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("agentdeckctl").path
    }
    var live: [AgentRecord] { records.filter { $0.isPresent && $0.status != .offline } }
    var selected: AgentRecord? { records.first { $0.id == selection } }
    var visible: [AgentRecord] {
        records.filter { $0.isPresent && $0.status != .offline }.sorted {
            let order: [AgentStatus: Int] = [.waiting: 0, .working: 1, .failed: 2, .completed: 3, .idle: 4, .unknown: 5, .offline: 6]
            let a = order[$0.status] ?? 7, b = order[$1.status] ?? 7
            return a == b ? $0.id.localizedStandardCompare($1.id) == .orderedAscending : a < b
        }
    }
    func refresh() async {
        guard !demo, !refreshing else { return }
        refreshing = true
        let client = tmux, extras = extraSockets.components(separatedBy: .newlines).filter { !$0.isEmpty } + runtimeSockets
        let tracked = Dictionary(uniqueKeysWithValues: records.filter { $0.pane.hermesSession == nil }.map { ($0.id, $0.pane.kind) })
        let disk = persistence
        let excluded = loadedEvents ? seen : []
        async let guiScan = hermesGateway.scan(home: hermesHome)
        var (scan, events) = await Task.detached(priority: .utility) {
            (client.scan(extraSockets: extras, tracked: tracked), disk.read(excluding: excluded))
        }.value
        let gui = await guiScan
        scan.panes += gui.panes; scan.errors += gui.errors
        scan.successfulSockets.formUnion(gui.successfulSources); events += gui.events
        errors = scan.errors; socketCount = scan.socketCount
        for event in events where latestEvents[event.paneKey].map({ $0.date <= event.date }) ?? true { latestEvents[event.paneKey] = event }
        _ = monitor.ingest(scan, events: Array(latestEvents.values))
        records = Array(monitor.records.values)
        let incoming = events.filter { !seen.contains($0.id) }
        if !loadedEvents { seen.formIntersection(Set(events.map(\.id))); loadedEvents = true }
        seen.formUnion(incoming.map(\.id))
        if !incoming.isEmpty { persist() }
        if selection == nil { selection = visible.first?.id }
        lastRefresh = Date(); refreshing = false
    }
    func persist() {
        guard !demo else { return }
        do { try persistence.save(SavedState(seen: seen), name: "state.json") }
        catch { actionError = "无法保存会话状态：\(error.localizedDescription)" }
    }
    private(set) var floatingController: FloatingAgentsController?
    func startFloating() {
        guard floatingController == nil else { return }
        floatingController = FloatingAgentsController(store: self)
        floatingController?.start()
    }
    func openMain() {
        onReveal?()
        if let window = NSApp.windows.first(where: { $0.title == "AgentDeck" && $0.styleMask.contains(.titled) }) {
            window.deminiaturize(nil); window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    func openAgent(_ id: String) {
        selection = id; showDetail = records.contains { $0.id == id }; openMain()
    }
    func perform(_ action: @escaping @Sendable () throws -> Void, then: (() -> Void)? = nil) {
        guard !demo, !actionBusy else { return }
        actionBusy = true
        Task {
            do { try await Task.detached(priority: .userInitiated) { try action() }.value; then?() }
            catch { actionError = error.localizedDescription }
            actionBusy = false
            await refresh()
        }
    }
    func send(_ text: String, to record: AgentRecord, onSuccess: (() -> Void)? = nil) {
        if let ref = record.pane.hermesSession {
            performAsync { try await self.hermesGateway.send(text, to: ref); self.monitor.sentInput(record.id); onSuccess?() }
            return
        }
        let client = tmux, pane = record.pane
        perform({ try client.send(text, to: pane) }) { self.monitor.sentInput(pane.id); self.records = Array(self.monitor.records.values); onSuccess?() }
    }
    func interrupt(_ record: AgentRecord) {
        if let ref = record.pane.hermesSession {
            performAsync { try await self.hermesGateway.interrupt(ref) }; return
        }
        let client = tmux, pane = record.pane
        perform { try client.interrupt(pane) }
    }
    func terminal(_ record: AgentRecord) {
        if record.pane.hermesSession != nil {
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == "Hermes" }) {
                app.activate(options: []); return
            }
            actionError = "Hermes GUI 未运行。请打开 Hermes 后选择这个会话。"; return
        }
        let pane = record.pane, client = tmux
        perform {
            try client.validate(pane)
            // Connect to the existing session and select the requested pane.
            let command = [client.executable, "-S", pane.socket, "attach-session", "-t", pane.session, ";", "select-window", "-t", pane.paneID, ";", "select-pane", "-t", pane.paneID].map(Command.quote).joined(separator: " ")
            let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
            let result = try Command.run("/usr/bin/osascript", ["-e", "tell application \"Terminal\"\nactivate\ndo script \"\(escaped)\"\nend tell"])
            if result.status != 0 { throw DeckError.message("无法打开 Terminal：\(result.stderr)\n可使用「复制连接命令」。") }
        }
    }
    func copyAttach(_ record: AgentRecord) {
        if let ref = record.pane.hermesSession {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(ref.sessionID, forType: .string); return
        }
        let command = [tmux.executable, "-S", record.pane.socket, "attach-session", "-t", record.pane.session].map(Command.quote).joined(separator: " ")
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string)
    }
    private func performAsync(_ action: @escaping @MainActor () async throws -> Void) {
        guard !demo, !actionBusy else { return }
        actionBusy = true
        Task {
            do { try await action() } catch { actionError = error.localizedDescription }
            actionBusy = false; await refresh()
        }
    }
    func installHermesHooks() {
        let home = (hermesHome as NSString).expandingTildeInPath, helper = helper
        let script = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/install-hermes-hooks.py").path
        let destination = persistence.root.appendingPathComponent("bin/agentdeckctl").path
        perform({
            guard let executable = Command.find("hermes") else { throw DeckError.message("找不到 Hermes，请先安装 Hermes。") }
            let python = try Hermes.installerPython(executable: executable)
            let result = try Command.run(python, [script, home, helper, destination], timeout: 15)
            guard result.status == 0 else { throw DeckError.message(result.stderr) }
        }) { self.hermesSetupMessage = "已接入。原配置已备份；下次启动 Hermes 时请批准这四个观察 hooks。" }
    }
    private func loadDemo() {
        let samples: [(AgentKind, String, String, AgentStatus, String)] = [
            (.codex, "支付服务重构", "payments-api", .working, "• Running swift test\n• Working (2m 18s • esc to interrupt)\n\n› Ask Codex to do anything"),
            (.claude, "修复登录重定向", "dashboard", .waiting, "Claude needs your permission\n\nDo you want to proceed?\n❯ 1. Yes\n  2. No"),
            (.hermes, "整理 API 文档", "developer-docs", .working, "✓ Updated 12 API reference pages\n✓ All internal links checked\n\n文档已更新，新增了鉴权示例和错误码说明。\n\nYou ❯"),
            (.codex, "增加回归测试", "payments-api", .completed, "All 28 tests passed.\n\n› Ask Codex to do anything"),
            (.claude, "检查依赖升级", "web-client", .idle, "Dependency review ready.\n❯")
        ]
        records = samples.enumerated().map { index, value in
            var pane = Pane(socket: "/tmp/demo", serverPID: 1, session: "workspace", window: "\(index + 1)", paneID: "%\(index)", pid: index + 1, command: value.0.rawValue, directory: "/Projects/\(value.2)", title: value.1, kind: value.0, output: value.4)
            pane.contextUsage = ContextUsage(used: [48640, 132000, 28700, 102400, 38000][index], capacity: index == 0 || index == 3 ? 256000 : 200000, source: "演示数据")
            pane.currentWork = ["运行支付模块的回归测试", "需要批准修改 auth/callback.ts", "读取 API 定义，补充鉴权示例", "28 项测试全部通过", "等待下一项任务"][index]
            var record = AgentRecord(pane: pane, now: Date().addingTimeInterval(-Double(40 + index * 55)))
            record.status = value.3; record.reason = value.3 == .completed ? "Agent 已确认完成 · 精确事件" : "实时终端状态"
            return record
        }
        selection = nil
        socketCount = 1; lastRefresh = Date()
    }
}
