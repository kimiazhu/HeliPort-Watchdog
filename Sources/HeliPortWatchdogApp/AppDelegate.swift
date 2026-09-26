import AppKit
import WatchdogCore

/// 组装日志窗口 + 托盘 + 引擎；Engine 事件 hop 主线程。
final class AppDelegate: NSObject, NSApplicationDelegate {

    let engine: WatchdogEngine
    let logWindowController: LogWindowController
    let statusItemController: StatusItemController

    var pendingTerminate = false

    override init() {
        // 启动时读取持久化配置（首次运行为 .sh 默认值）
        let savedConfig = AppSettings.load()

        let logController = LogWindowController(config: savedConfig)
        self.logWindowController = logController

        let engine = WatchdogEngine(config: savedConfig)
        self.engine = engine

        let statusItem = StatusItemController()
        self.statusItemController = statusItem

        super.init()

        logController.onSave = { [weak self] config in
            self?.applyConfig(config)
        }
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

    // MARK: - 配置

    /// 「保存配置」：更新运行中的引擎，并在日志窗口回显生效值
    private func applyConfig(_ config: WatchdogEngine.Config) {
        engine.updateConfig(config)
        let fmt = { (value: TimeInterval) in String(format: "%g", value) }
        logWindowController.append(LogLine(
            date: Date(),
            level: .info,
            message: "配置已保存并生效：远端 IP=\(config.remoteIP)，"
                + "判定时长=\(fmt(config.downThreshold))s，"
                + "探测间隔=\(fmt(config.pingInterval))s，"
                + "断网时长=\(fmt(config.offDuration))s，"
                + "启动延迟=\(fmt(config.startDelay))s"
                + (config.startDelay > 0 ? "（启动延迟在下一次启动应用时生效）" : "")
        ))
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
