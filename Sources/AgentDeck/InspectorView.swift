import SwiftUI
import AppKit
import AgentDeckCore

struct InspectorView: View {
    @ObservedObject var store: DeckStore
    let record: AgentRecord
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var confirmInterrupt = false
    @State private var confirmExit = false
    @State private var followOutput = true
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                AnimatedAgentIcon(kind: record.pane.kind, status: record.status, size: 56)
                VStack(alignment: .leading, spacing: 7) {
                    Text(record.pane.title.isEmpty ? record.pane.project : record.pane.title).font(.system(size: 21, weight: .semibold)).lineLimit(2)
                    Text(record.pane.location).font(.system(size: 13)).foregroundStyle(DeckTheme.muted)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 28, height: 28) }.buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel("关闭详情")
            }.padding(26)
            HStack(spacing: 20) {
                StatusPill(status: record.status)
                Text(record.pane.currentWork ?? "暂无进行中的工作").font(.system(size: 14)).lineLimit(2)
                Spacer()
            }.padding(.horizontal, 26).padding(.bottom, 22)
            HStack(spacing: 26) {
                ContextMeter(usage: record.pane.contextUsage).frame(width: 210)
                if let used = record.pane.contextUsage?.used, let capacity = record.pane.contextUsage?.capacity {
                    Text("\(used.formatted()) / \(capacity.formatted()) tokens").font(.system(size: 13, design: .monospaced)).foregroundStyle(DeckTheme.muted)
                }
                Spacer()
                Button { store.terminal(record) } label: {
                    Label(record.pane.hermesSession == nil ? "打开 tmux" : "打开 Hermes", systemImage: "arrow.up.forward.app")
                }.buttonStyle(.bordered).disabled(!record.isPresent || store.demo || store.actionBusy)
                    .help(record.pane.hermesSession == nil ? "优先在已有终端定位这个 Agent 所在的 pane" : "打开 Hermes")
                Button { confirmExit = true } label: { Image(systemName: "power") }
                    .buttonStyle(.bordered).help("退出 Agent").accessibilityLabel("退出 Agent")
                    .disabled(!record.isPresent || store.demo || store.actionBusy)
            }.padding(.horizontal, 26).padding(.bottom, 24)
            HStack {
                Text("实时输出").font(.system(size: 13, weight: .medium))
                Spacer()
                Button { followOutput.toggle() } label: { Image(systemName: followOutput ? "arrow.down.to.line.compact" : "pause.circle") }.buttonStyle(.plain).help("跟随输出").accessibilityLabel("跟随输出")
                Menu {
                    Button(record.pane.hermesSession == nil ? "复制连接命令" : "复制会话 ID") { store.copyAttach(record) }
                    if !record.pane.directory.isEmpty { Button("在 Finder 中显示项目") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: record.pane.directory) } }
                    Button("复制输出") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(record.pane.output, forType: .string) }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24)
            }.foregroundStyle(DeckTheme.muted).padding(.horizontal, 26).padding(.bottom, 12)
            GeometryReader { geometry in
              ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(record.pane.output.isEmpty ? "暂无输出" : record.pane.output.trimmingCharacters(in: .newlines))
                            .font(.system(size: 13, design: .monospaced)).foregroundStyle(DeckTheme.text.opacity(0.8)).lineSpacing(5).textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
                    }.frame(minWidth: max(0, geometry.size.width - 48), minHeight: max(0, geometry.size.height - 48), alignment: .topLeading).padding(24).id("bottom")
                }.background(Color.black.opacity(0.18))
                    .onAppear { proxy.scrollTo("bottom", anchor: .bottomLeading) }
                    .onChange(of: record.pane.output) { _, _ in if followOutput { proxy.scrollTo("bottom", anchor: .bottomLeading) } }
              }
            }
            HStack(spacing: 12) {
                Button { confirmInterrupt = true } label: { Image(systemName: "stop.fill").frame(width: 30, height: 30) }
                    .buttonStyle(.plain).foregroundStyle(DeckTheme.muted).help("中断任务").accessibilityLabel("中断任务")
                    .disabled(!record.isPresent || record.pane.dead || store.actionBusy || store.demo)
                TextField(record.status == .waiting ? "在原应用中确认" : "发送消息…", text: $input).textFieldStyle(.plain).font(.system(size: 14)).onSubmit(send)
                    .disabled(!canSend)
                Button(action: send) { Image(systemName: "arrow.up").font(.system(size: 14, weight: .semibold)).foregroundStyle(DeckTheme.background).frame(width: 32, height: 32).background(DeckTheme.accent, in: RoundedRectangle(cornerRadius: 9)) }
                    .buttonStyle(.plain).disabled(input.isEmpty || !canSend).accessibilityLabel("发送消息")
            }.padding(14).background(DeckTheme.panel, in: RoundedRectangle(cornerRadius: 12)).padding(20)
        }.background(DeckTheme.background).foregroundStyle(DeckTheme.text).tint(DeckTheme.accent)
            .confirmationDialog("中断当前任务？", isPresented: $confirmInterrupt) {
                Button("中断任务", role: .destructive) { store.interrupt(record) }
            }
            .confirmationDialog("退出这个 Agent？", isPresented: $confirmExit) {
                Button("退出 Agent", role: .destructive) { store.exitAgent(record) }
            } message: {
                Text(record.pane.hermesSession == nil ? "结束当前任务，保留 tmux pane 并回到 shell。" : "关闭当前会话，保留聊天记录。")
            }
    }
    private var canSend: Bool { record.isPresent && !record.pane.dead && record.status != .waiting && !store.actionBusy && !store.demo }
    private func send() {
        guard canSend, !input.isEmpty else { return }
        let message = input
        store.send(message, to: record) { if input == message { input = "" } }
    }
}

struct SettingsView: View {
    @ObservedObject var store: DeckStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 22) {
            HStack { Text("偏好设置").font(.system(size: 22, weight: .semibold)); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
            if !store.errors.isEmpty { GroupBox("连接状态") { Text(store.errors.joined(separator: "\n")).foregroundStyle(.orange).textSelection(.enabled).padding(10) } }
            GroupBox("tmux 连接") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("tmux 路径（留空自动查找）", text: $store.tmuxPath)
                    Text("自动发现本机 tmux socket。自定义 socket 路径，每行一个：").foregroundStyle(DeckTheme.muted)
                    TextEditor(text: $store.extraSockets).font(.system(size: 11, design: .monospaced)).frame(height: 55)
                }.padding(10).textFieldStyle(.roundedBorder)
            }
            GroupBox("Hermes") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("GUI 会话通过本地 Gateway 自动发现。以下 hooks 用于经典 CLI，会备份配置并保留已有 hooks。").foregroundStyle(DeckTheme.muted).lineSpacing(3)
                    HStack { TextField("Hermes 配置目录", text: $store.hermesHome).textFieldStyle(.roundedBorder); Button("接入 CLI hooks") { store.installHermesHooks() }.disabled(store.actionBusy || store.demo) }
                    if let message = store.hermesSetupMessage { Text(message).foregroundStyle(DeckTheme.accent) }
                }.padding(10)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("状态如何判断").fontWeight(.semibold)
                Text("只有会话结束事件、完成 hook 或正常退出才标记完成。输出暂停、输入提示符和界面重绘不会标记完成；暂时无法读取时保留上次状态。关闭 App 不会停止任何 Agent。").foregroundStyle(DeckTheme.muted).lineSpacing(4)
                Text("终端内容只保留在内存；事件记录仅保存状态和项目名称。支持本机 tmux 和 Hermes GUI；Context 读取实际接口、会话日志和终端状态栏。").foregroundStyle(DeckTheme.muted).lineSpacing(4)
            }
        }.font(.system(size: 12)).padding(28) }.frame(width: 625, height: 510).background(DeckTheme.background).preferredColorScheme(.dark).tint(DeckTheme.accent)
    }
}
