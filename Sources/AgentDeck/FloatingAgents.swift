import AppKit
import SwiftUI
import Combine
import AgentDeckCore

private enum FloatingMetrics {
    static let icon: CGFloat = 24
    static let cell: CGFloat = 28
    static let spacing: CGFloat = 4
    static let padding: CGFloat = 6
    static let cornerRadius: CGFloat = 10
    static func length(_ count: Int) -> CGFloat {
        CGFloat(count) * cell + CGFloat(max(0, count - 1)) * spacing + padding * 2
    }
}

final class AgentFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    var onDrag: ((NSPoint, Bool) -> Void)?
    var onClick: ((NSPoint) -> Void)?
    var onPress: (() -> Void)?
    private var press: (mouse: NSPoint, origin: NSPoint, dragging: Bool)?
    var isPointerPressed: Bool { press != nil }

    // Own the pointer sequence so dragging an icon never also opens its session.
    // Screen coordinates remain stable while the panel itself moves.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            press = (convertPoint(toScreen: event.locationInWindow), frame.origin, false)
            onPress?()
        case .leftMouseDragged:
            guard var press else { return }
            let mouse = convertPoint(toScreen: event.locationInWindow)
            let dx = mouse.x - press.mouse.x, dy = mouse.y - press.mouse.y
            guard press.dragging || hypot(dx, dy) >= 4 else { return }
            press.dragging = true; self.press = press
            onDrag?(NSPoint(x: press.origin.x + dx, y: press.origin.y + dy), false)
        case .leftMouseUp:
            guard let press else { return }
            self.press = nil
            if press.dragging { onDrag?(frame.origin, true) }
            else { onClick?(event.locationInWindow) }
        case .rightMouseDown:
            onPress?()
            super.sendEvent(event)
        default:
            super.sendEvent(event)
        }
    }
}

@MainActor
final class FloatingAgentsController {
    private weak var store: DeckStore?
    private let panel = AgentFloatingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let preview = AgentFloatingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private var hoverID: String?
    private var hoverTask: DispatchWorkItem?
    private var previewRecordID: String?
    #if DEBUG
    private var terminalForVerification: ((String) -> Void)?
    #endif
    private var observations: [(NotificationCenter, NSObjectProtocol)] = []
    private var subscription: AnyCancellable?
    private var started = false
    private let layout = FloatingLayout()
    private let positionStore: EventStore?
    private var customOrigin: NSPoint?
    private var mainWindow: NSWindow? { NSApp.windows.first { $0.title == "AgentDeck" && $0.styleMask.contains(.titled) } }

    init(store: DeckStore) {
        self.store = store
        positionStore = store.demo ? nil : EventStore()
        if let saved = positionStore?.load(NSPoint.self, name: "floating-position.json"), saved.x.isFinite, saved.y.isFinite { customOrigin = saved }
        panel.identifier = NSUserInterfaceItemIdentifier("AgentDeck.floating")
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let hosting = FloatingHostingView(rootView: FloatingAgentsView(store: store, layout: layout) { [weak self] id in self?.open(id) })
        hosting.onHoverPoint = { [weak self] point in self?.hover(at: point) }
        panel.contentView = hosting
        preview.identifier = NSUserInterfaceItemIdentifier("AgentDeck.floatingPreview")
        preview.level = .floating
        preview.isFloatingPanel = true; preview.hidesOnDeactivate = false; preview.canHide = false
        preview.isOpaque = false; preview.backgroundColor = .clear; preview.hasShadow = true
        preview.ignoresMouseEvents = true; preview.isReleasedWhenClosed = false
        preview.collectionBehavior = panel.collectionBehavior
        panel.onPress = { [weak self] in self?.hidePreview() }
        panel.onDrag = { [weak self] origin, finished in self?.move(to: origin, finished: finished) }
        panel.onClick = { [weak self] point in
            guard let self else { return }
            if let id = self.agent(at: point) { self.open(id) }
        }
    }
    deinit { for (center, token) in observations { center.removeObserver(token) } }

    func start() {
        guard !started, let store else { return }; started = true
        let names: [Notification.Name] = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification,
            NSWindow.didChangeOcclusionStateNotification, NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification, NSApplication.didHideNotification, NSApplication.didUnhideNotification,
            NSApplication.didChangeScreenParametersNotification]
        for name in names { observe(name, center: .default) }
        observe(NSWorkspace.activeSpaceDidChangeNotification, center: NSWorkspace.shared.notificationCenter)
        subscription = store.$records.sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            if CommandLine.arguments.contains("--start-hidden") { self?.mainWindow?.orderOut(nil); NSApp.hide(nil) }
            self?.refresh()
        }
    }
    private func observe(_ name: Notification.Name, center: NotificationCenter) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            if note.object is AgentFloatingPanel { return }
            DispatchQueue.main.async { self?.refresh() }
        }
        observations.append((center, token))
    }
    func refresh() {
        guard let store, let screen = NSScreen.screens.first else { panel.orderOut(nil); hidePreview(); return }
        let mainInFront = NSApp.isActive && !NSApp.isHidden && mainWindow?.isVisible == true && mainWindow?.isMiniaturized == false
        guard !mainInFront, !store.live.isEmpty else { panel.orderOut(nil); hidePreview(); return }
        let available = screen.frame
        let columns = min(store.live.count, min(12, max(1, Int((available.width - 24 - FloatingMetrics.padding * 2 + FloatingMetrics.spacing) / (FloatingMetrics.cell + FloatingMetrics.spacing)))))
        let rows = min(4, Int(ceil(Double(store.live.count) / Double(columns))))
        if layout.columns != columns { layout.columns = columns }
        let width = FloatingMetrics.length(columns)
        let height = FloatingMetrics.length(rows)
        let origin = customOrigin ?? NSPoint(x: available.minX + 12, y: available.minY + 12)
        let frame = clamped(NSRect(origin: origin, size: NSSize(width: width, height: height)))
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
        if let hoverID {
            if !store.live.contains(where: { $0.id == hoverID }) { hidePreview() }
            else if preview.isVisible { showPreview(for: hoverID) }
        }
    }
    private func clamped(_ frame: NSRect) -> NSRect {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return frame }
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let screen = screens.first(where: { $0.frame.contains(center) })
            ?? screens.filter { $0.frame.intersects(frame) }.max(by: {
                let a = $0.frame.intersection(frame), b = $1.frame.intersection(frame)
                return a.width * a.height < b.width * b.height
            }) ?? primary
        let bounds = screen.frame.insetBy(dx: 12, dy: 12)
        return NSRect(x: min(max(frame.minX, bounds.minX), max(bounds.minX, bounds.maxX - frame.width)),
                      y: min(max(frame.minY, bounds.minY), max(bounds.minY, bounds.maxY - frame.height)),
                      width: frame.width, height: frame.height)
    }
    private func move(to origin: NSPoint, finished: Bool) {
        hidePreview()
        let frame = clamped(NSRect(origin: origin, size: panel.frame.size))
        customOrigin = frame.origin
        panel.setFrameOrigin(frame.origin)
        if finished { try? positionStore?.save(frame.origin, name: "floating-position.json") }
    }
    private func agent(at windowPoint: NSPoint) -> String? {
        let point = NSPoint(x: windowPoint.x, y: panel.frame.height - windowPoint.y)
        return layout.frames.first(where: { $0.value.contains(point) })?.key
    }
    private func hover(at point: NSPoint?) {
        guard panel.isVisible, !panel.isPointerPressed, let point, let id = agent(at: point) else { hidePreview(); return }
        guard hoverID != id else { return }
        hidePreview(); hoverID = id
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.hoverID == id, self.panel.isVisible, !self.panel.isPointerPressed else { return }
            self.showPreview(for: id)
        }
        hoverTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: task)
    }
    private func hidePreview() {
        hoverTask?.cancel(); hoverTask = nil; hoverID = nil; previewRecordID = nil
        preview.orderOut(nil)
    }
    private func showPreview(for id: String) {
        guard panel.isVisible, let record = store?.live.first(where: { $0.id == id }), let icon = layout.frames[id],
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(panel.frame) }) else { hidePreview(); return }
        let view: NSHostingView<FloatingAgentPreview>
        if let current = preview.contentView as? NSHostingView<FloatingAgentPreview> {
            current.rootView = FloatingAgentPreview(record: record); view = current
        } else {
            view = NSHostingView(rootView: FloatingAgentPreview(record: record)); preview.contentView = view
        }
        let size = view.fittingSize
        let bounds = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let x = min(max(panel.frame.minX + icon.minX - 8, bounds.minX), bounds.maxX - size.width)
        let above = panel.frame.maxY + 8
        let y = above + size.height <= bounds.maxY ? above : panel.frame.minY - size.height - 8
        preview.setFrame(NSRect(x: x, y: min(max(y, bounds.minY), bounds.maxY - size.height), width: size.width, height: size.height), display: true)
        previewRecordID = id
        preview.order(.above, relativeTo: panel.windowNumber)
    }
    private func open(_ id: String) {
        hidePreview()
        guard let store, let record = store.live.first(where: { $0.id == id }) else { return }
        #if DEBUG
        if let terminalForVerification { terminalForVerification(id); return }
        #endif
        store.terminal(record, revealErrors: true)
    }
    func saveSnapshot(to url: URL) {
        refresh()
        guard let view = panel.contentView, view.bounds.width > 0 else { return }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
    func savePreviewSnapshot(to url: URL) {
        guard store?.demo == true, let id = store?.live.sorted(by: { $0.id < $1.id }).first?.id else { return }
        refresh(); hoverID = id; showPreview(for: id)
        savePreviewImage(to: url)
    }
    private func savePreviewImage(to url: URL) {
        guard let view = preview.contentView, preview.isVisible else { return }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    #if DEBUG
    func verifyBehavior(snapshot: URL) async throws -> [String: String] {
        guard let store, let id = store.live.sorted(by: { $0.id < $1.id }).first?.id else { throw DeckError.message("No agents to verify floating panel") }
        var terminalClicks = [String]()
        terminalForVerification = { terminalClicks.append($0) }
        defer { terminalForVerification = nil; hidePreview() }
        customOrigin = nil // Runtime verification uses an isolated data directory.
        store.showDetail = false; store.openMain()
        try await Task.sleep(for: .milliseconds(350)); refresh()
        guard !panel.isVisible, let main = mainWindow else { throw DeckError.message("Floating panel should be hidden while main window is active") }
        main.miniaturize(nil)
        try await Task.sleep(for: .milliseconds(700)); refresh()
        guard panel.isVisible, panel.level.rawValue > NSWindow.Level.normal.rawValue, !panel.hidesOnDeactivate, !panel.canBecomeKey,
              panel.collectionBehavior.contains(.canJoinAllSpaces), panel.collectionBehavior.contains(.fullScreenAuxiliary),
              !panel.isOpaque, !panel.canHide, let screen = NSScreen.screens.first,
              abs(panel.frame.minX - screen.frame.minX - 12) < 1,
              abs(panel.frame.minY - screen.frame.minY - 12) < 1 else { throw DeckError.message("Floating panel placement or visibility failed") }
        guard layout.frames.count == store.live.count,
              layout.frames.values.allSatisfy({ $0.minX >= 0 && $0.maxX <= panel.frame.width + 1 && $0.minY >= 0 && $0.maxY <= panel.frame.height + 1 }) else { throw DeckError.message("Floating panel clipped an agent icon: \(layout.frames.count)/\(store.live.count)") }
        saveSnapshot(to: snapshot)
        guard let iconFrame = layout.frames[id] else { throw DeckError.message("Missing floating icon bounds") }
        let iconPoint = NSPoint(x: iconFrame.midX, y: panel.frame.height - iconFrame.midY)
        guard let hosting = panel.contentView as? FloatingHostingView<FloatingAgentsView>,
              let hover = NSEvent.mouseEvent(with: .mouseMoved, location: iconPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else { throw DeckError.message("Could not create hover event") }
        hosting.mouseEntered(with: hover)
        try await Task.sleep(for: .milliseconds(350))
        guard preview.isVisible, previewRecordID == id, !preview.canBecomeKey, !preview.isKeyWindow,
              preview.ignoresMouseEvents, screen.visibleFrame.contains(preview.frame), main.isMiniaturized else { throw DeckError.message("Hover preview routing, focus or screen placement failed") }
        savePreviewImage(to: snapshot.deletingLastPathComponent().appendingPathComponent("floating-preview-runtime.png"))
        hosting.mouseExited(with: hover)
        guard !preview.isVisible else { throw DeckError.message("Hover preview did not dismiss") }
        hosting.mouseEntered(with: hover)
        hosting.mouseExited(with: hover)
        try await Task.sleep(for: .milliseconds(300))
        guard !preview.isVisible else { throw DeckError.message("Cancelled hover preview appeared late") }
        func pointer(_ type: NSEvent.EventType, at screenPoint: NSPoint) throws {
            guard let event = NSEvent.mouseEvent(with: type, location: panel.convertPoint(fromScreen: screenPoint), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else { throw DeckError.message("Could not create floating-panel pointer event") }
            panel.sendEvent(event)
        }
        // Drag from an icon and from the surrounding glass, with two motion events
        // each to catch feedback caused by using a moving window's coordinates.
        for point in [iconPoint, NSPoint(x: FloatingMetrics.padding / 2, y: FloatingMetrics.padding / 2)] {
            let origin = panel.frame.origin, start = panel.convertPoint(toScreen: point)
            try pointer(.leftMouseDown, at: start)
            try pointer(.leftMouseDragged, at: NSPoint(x: start.x + 40, y: start.y + 30))
            try pointer(.leftMouseDragged, at: NSPoint(x: start.x + 160, y: start.y + 90))
            try pointer(.leftMouseUp, at: NSPoint(x: start.x + 160, y: start.y + 90))
            let expected = NSPoint(x: origin.x + 160, y: origin.y + 90)
            await store.refresh(); refresh()
            guard panel.frame.origin == expected, panel.isVisible, !store.showDetail, main.isMiniaturized, !panel.isKeyWindow, terminalClicks.isEmpty, !preview.isVisible else { throw DeckError.message("Dragging snapped back or opened an agent") }
            guard positionStore?.load(NSPoint.self, name: "floating-position.json") == expected else { throw DeckError.message("Floating position was not saved") }
        }
        let restored = FloatingAgentsController(store: store)
        guard restored.customOrigin == panel.frame.origin else { throw DeckError.message("Floating position was not restored") }
        let outside = NSRect(x: screen.frame.maxX + 100_000, y: screen.frame.maxY + 100_000, width: panel.frame.width, height: panel.frame.height)
        guard screen.frame.contains(clamped(outside)) else { throw DeckError.message("An unavailable display left the panel offscreen") }
        let point = iconPoint
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else { throw DeckError.message("Could not create floating-panel click") }
            panel.sendEvent(event)
        }
        try await Task.sleep(for: .milliseconds(400)); refresh()
        guard terminalClicks == [id], !store.showDetail, main.isMiniaturized, !preview.isVisible else { throw DeckError.message("Floating icon did not route directly to its terminal") }
        store.showDetail = false
        try await Task.sleep(for: .milliseconds(250))
        main.orderOut(nil); NSApp.hide(nil)
        try await Task.sleep(for: .milliseconds(300)); refresh()
        guard panel.isVisible else { throw DeckError.message("Floating panel disappeared with hidden app") }
        store.openMain()
        try await Task.sleep(for: .milliseconds(300)); refresh()
        guard !panel.isVisible else { throw DeckError.message("Floating panel did not hide on returning to main window") }
        mainWindow?.performClose(nil)
        try await Task.sleep(for: .milliseconds(300)); refresh()
        guard panel.isVisible else { throw DeckError.message("Floating panel disappeared after closing main window") }
        store.openMain()
        try await Task.sleep(for: .milliseconds(400)); refresh()
        guard !panel.isVisible, mainWindow?.isVisible == true else { throw DeckError.message("Could not reopen the closed main window") }
        return ["floatingVisibility": "passed", "floatingPrimaryBottomLeft": "passed", "floatingAlwaysOnTop": "passed", "floatingNonactivating": "passed", "floatingTerminalRouting": "passed", "floatingHoverPreview": "passed", "floatingHoverDismissal": "passed", "floatingClosedWindowReopen": "passed", "floatingAllIconsVisible": "passed", "floatingDrag": "passed", "floatingPositionPersistence": "passed", "floatingScreenClamping": "passed"]
    }
    #endif
}

private final class FloatingHostingView<Content: View>: NSHostingView<Content> {
    var onHoverPoint: ((NSPoint?) -> Void)?
    private var pointerTracking: NSTrackingArea?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard pointerTracking == nil else { return }
        let tracking = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited, .mouseMoved], owner: self, userInfo: nil)
        addTrackingArea(tracking); pointerTracking = tracking
    }
    override func mouseEntered(with event: NSEvent) { onHoverPoint?(event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { onHoverPoint?(event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { onHoverPoint?(nil) }
}

private final class FloatingLayout: ObservableObject {
    @Published var columns = 1
    var frames: [String: CGRect] = [:]
}
private struct FloatingIconFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { _, new in new } }
}

private struct FloatingAgentsView: View {
    @ObservedObject var store: DeckStore
    @ObservedObject var layout: FloatingLayout
    let onOpen: (String) -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        ScrollView(.vertical) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(FloatingMetrics.cell), spacing: FloatingMetrics.spacing), count: layout.columns), spacing: FloatingMetrics.spacing) {
                ForEach(store.live.sorted { $0.id < $1.id }) { record in
                    Button { onOpen(record.id) } label: {
                        AnimatedAgentIcon(kind: record.pane.kind, status: record.status, size: FloatingMetrics.icon).frame(width: FloatingMetrics.cell, height: FloatingMetrics.cell)
                    }.buttonStyle(.plain)
                        .contextMenu {
                            Button("查看详情") { store.openAgent(record.id) }
                        }
                        .background(GeometryReader { geometry in Color.clear.preference(key: FloatingIconFrames.self, value: [record.id: geometry.frame(in: .named("floating-panel"))]) })
                        .accessibilityLabel("\(record.pane.title.isEmpty ? record.pane.project : record.pane.title)，\(record.pane.kind.title)，\(record.status.title)，\(record.pane.hermesSession == nil ? "定位终端" : "打开 Hermes")")
                }
            }.padding(FloatingMetrics.padding)
        }.scrollIndicators(.hidden).coordinateSpace(name: "floating-panel")
            .onPreferenceChange(FloatingIconFrames.self) { layout.frames = $0 }
            .background {
                if reduceTransparency { DeckTheme.surface }
                else { FloatingGlass().opacity(0.80) }
            }
            .clipShape(RoundedRectangle(cornerRadius: FloatingMetrics.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: FloatingMetrics.cornerRadius).strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
            .preferredColorScheme(.dark)
    }
}

private struct FloatingAgentPreview: View {
    let record: AgentRecord
    private var output: String {
        let text = record.pane.previewOutput ?? TerminalTelemetry.preview(record.pane.output)
        return String(text.split(separator: "\n", omittingEmptySubsequences: false).suffix(8).joined(separator: "\n").suffix(1400))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(record.status.color).frame(width: 6, height: 6).padding(.top, 5)
                Text(record.pane.title.isEmpty ? record.pane.project : record.pane.title)
                    .font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Spacer(minLength: 4)
                Text(record.pane.kind.title).font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
            }
            Label(record.pane.directory.isEmpty ? record.pane.location : (record.pane.directory as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(DeckTheme.muted)
                .lineLimit(2).truncationMode(.middle)
            ScrollView(.vertical) {
                Text(output.isEmpty ? "暂无输出" : output)
                    .font(.system(size: 10, design: .monospaced)).lineSpacing(3)
                    .foregroundStyle(DeckTheme.text.opacity(0.88))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
            }.scrollIndicators(.hidden).defaultScrollAnchor(.bottom)
                .frame(height: 112).background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 7)).id(output)
            HStack {
                Text(record.status.title)
                Spacer()
                if let usage = record.pane.contextUsage { Text("Context \(usage.label)") }
            }.font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
        }.padding(12).frame(width: 326)
            .foregroundStyle(DeckTheme.text)
            .background(DeckTheme.surface.opacity(0.97), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .preferredColorScheme(.dark)
    }
}

private struct FloatingGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow; view.blendingMode = .behindWindow; view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
