import AppKit
import WatchdogCore

/// 组装日志窗口 + 托盘 + 引擎；Engine 事件 hop 主线程。
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// GUI 固定 .sh 默认配置（无设置界面）
    private static let config = WatchdogEngine.Config(
        remoteIP: "192.168.100.1",
        downThreshold: 10,
        pingInterval: 1,
        offDuration: 1
    )

    let engine: WatchdogEngine
    let logWindowController: LogWindowController
    let statusItemController: StatusItemController

    var pendingTerminate = false

    override init() {
        let logController = LogWindowController()
        self.logWindowController = logController

        let engine = WatchdogEngine(config: Self.config)
        self.engine = engine

        let statusItem = StatusItemController()
        self.statusItemController = statusItem

        super.init()

        engine.onEvent = { [weak logController] line in
            DispatchQueue.main.async {
                logController?.append(line)
            }
        }
        engine.onToggleDidFinish = { [weak self] in
            DispatchQueue.main.async {
                self?.finishPendingTerminate()
            }
        }

        statusItem.onLeftClick = { [weak self] in self?.restoreWindow() }
        statusItem.log = { [weak logController] level, message in
            DispatchQueue.main.async {
                logController?.append(LogLine(date: Date(), level: level, message: message))
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenus()
        if LaunchContext.shouldShowWindow(notification) {
            showLogWindow()
        }
        engine.start()
    }

    /// 最小菜单：编辑（复制/全选）+ 窗口（最小化 Cmd+M / 关闭 Cmd+W）。
    /// accessory 应用无菜单栏展示，但窗口为 key 时快捷键经此路由生效。
    private func installMenus() {
        let mainMenu = NSMenu()

        let editRoot = NSMenuItem()
        mainMenu.addItem(editRoot)
        let editMenu = NSMenu(title: "编辑")
        editRoot.submenu = editMenu
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowRoot = NSMenuItem()
        mainMenu.addItem(windowRoot)
        let windowMenu = NSMenu(title: "窗口")
        windowRoot.submenu = windowMenu
        // performMiniaturize / performClose 与标题栏按钮同路由（进托盘 / 退出应用）
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        NSApp.mainMenu = mainMenu
    }

    /// 最小化到托盘后进程仍驻留，不随窗口关闭而退出
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - 窗口

    func showLogWindow() {
        logWindowController.showWindow(nil)
        AppActivation.activateApp()
    }

    private func restoreWindow() {
        logWindowController.showWindow(nil)
        AppActivation.activateApp()
    }

    // MARK: - 退出收尾

    func finishPendingTerminate() {
        guard pendingTerminate else { return }
        pendingTerminate = false
        appendExitLine()
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func appendExitLine() {
        logWindowController.append(LogLine(date: Date(), level: .info, message: "heliport-watchdog 退出"))
    }
}

/// 前置激活：macOS 14 起新旧 activate API 有别，运行期按系统版本选择
enum AppActivation {
    static func activateApp() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    static func activateRunning(_ app: NSRunningApplication) {
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }
}
