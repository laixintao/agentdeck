import SwiftUI
import AppKit
import AgentDeckCore

enum DeckTheme {
    static let background = Color(red: 0.065, green: 0.071, blue: 0.083)
    static let surface = Color(red: 0.105, green: 0.113, blue: 0.130)
    static let panel = Color(red: 0.145, green: 0.155, blue: 0.175)
    static let text = Color(red: 0.92, green: 0.93, blue: 0.95)
    static let accent = Color(red: 0.70, green: 0.82, blue: 0.98)
    static let line = Color.white.opacity(0.085)
    static let muted = Color(red: 0.57, green: 0.60, blue: 0.66)
}
extension AgentStatus {
    var color: Color { switch self {
    case .working: Color(red: 0.56, green: 0.75, blue: 0.99)
    case .waiting: Color(red: 0.98, green: 0.73, blue: 0.36)
    case .completed: Color(red: 0.53, green: 0.83, blue: 0.69)
    case .failed: Color(red: 0.99, green: 0.48, blue: 0.46)
    default: DeckTheme.muted
    } }
}
extension AgentKind {
    var color: Color { switch self {
    case .codex: Color(red: 0.70, green: 0.84, blue: 0.95)
    case .claude: Color(red: 0.90, green: 0.64, blue: 0.48)
    case .hermes: Color(red: 0.74, green: 0.67, blue: 0.98)
    case .custom: DeckTheme.muted
    } }
}
struct StatusPill: View {
    let status: AgentStatus
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: status == .working ? "circle.fill" : status.symbol).font(.system(size: status == .working ? 5 : 10))
            Text(status.title)
        }.font(.system(size: 11, weight: .medium)).foregroundStyle(status.color)
            .padding(.horizontal, 9).padding(.vertical, 6).background(status.color.opacity(0.09), in: Capsule())
    }
}
struct AgentIcon: View {
    let kind: AgentKind
    var size: CGFloat = 36
    var body: some View { AnimatedAgentIcon(kind: kind, status: .idle, size: size) }
}

struct AnimatedAgentIcon: View {
    let kind: AgentKind
    let status: AgentStatus
    var size: CGFloat = 60
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion || ![.working, .waiting].contains(status))) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            let working = status == .working && !reduceMotion
            let pulse = status == .waiting && !reduceMotion ? (sin(t * 3) + 1) / 2 : 0
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.28).fill(kind.color.opacity(0.08))
                if status == .working {
                    Circle().trim(from: 0.08, to: 0.32).stroke(kind.color.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .rotationEffect(.degrees(working ? t.truncatingRemainder(dividingBy: 3) * 120 : 0)).padding(2)
                    Circle().trim(from: 0.58, to: 0.72).stroke(kind.color.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .rotationEffect(.degrees(working ? t.truncatingRemainder(dividingBy: 3) * 120 : 0)).padding(2)
                }
                if status == .waiting {
                    RoundedRectangle(cornerRadius: size * 0.28).stroke(status.color.opacity(0.3 + pulse * 0.5), lineWidth: 1.5)
                        .scaleEffect(1 + pulse * 0.1)
                }
                if status == .completed || status == .failed {
                    Image(systemName: status == .completed ? "checkmark" : "exclamationmark")
                        .font(.system(size: size * 0.15, weight: .bold)).foregroundStyle(DeckTheme.background)
                        .frame(width: size * 0.29, height: size * 0.29).background(status.color, in: Circle())
                        .offset(x: size * 0.39, y: size * 0.37)
                }
                glyph(time: t, working: working).foregroundStyle(kind.color)
                if status == .waiting {
                    Image(systemName: "pause.fill").font(.system(size: size * 0.13, weight: .bold)).foregroundStyle(DeckTheme.background)
                        .frame(width: size * 0.29, height: size * 0.29).background(status.color, in: Circle())
                        .offset(x: size * 0.39, y: size * 0.37).scaleEffect(1 + pulse * 0.08)
                }
            }
        }.frame(width: size, height: size).accessibilityLabel("\(kind.title)，\(status.title)")
    }
    @ViewBuilder private func glyph(time: Double, working: Bool) -> some View {
        switch kind {
        case .codex:
            Image(systemName: "command").font(.system(size: size * 0.44, weight: .medium))
                .rotationEffect(.degrees(working ? sin(time * 2.4) * 10 : 0))
                .scaleEffect(working ? 1 + sin(time * 2.4) * 0.06 : 1)
        case .claude:
            ZStack {
                ForEach(0..<12) { index in
                    Capsule().frame(width: size * 0.045, height: size * (index % 2 == 0 ? 0.18 : 0.13))
                        .offset(y: -size * 0.17).rotationEffect(.degrees(Double(index) * 30))
                }
                Circle().frame(width: size * 0.16, height: size * 0.16)
            }.rotationEffect(.degrees(working ? time.truncatingRemainder(dividingBy: 12) * 30 : 12))
                .scaleEffect(working ? 0.94 + sin(time * 3) * 0.09 : 1)
        case .hermes:
            Image(nsImage: AgentAssets.hermes).resizable().renderingMode(.original).interpolation(.high)
                .scaledToFit().frame(width: size * 0.72, height: size * 0.72)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.18))
                .rotationEffect(.degrees(working ? sin(time * 3) * 5 : 0))
                .offset(y: working ? sin(time * 3) * 1.5 : 0)
        case .custom:
            Image(systemName: "terminal").font(.system(size: size * 0.42)).opacity(working ? 0.6 + (sin(time * 3) + 1) * 0.2 : 1)
        }
    }
}
private enum AgentAssets {
    static let hermes: NSImage = {
        let url = Bundle.main.url(forResource: "Hermes", withExtension: "png") ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Hermes.png")
        return NSImage(contentsOf: url) ?? NSImage(systemSymbolName: "h.circle", accessibilityDescription: "Hermes")!
    }()
}
