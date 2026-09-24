import AppKit
import ServiceManagement
import WatchdogCore

/// 托盘：SF Symbol "wifi"（template）。
/// 左键 → 还原/前置日志窗口；右键 / Ctrl+左键 → 菜单（随系统启动、退出）。
/// NSStatusItem.button 为只读，无法替换为 NSStatusBarButton 子类，
/// 故以 button.action + NSApp.currentEvent 分流实现同等的左/右键行为。
final class StatusItemController: NSObject, NSMenuDelegate {

    var onLeftClick: (() -> Void)?
    /// 登录项操作的提示日志（GUI 汇入日志窗口）
    var log: HeliPort.LogSink = { _, _ in }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let loginItemsItem = NSMenuItem(
        title: "随系统启动",
        action: #selector(toggleLoginItems(_:)),
        keyEquivalent: ""
    )

    override init() {
        super.init()
        guard let button = statusItem.button else { return }
        let icon = NSImage(systemSymbolName: "wifi", accessibilityDescription: "HeliPort Watchdog")
        icon?.isTemplate = true
        button.image = icon
        button.toolTip = "HeliPort Watchdog"
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        loginItemsItem.target = self
        menu.addItem(loginItemsItem)
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit(_:)), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
        menu.delegate = self
    }

    // MARK: - 左/右键分流

    @objc private func handleClick(_ sender: Any) {
        guard let event = NSApp.currentEvent else {
            onLeftClick?()
            return
        }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenu()
        } else {
            onLeftClick?()
        }
    }

    private func showMenu() {
        // 临时挂菜单后模拟点击，保持托盘高亮与定位的原生表现
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    // MARK: - NSMenuDelegate（每次打开重读登录项状态）

    func menuWillOpen(_ menu: NSMenu) {
        refreshLoginItemsState()
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    private func refreshLoginItemsState() {
        // 非 bundle 环境运行（如 swift run）无法注册登录项，菜单项置灰
        guard LoginItems.isBundleApp else {
            loginItemsItem.isEnabled = false
            loginItemsItem.state = .off
            return
        }
        loginItemsItem.isEnabled = true
        loginItemsItem.state = LoginItems.isEnabled() ? .on : .off
    }

    // MARK: - 菜单动作

    @objc private func toggleLoginItems(_ sender: NSMenuItem) {
        do {
            if LoginItems.isEnabled() {
                try LoginItems.setEnabled(false)
                log(.info, "已取消随系统启动")
            } else {
                let needsApproval = try LoginItems.setEnabled(true)
                if needsApproval {
                    log(.info, "已请求随系统启动，请在「系统设置 → 通用 → 登录项」中批准 HeliPortWatchdog")
                } else {
                    log(.info, "已开启随系统启动")
                }
            }
        } catch {
            log(.error, "更新登录项失败：\(error)")
        }
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}
