import SwiftUI
import AppKit
import AgentDeckCore

struct ContentView: View {
    @ObservedObject var store: DeckStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(spacing: 0) {
            header
            agents
        }
        .background(DeckTheme.background).foregroundStyle(DeckTheme.text)
        .tint(DeckTheme.accent).preferredColorScheme(.dark)
        .frame(minWidth: 800, minHeight: 540)
        .onAppear { store.onReveal = { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) } }
        .sheet(isPresented: $store.showSettings) { SettingsView(store: store) }
        .sheet(isPresented: $store.showDetail) {
            if let record = store.selected {
                InspectorView(store: store, record: record).id(record.id)
                    .frame(width: 760, height: 700).preferredColorScheme(.dark)
            }
        }
        .alert("操作未完成", isPresented: Binding(get: { store.actionError != nil }, set: { if !$0 { store.actionError = nil } })) {
            Button("好", role: .cancel) { store.actionError = nil }
        } message: { Text(store.actionError ?? "") }
    }
    private var header: some View {
        HStack(spacing: 18) {
            Text("AgentDeck").font(.system(size: 20, weight: .semibold, design: .rounded))
            if store.demo { Text("演示").font(.system(size: 12)).foregroundStyle(DeckTheme.muted) }
            Spacer()
            Button { store.showSettings = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 28, height: 28) }
                .buttonStyle(.plain).foregroundStyle(store.errors.isEmpty ? DeckTheme.muted : AgentStatus.waiting.color).help(store.errors.isEmpty ? "设置" : store.errors.joined(separator: "\n")).accessibilityLabel("设置")
        }.padding(.horizontal, 28).padding(.top, 30).padding(.bottom, 22)
    }
    private var agents: some View {
        VStack(alignment: .leading, spacing: 24) {
            if store.visible.isEmpty {
                VStack(spacing: 18) {
                    Image(systemName: "square.grid.2x2").font(.system(size: 32, weight: .light)).foregroundStyle(DeckTheme.muted)
                    Text("暂无 Agent").font(.system(size: 17, weight: .medium))
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 214, maximum: 310), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                        ForEach(store.visible) { record in
                            AgentCard(record: record) { store.selection = record.id; store.showDetail = true }
                        }
                    }.padding(2).padding(.bottom, 28)
                }.scrollIndicators(.hidden)
            }
        }.padding(.horizontal, 26).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct AgentCard: View {
    let record: AgentRecord
    var onOpen: () -> Void
    @State private var hovered = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    AnimatedAgentIcon(kind: record.pane.kind, status: record.status, size: 44)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(record.pane.title.isEmpty ? record.pane.project : record.pane.title)
                            .font(.system(size: 14, weight: .semibold)).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 48)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).help(record.status.title + " · 查看详情")
                .accessibilityLabel("\(record.pane.kind.title)，\(record.status.title)，查看详情")
            LiveOutputPreview(output: record.pane.previewOutput ?? TerminalTelemetry.preview(record.pane.output))
            ContextMeter(usage: record.pane.contextUsage)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).frame(height: 296)
            .background(hovered ? DeckTheme.panel : DeckTheme.surface, in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(record.status == .waiting || record.status == .failed ? record.status.color.opacity(0.4) : DeckTheme.line, lineWidth: 1))
            .onHover { hovered = $0 }
    }
}

struct LiveOutputPreview: View {
    let output: String
    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                      Text(output.isEmpty ? "—" : output)
                        .font(.system(size: 10, design: .monospaced)).lineSpacing(3)
                        .foregroundStyle(DeckTheme.text.opacity(0.74)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: max(0, geometry.size.height - 20), alignment: .topLeading)
                        .padding(10)
                      Color.clear.frame(height: 1).id("latest-output")
                    }
                }.scrollIndicators(.hidden).defaultScrollAnchor(.bottom)
                    .onAppear { proxy.scrollTo("latest-output", anchor: .bottom) }
                    .onChange(of: output) { _, _ in proxy.scrollTo("latest-output", anchor: .bottom) }
            }
        }.frame(height: 150).background(Color.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ContextMeter: View {
    let usage: ContextUsage?
    var body: some View {
        VStack(spacing: 9) {
            HStack {
                Text("Context").foregroundStyle(DeckTheme.muted)
                Spacer()
                Text(usage?.label ?? "—").monospacedDigit().foregroundStyle(usage == nil ? DeckTheme.muted : DeckTheme.text)
            }.font(.system(size: 12, weight: .medium))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(DeckTheme.line)
                    if let percent = usage?.percent {
                        Capsule().fill(percent >= 85 ? AgentStatus.waiting.color : DeckTheme.accent.opacity(0.75))
                            .frame(width: geometry.size.width * percent / 100)
                    }
                }
            }.frame(height: 4)
        }.help(usage.map { value in
            if let used = value.used, let capacity = value.capacity { return "\(used.formatted()) / \(capacity.formatted()) tokens · \(value.source)" }
            return value.source
        } ?? "当前会话尚未提供 context 用量")
    }
}
