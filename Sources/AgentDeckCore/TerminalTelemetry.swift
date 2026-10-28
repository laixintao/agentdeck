import Foundation

public enum TerminalTelemetry {
    public static func preview(_ output: String) -> String {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
        return String(lines.filter { !isChrome($0) }.suffix(45).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).suffix(6000))
    }
    private static func isChrome(_ line: String) -> Bool {
        let lower = line.lowercased()
        if lower.contains("esc to interrupt") || lower.contains("tip: use /keymap") || lower.contains("tab to queue message") { return true }
        if lower.contains("for shortcuts") || lower.contains("to expand)") || lower.contains("shift+tab to cycle") || lower.contains("update available!") || lower.contains("for agents") || lower.hasPrefix("gpt-") { return true }
        if lower.hasPrefix("›") || lower == "❯" || lower.hasPrefix("you ❯") || lower.hasPrefix("hermes ❯") { return true }
        if line.count > 2, line.allSatisfy({ "─━═│╭╰╮╯ ".contains($0) }) { return true }
        return false
    }
    // Only parse explicit context meters in the current footer. Token totals and
    // arbitrary percentages in previous tool output are not context occupancy.
    public static func context(_ output: String) -> ContextUsage? {
        let lines = output.split(separator: "\n").suffix(12)
        for line in lines.reversed() {
            let text = String(line).lowercased()
            for pattern in [#"(\d+(?:\.\d+)?)%\s+(?:of\s+)?context\s+(left|remaining|used)"#,
                            #"context(?:\s+(?:window|usage))?\s*[:：]?\s*(\d+(?:\.\d+)?)%\s*(left|remaining|used)?"#] {
                if let parts = match(pattern, text), let percent = Double(parts[0]), (0...100).contains(percent) {
                    let remaining = parts.count > 1 && ["left", "remaining"].contains(parts[1])
                    return ContextUsage(percent: remaining ? 100 - percent : percent, source: "终端 context 状态栏")
                }
            }
            if text.contains("context"), let parts = match(#"(\d[\d,]*(?:\.\d+)?)\s*([km]?)\s*/\s*(\d[\d,]*(?:\.\d+)?)\s*([km]?)"#, text),
               let used = tokens(parts[0], suffix: parts[1]), let capacity = tokens(parts[2], suffix: parts[3]) {
                return ContextUsage(used: used, capacity: capacity, source: "终端 context 状态栏")
            }
        }
        return nil
    }
    public static func work(_ output: String, kind: AgentKind) -> String? {
        let lines = output.split(separator: "\n").suffix(45).map { String($0).trimmingCharacters(in: .whitespaces) }
        // Prefer the latest concrete activity above the input/status footer.
        for line in lines.reversed() {
            let lower = line.lowercased()
            if isChrome(line) { continue }
            let verbs = ["running ", "reading ", "editing ", "searching ", "writing ", "testing ", "executing ", "正在", "读取", "修改", "搜索", "执行"]
            let clean = line.trimmingCharacters(in: CharacterSet(charactersIn: "•●✻✽✳⏺·─ "))
            if verbs.contains(where: { clean.lowercased().hasPrefix($0) }) && !lower.contains("esc to") {
                return String(clean.prefix(180))
            }
        }
        for line in lines.reversed() {
            let lower = line.lowercased()
            if line.count < 4 || lower.contains("context") || lower.contains("esc to") || lower.contains("ctrl-c") || lower.contains("ctrl+c") || lower.contains("for shortcuts") || lower.contains("tokens") { continue }
            if ["›", "❯", "you ❯", "you ›", "hermes ❯", "╭", "╰", "│", "─", "└", "$", "%"].contains(where: lower.hasPrefix) { continue }
            if lower.hasPrefix("gpt-") || lower.hasPrefix("claude-") || lower.hasPrefix("model:") { continue }
            return String(line.trimmingCharacters(in: CharacterSet(charactersIn: "•●⏺ ")).prefix(180))
        }
        return nil
    }
    private static func match(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }
    private static func tokens(_ text: String, suffix: String) -> Int? {
        guard let value = Double(text.replacingOccurrences(of: ",", with: "")) else { return nil }
        let amount = value * (suffix == "m" ? 1_000_000 : suffix == "k" ? 1000 : 1)
        guard amount.isFinite, amount >= 0, amount < Double(Int.max) else { return nil }
        return Int(amount)
    }
}
