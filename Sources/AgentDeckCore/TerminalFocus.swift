import Foundation

/// Native terminal scripting, addressed by the attached client's exact TTY.
/// Values are argv, never interpolated into AppleScript or typed into a shell.
public enum TerminalFocus {
    public static func focus(tty: String, applicationID: String) throws -> Bool {
        let body: String
        switch applicationID {
        case "com.mitchellh.ghostty":
            body = """
            tell application id "com.mitchellh.ghostty"
                repeat with terminalSurface in terminals
                    if (tty of terminalSurface as text) is targetTTY then
                        focus terminalSurface
                        activate
                        return "focused"
                    end if
                end repeat
            end tell
            """
        case "com.apple.Terminal":
            body = """
            tell application id "com.apple.Terminal"
                repeat with terminalWindow in windows
                    repeat with terminalTab in tabs of terminalWindow
                        if (tty of terminalTab as text) is targetTTY then
                            set selected tab of terminalWindow to terminalTab
                            set miniaturized of terminalWindow to false
                            set index of terminalWindow to 1
                            activate
                            return "focused"
                        end if
                    end repeat
                end repeat
            end tell
            """
        case "com.googlecode.iterm2":
            body = """
            tell application id "com.googlecode.iterm2"
                repeat with terminalWindow in windows
                    repeat with terminalTab in tabs of terminalWindow
                        repeat with terminalSession in sessions of terminalTab
                            if (tty of terminalSession as text) is targetTTY then
                                select terminalSession
                                select terminalTab
                                select terminalWindow
                                activate
                                return "focused"
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """
        default: return false
        }
        let script = "on run argv\nset targetTTY to item 1 of argv\n" + body + "\nreturn \"not-found\"\nend run"
        let result = try Command.run("/usr/bin/osascript", ["-e", script, tty])
        guard result.status == 0 else { throw DeckError.message("tmux 已定位，但无法聚焦原终端：\(result.stderr)") }
        guard result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "focused" else {
            throw DeckError.message("tmux 已定位，但原终端标签页已关闭或无法找到。")
        }
        return true
    }

    public static func openNew(command: String) throws {
        let script = """
        on run argv
            tell application "Terminal"
                activate
                do script (item 1 of argv)
            end tell
        end run
        """
        let result = try Command.run("/usr/bin/osascript", ["-e", script, command])
        guard result.status == 0 else { throw DeckError.message("无法打开 Terminal：\(result.stderr)\n可使用「复制连接命令」。") }
    }
}
