import AppKit

/// 退出守卫：toggle 在途时 terminateLater 延迟退出（防止 Wi-Fi 被留在关闭态），
/// toggle 完成后经 finishPendingTerminate 终止。
extension AppDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard engine.isToggleInProgress else {
            appendExitLine()
            return .terminateNow
        }
        pendingTerminate = true
        return .terminateLater
    }
}
