import SwiftUI
import AppKit
import AgentDeckCore

@main
struct AgentDeckApp: App {
    @NSApplicationDelegateAdaptor(DeckDelegate.self) var delegate
    @StateObject private var store = DeckStore(demo: CommandLine.arguments.contains("--demo"))
    var body: some Scene {
        Window("AgentDeck", id: "main") {
            ContentView(store: store)
                .onAppear {
                    delegate.reopenMain = { store.openMain() }
                    store.startFloating()
                    captureIfRequested()
                    #if DEBUG
                    if store.demo, CommandLine.arguments.contains("--demo-detail") {
                        store.selection = store.visible.first?.id; store.showDetail = true
                    }
                    RuntimeVerification.startIfRequested(store: store)
                    #endif
                }
        }
        .defaultSize(width: 1240, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) { Button("偏好设置…") { store.showSettings = true }.keyboardShortcut(",") }
        }
    }
    private func captureIfRequested() {
        guard let index = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.indices.contains(index + 1) else { return }
        let path = CommandLine.arguments[index + 1]
        func capture(_ destination: String) {
            let floating = CommandLine.arguments.contains("--snapshot-floating")
            if floating {
                if CommandLine.arguments.contains("--snapshot-floating-preview") { store.floatingController?.savePreviewSnapshot(to: URL(fileURLWithPath: destination)) }
                else { store.floatingController?.saveSnapshot(to: URL(fileURLWithPath: destination)) }
                return
            }
            guard let window = NSApp.windows.first(where: { floating ? $0.identifier?.rawValue == "AgentDeck.floating" : $0.title == "AgentDeck" && $0.frame.width > 800 }), let view = (window.attachedSheet ?? window).contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: destination)) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { capture(path) }
        #if DEBUG
        if CommandLine.arguments.contains("--snapshot-motion") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.7) { capture(path.replacingOccurrences(of: ".png", with: "-motion.png")) }
        }
        #endif
    }
}

final class DeckDelegate: NSObject, NSApplicationDelegate {
    var reopenMain: (() -> Void)?
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            if let window = NSApp.windows.first(where: { $0.title == "AgentDeck" && $0.styleMask.contains(.titled) }) {
                window.isRestorable = false
                window.makeKeyAndOrderFront(nil)
            }
            if !CommandLine.arguments.contains("--start-hidden") { NSApp.activate(ignoringOtherApps: true) }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        reopenMain?()
        return true
    }
}
