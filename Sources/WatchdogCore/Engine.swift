import Foundation

/// 看门狗引擎：主循环状态机逐行对齐 heliport-watchdog.sh。
///
/// - ping / toggle / 时钟 / 睡眠均可注入，便于单元测试；
/// - 主循环在后台线程执行（`start()`），CLI 也可直接 `run()` 阻塞主线程；
/// - 所有日志经 `onEvent: (LogLine) -> Void` 回调，由调用方决定落点
///   （CLI 打印到控制台，GUI 跳主线程汇入日志窗口）。
public final class WatchdogEngine {

    public struct Config {
        public var remoteIP: String
        public var downThreshold: TimeInterval
        public var pingInterval: TimeInterval
        public var offDuration: TimeInterval

        /// 默认值与 .sh 保持一致：IP=192.168.100.1，down=10s，interval=1s，off=1s
        public init(remoteIP: String = "192.168.100.1",
                    downThreshold: TimeInterval = 10,
                    pingInterval: TimeInterval = 1,
                    offDuration: TimeInterval = 1) {
            self.remoteIP = remoteIP
            self.downThreshold = downThreshold
            self.pingInterval = pingInterval
            self.offDuration = offDuration
        }
    }

    public typealias PingFn = (_ host: String) -> Bool
    public typealias ToggleFn = (_ log: @escaping HeliPort.LogSink) -> HeliPort.ToggleOutcome
    public typealias ClockFn = () -> Date
    public typealias SleepFn = (TimeInterval) -> Void

    /// 每条日志回调（引擎线程触发）。
    public var onEvent: ((LogLine) -> Void)?
    /// toggle 因缺少辅助功能权限被拒时回调。CLI 设置为 exit(1)；
    /// GUI 不设置：引擎记 ERROR 后进入宽限期防刷屏。
    public var onAssistiveDenied: (() -> Void)?
    /// 每次 toggle（无论成败）完成后在引擎线程回调。GUI 用于延迟退出。
    public var onToggleDidFinish: (() -> Void)?

    private let config: Config
    private let ping: PingFn?
    private let toggle: ToggleFn?
    private let clock: ClockFn
    private let sleep: SleepFn

    // 以下状态仅在引擎线程（run/cycle）上读写
    private var failureStart: Date?
    private var suppressUntil: Date?
    private var failCount = 0

    // 跨线程状态
    private let lock = NSLock()
    private var running = false
    private var toggling = false

    public init(config: Config = Config(),
                ping: PingFn? = nil,
                toggle: ToggleFn? = nil,
                clock: @escaping ClockFn = { Date() },
                sleep: @escaping SleepFn = { Thread.sleep(forTimeInterval: $0) }) {
        self.config = config
        self.ping = ping
        self.toggle = toggle
        self.clock = clock
        self.sleep = sleep
    }

    // MARK: - 生命周期

    /// 后台线程启动主循环（GUI 使用）。
    public func start() {
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "heliport-watchdog"
        thread.start()
    }

    /// 请求停止主循环（当前周期执行完后退出；不会打断进行中的 toggle）。
    public func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }

    /// toggle 是否正在进行（跨线程可读；GUI 退出守卫使用）。
    public var isToggleInProgress: Bool {
        lock.lock()
        defer { lock.unlock() }
        return toggling
    }

    /// 阻塞式主循环。CLI 直接在主线程调用；GUI 经 `start()` 在后台线程调用。
    public func run() {
        emit(.info, "heliport-watchdog 启动：远端 IP=\(config.remoteIP)，"
            + "判定时长=\(fmt(config.downThreshold))s，"
            + "探测间隔=\(fmt(config.pingInterval))s，"
            + "断网时长=\(fmt(config.offDuration))s")
        lock.lock()
        running = true
        lock.unlock()
        while isRunning() {
            cycle()
            // 对齐 .sh：每周期无条件 sleep(interval)，不减去 ping 耗时
            sleep(config.pingInterval)
        }
    }

    // MARK: - 状态机

    /// 主循环单次迭代（ping + 状态机判定 + 动作；不含 sleep），供单元测试直接驱动。
    func cycle() {
        let sink: HeliPort.LogSink = { [weak self] level, message in
            self?.emit(level, message)
        }

        let reachable: Bool
        if let ping = ping {
            reachable = ping(config.remoteIP)
        } else {
            reachable = Pinger.ping(host: config.remoteIP, timeoutSeconds: 2) { sink(.error, $0) }
        }
        let now = clock()

        if reachable {
            if failCount > 0 {
                emit(.info, "网络恢复：ping \(config.remoteIP) 成功（连续失败计数 \(failCount) 已清零）")
            }
            // 成功即清空全部失败状态，并提前结束宽限期
            failureStart = nil
            suppressUntil = nil
            failCount = 0
            return
        }

        // 宽限期内失败也计数
        failCount += 1

        if let until = suppressUntil {
            if now < until {
                emit(.warn, "ping \(config.remoteIP) 失败（连续失败 \(failCount) 次，修复后宽限期内，忽略）")
            } else {
                emit(.info, "宽限期结束，重新开始统计连续失败时长（连续失败 \(failCount) 次）")
                // 时长重新统计，计数不清零；本次 ping 不再走失败分支
                suppressUntil = nil
                failureStart = nil
            }
            return
        }

        if failureStart == nil { failureStart = now }
        let down = now.timeIntervalSince(failureStart!)
        let downSeconds = Int(down)
        emit(.warn, "ping \(config.remoteIP) 失败（连续失败 \(failCount) 次，已持续 \(downSeconds)s）")

        guard down >= config.downThreshold else { return }

        emit(.warn, "连续 \(downSeconds)s ping 不通（连续失败 \(failCount) 次），"
            + "重启 HeliPort 网络：关闭 \(fmt(config.offDuration))s 后重开")

        lock.lock()
        toggling = true
        lock.unlock()
        let outcome = runToggle(sink)
        lock.lock()
        toggling = false
        lock.unlock()

        switch outcome {
        case .success:
            emit(.info, "HeliPort 网络重启完成，等待重连")
        case .failed:
            emit(.error, "HeliPort 网络重启失败（稍后自动重试）")
        case .assistiveDenied:
            // 两行权限 ERROR 已由 HeliPort 经 sink 记录；
            // GUI 不退出（与 .sh 的有意偏差），仅记一行失败 ERROR 并进入宽限期防刷屏。
            if onAssistiveDenied == nil {
                emit(.error, "HeliPort 网络重启失败（稍后自动重试）")
            }
        }
        onToggleDidFinish?()

        failureStart = nil
        failCount = 0
        suppressUntil = clock().addingTimeInterval(max(30, config.downThreshold * 2))

        if case .assistiveDenied = outcome {
            onAssistiveDenied?()
        }
    }

    private func runToggle(_ sink: @escaping HeliPort.LogSink) -> HeliPort.ToggleOutcome {
        if let toggle = toggle {
            return toggle(sink)
        }
        return HeliPort.toggle(offDuration: config.offDuration, log: sink)
    }

    // MARK: - 内部

    private func isRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func emit(_ level: LogLevel, _ message: String) {
        onEvent?(LogLine(date: clock(), level: level, message: message))
    }

    /// .sh 中配置均为整数秒，%g 保证 10.0 显示为 "10"
    private func fmt(_ value: TimeInterval) -> String {
        String(format: "%g", value)
    }
}
