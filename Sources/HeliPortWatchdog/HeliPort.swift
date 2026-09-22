import Foundation

enum HeliPortError: Error, CustomStringConvertible {
    case notRunning
    case assistiveAccess(String)
    case switchNotFound
    case scriptFailed(String)

    var description: String {
        switch self {
        case .notRunning:
            return "HeliPort 未运行，请先启动 HeliPort"
        case .assistiveAccess(let detail):
            return "缺少辅助功能权限，无法操作 HeliPort 菜单。"
                + "请在「系统设置 → 隐私与安全性 → 辅助功能」中，"
                + "为运行 heliport-watchdog 的终端程序（或 heliport-watchdog 本体）授权后重试。详情：\(detail)"
        case .switchNotFound:
            return "未能在 HeliPort 菜单中找到 Wi-Fi 开关，HeliPort 版本可能不兼容"
        case .scriptFailed(let detail):
            return "AppleScript 执行失败：\(detail)"
        }
    }
}

/// 通过 System Events 操作 HeliPort 菜单栏图标中的 Wi-Fi 电源开关（NSSwitch）。
///
/// HeliPort（itlwm 驱动配套客户端）没有 CLI / URL Scheme，Wi-Fi 电源
/// 只能经由其菜单栏菜单第一项里的 NSSwitch 切换，因此依赖辅助功能权限。
enum HeliPort {

    /// 将 HeliPort 的 Wi-Fi 关闭一段时间后再打开。
    static func toggle(offDuration: TimeInterval) throws {
        try setPower(on: false)
        if offDuration > 0 {
            Thread.sleep(forTimeInterval: offDuration)
        }
        // 恢复动作必须成功，否则会把 Wi-Fi 留在关闭状态
        var lastError: Error = HeliPortError.scriptFailed("恢复 Wi-Fi 未知失败")
        for _ in 0..<3 {
            do {
                try setPower(on: true)
                return
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 1)
            }
        }
        throw lastError
    }

    /// 设置 Wi-Fi 电源状态（幂等：若已处于目标状态则不做任何点击）。
    static func setPower(on: Bool) throws {
        let (out, err, status) = runOSAScript(arguments: ["-", on ? "1" : "0"], timeout: 30)
        let result = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if status == 0 && result == "ok" { return }

        let detail = err.isEmpty ? result : err
        if detail.lowercased().contains("assistive") {
            throw HeliPortError.assistiveAccess(detail)
        }
        switch result {
        case "error:not-running":
            throw HeliPortError.notRunning
        case "error:not-found", "error:unreachable-state":
            throw HeliPortError.switchNotFound
        default:
            throw HeliPortError.scriptFailed(detail)
        }
    }

    // MARK: - AppleScript

    /// 脚本约定：
    /// - 入参：argv[1] 为目标状态，"1"=开 Wi-Fi，"0"=关 Wi-Fi
    /// - 成功输出 "ok"
    /// - 失败输出 "error:not-running" / "error:not-found" / "error:unreachable-state"
    ///
    /// HeliPort 的状态栏菜单位于菜单栏扩展区域（menu bar 1 或 2 因系统版本而异），
    /// 因此遍历该进程所有 menu bar 的 menu bar item，在展开的菜单中查找第一个
    /// checkbox（即 Wi-Fi 开关 NSSwitch），按需点击并校验状态。
    private static let appleScript = """
    on run argv
        set targetOn to (item 1 of argv) as string
        repeat 4 times
            set r to attemptSet(targetOn)
            if r is "ok" then return "ok"
            if r starts with "error:" then return r
            delay 0.8
        end repeat
        return "error:unreachable-state"
    end run

    on attemptSet(targetOn)
        tell application "System Events"
            if not (exists process "HeliPort") then return "error:not-running"
            key code 53
            delay 0.25
            repeat with mb in menu bars of process "HeliPort"
                repeat with sbi in menu bar items of mb
                    set r to tryMenu(sbi, targetOn)
                    if r is "ok" then
                        key code 53
                        return "ok"
                    else if r starts with "error:" then
                        return r
                    else if r is "retry" then
                        return "retry"
                    end if
                end repeat
            end repeat
            key code 53
        end tell
        return "error:not-found"
    end attemptSet

    on tryMenu(sbi, targetOn)
        tell application "System Events"
            try
                click sbi
            end try
            delay 0.4
            try
                set cb to my findSwitch(menu 1 of sbi)
            on error
                return "next"
            end try
            try
                set current to (value of cb) as string
                if current is targetOn then return "ok"
                click cb
                delay 1
                set afterClick to (value of cb) as string
                if afterClick is targetOn then return "ok"
                return "retry"
            on error
                return "retry"
            end try
        end tell
    end tryMenu

    on findSwitch(menuRef)
        tell application "System Events"
            repeat with mi in menu items of menuRef
                try
                    return checkbox 1 of mi
                end try
                try
                    return checkbox 1 of UI element 1 of mi
                end try
            end repeat
            error "switch-not-found"
        end tell
    end findSwitch
    """

    // MARK: - osascript 执行

    private static func runOSAScript(arguments: [String], timeout: TimeInterval)
        -> (out: String, err: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = arguments
        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ("", "无法启动 osascript：\(error.localizedDescription)", -1)
        }

        stdinPipe.fileHandleForWriting.write(Data(appleScript.utf8))
        stdinPipe.fileHandleForWriting.closeFile()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.3)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return ("", "osascript 执行超时（\(Int(timeout))s）", -2)
        }

        let out = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (out, err, process.terminationStatus)
    }
}
