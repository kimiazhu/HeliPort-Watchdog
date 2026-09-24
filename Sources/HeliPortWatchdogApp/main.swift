import AppKit
import WatchdogCore

// 单实例保护：同 bundle id 已有实例在跑则激活它并退出，防止双实例同时 ping/切 Wi-Fi。
// LaunchServices 拉起时本进程自身可能已在列表中，必须排除。
if let bundleID = Bundle.main.bundleIdentifier {
    let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { $0 != NSRunningApplication.current }
    if let first = existing.first {
        AppActivation.activateRunning(first)
        exit(0)
    }
}

let app = NSApplication.shared
// 纯托盘应用：任何时刻无 Dock 图标（打包 Info.plist 另有 LSUIElement=true 双保险）
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()

/// 启动环境判定（开机自启静默）：
/// 由登录项拉起时系统将 NSApplicationLaunchIsDefaultLaunchKey 置为 false，
/// 此时不弹窗口、静默进托盘；键缺失（如直接运行可执行文件）视为手动启动。
enum LaunchContext {
    static func shouldShowWindow(_ notification: Notification?) -> Bool {
        if let value = notification?.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool {
            return value
        }
        if let value = UserDefaults.standard.object(forKey: "NSApplicationLaunchIsDefaultLaunch") as? Bool {
            return value
        }
        return true
    }
}
