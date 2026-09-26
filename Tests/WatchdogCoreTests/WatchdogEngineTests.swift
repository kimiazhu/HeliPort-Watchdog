import Testing
@testable import WatchdogCore

// 注意：本文件不可 import Foundation —— CLT 的 _Testing_Foundation.framework
// 未携带 Swift module，同文件同时 import Testing 与 Foundation 会编译失败。
// 需要 Foundation 的桩与工具见 TestSupport.swift（仅 import Foundation）。

// MARK: - Engine 状态机（逐行对齐 heliport-watchdog.sh 主循环）

@Suite("WatchdogEngine 状态机")
struct WatchdogEngineTests {

    private let ip = "192.168.100.1"

    private func failWarn(_ count: Int, _ down: Int) -> String {
        "ping \(ip) 失败（连续失败 \(count) 次，已持续 \(down)s）"
    }
    private func graceWarn(_ count: Int) -> String {
        "ping \(ip) 失败（连续失败 \(count) 次，修复后宽限期内，忽略）"
    }

    private func makeEngine(
        config: WatchdogEngine.Config = WatchdogEngine.Config(),
        ping: PingStub,
        toggle: ToggleStub = ToggleStub(),
        clock: ClockStub = ClockStub()
    ) -> (engine: WatchdogEngine, log: LogRecorder) {
        let log = LogRecorder()
        let engine = WatchdogEngine(
            config: config,
            ping: { _ in ping.pop() },
            toggle: { sink in toggle.call(sink) },
            clock: { clock.date() }
        )
        engine.onEvent = { log.append($0) }
        return (engine, log)
    }

    /// 每个 cycle 用当前时钟执行，随后时钟前进 step
    private func runFailCycles(_ engine: WatchdogEngine, clock: ClockStub, count: Int, step: Double = 1) {
        for _ in 0..<count {
            engine.cycle()
            clock.advance(step)
        }
    }

    // MARK: 普通失败：计数累计与持续时长（首败 Ds=0s）

    @Test("普通失败：计数累计与持续时长（首败 0s）")
    func failureCountAccumulatesWithDuration() {
        let ping = PingStub([false, false, false])
        let clock = ClockStub()
        let toggle = ToggleStub()
        let (engine, log) = makeEngine(ping: ping, toggle: toggle, clock: clock)

        runFailCycles(engine, clock: clock, count: 3)

        #expect(log.count == 3)
        #expect(log.level(at: 0) == .warn)
        #expect(log.message(at: 0) == failWarn(1, 0), "首败已持续 0s")
        #expect(log.message(at: 1) == failWarn(2, 1))
        #expect(log.message(at: 2) == failWarn(3, 2))
        #expect(toggle.callCount == 0)
    }

    // MARK: 达阈值触发 toggle：触发行、完成行，随后计数清零进宽限期

    @Test("达阈值触发 toggle 并进入宽限期")
    func thresholdTriggersToggleThenGrace() {
        let ping = PingStub([Bool](repeating: false, count: 12))
        let clock = ClockStub()
        let toggle = ToggleStub()
        let (engine, log) = makeEngine(ping: ping, toggle: toggle, clock: clock)

        runFailCycles(engine, clock: clock, count: 12)

        #expect(toggle.callCount == 1)
        // 10 个未达阈值周期（log[0..9]）+ 触发周期 3 行 + 宽限期 1 行
        #expect(log.count == 14)
        #expect(log.message(at: 10) == failWarn(11, 10))
        #expect(log.level(at: 11) == .warn)
        #expect(log.message(at: 11) == "连续 10s ping 不通（连续失败 11 次），重启 HeliPort 网络：关闭 1s 后重开")
        #expect(log.level(at: 12) == .info)
        #expect(log.message(at: 12) == "HeliPort 网络重启完成，等待重连")
        #expect(log.message(at: 13) == graceWarn(1), "toggle 后计数清零并进入宽限期")
    }

    // MARK: 宽限期内失败：抑制不触发，但计数继续累计

    @Test("宽限期内失败：抑制不触发但计数累计")
    func gracePeriodSuppressesToggleButCountsFailures() {
        let ping = PingStub([Bool](repeating: false, count: 20))
        let clock = ClockStub()
        let toggle = ToggleStub()
        let (engine, log) = makeEngine(ping: ping, toggle: toggle, clock: clock)

        // 触发一次 toggle（11 个失败周期）
        runFailCycles(engine, clock: clock, count: 11)
        #expect(toggle.callCount == 1)
        let graceStart = log.count

        // 宽限期内继续失败 3 次
        runFailCycles(engine, clock: clock, count: 3)

        #expect(toggle.callCount == 1, "宽限期内不得再次触发 toggle")
        #expect(log.count == graceStart + 3)
        #expect(log.message(at: graceStart) == graceWarn(1))
        #expect(log.message(at: graceStart + 1) == graceWarn(2))
        #expect(log.message(at: graceStart + 2) == graceWarn(3))
        for index in graceStart..<(graceStart + 3) {
            #expect(log.level(at: index) == .warn)
        }
    }

    // MARK: 成功清零（含提前结束宽限期）

    @Test("成功清零并提前结束宽限期")
    func successResetsCounterAndEndsGraceEarly() {
        let ping = PingStub([Bool](repeating: false, count: 13) + [true, false])
        let clock = ClockStub()
        let (engine, log) = makeEngine(ping: ping, clock: clock)

        // 触发 toggle 并在宽限期内失败 2 次（计数 2）
        runFailCycles(engine, clock: clock, count: 13)
        // 成功：宽限期提前结束
        engine.cycle()
        #expect(log.level(at: log.count - 1) == .info)
        #expect(log.message(at: log.count - 1) == "网络恢复：ping \(ip) 成功（连续失败计数 2 已清零）")
        clock.advance(1)
        // 再失败：不在宽限期内，从头计数
        engine.cycle()
        #expect(log.message(at: log.count - 1) == failWarn(1, 0))
        #expect(log.level(at: log.count - 1) == .warn)
    }

    @Test("健康状态连续成功不输出日志")
    func successWhenHealthyEmitsNothing() {
        let ping = PingStub([true, true, true])
        let clock = ClockStub()
        let (engine, log) = makeEngine(ping: ping, clock: clock)

        runFailCycles(engine, clock: clock, count: 3)
        #expect(log.count == 0, "健康状态下连续成功不应输出任何日志")
    }

    // MARK: 宽限期结束：时长重新统计、计数不清零、本次不记失败不触发

    @Test("宽限期结束：时长重新统计、计数不清零")
    func gracePeriodEndRestartsDurationButKeepsCounter() {
        let ping = PingStub([Bool](repeating: false, count: 20))
        let clock = ClockStub()
        let toggle = ToggleStub()
        let (engine, log) = makeEngine(ping: ping, toggle: toggle, clock: clock)

        // 触发 toggle：周期 1-11，触发发生在时钟 T+10，宽限至 T+40
        runFailCycles(engine, clock: clock, count: 11)
        #expect(toggle.callCount == 1)
        #expect(log.count == 13)

        // T+11、T+21、T+31：宽限期内，计数累计（toggle 后计数已清零，从 1 起算）
        runFailCycles(engine, clock: clock, count: 3, step: 10)
        #expect(log.message(at: 13) == graceWarn(1))
        #expect(log.message(at: 14) == graceWarn(2))
        #expect(log.message(at: 15) == graceWarn(3))

        // 循环后时钟 = T+41，恰好 >= 宽限截止 T+40：宽限期结束
        // （计数不清零 = 4，本次不记失败行、不触发 toggle）
        engine.cycle()
        #expect(toggle.callCount == 1, "宽限期结束的周期不应触发 toggle")
        #expect(log.level(at: 16) == .info)
        #expect(log.message(at: 16) == "宽限期结束，重新开始统计连续失败时长（连续失败 4 次）")

        // 下一次失败：时长重新统计（0s），计数延续（5）
        clock.advance(1)
        engine.cycle()
        #expect(log.message(at: 17) == failWarn(5, 0))
    }

    // MARK: toggle 失败 → ERROR；宽限期照常进入

    @Test("toggle 失败记 ERROR 并进入宽限期")
    func toggleFailureLogsErrorAndEntersGrace() {
        let ping = PingStub([Bool](repeating: false, count: 12))
        let clock = ClockStub()
        let toggle = ToggleStub()
        toggle.outcome = .failed
        let (engine, log) = makeEngine(ping: ping, toggle: toggle, clock: clock)

        runFailCycles(engine, clock: clock, count: 12)

        #expect(log.level(at: 11) == .warn, "log[11] 是触发行")
        #expect(log.level(at: 12) == .error)
        #expect(log.message(at: 12) == "HeliPort 网络重启失败（稍后自动重试）")
        #expect(log.message(at: 13) == graceWarn(1))
    }

    // MARK: 缺辅助功能权限（GUI 模式）：不退出，记 ERROR 并进宽限期防刷屏

    @Test("缺辅助功能权限（GUI）：不退出进宽限期")
    func assistiveDeniedGuiModeLogsErrorAndEntersGrace() {
        let ping = PingStub([Bool](repeating: false, count: 12))
        let clock = ClockStub()
        let toggle = ToggleStub()
        toggle.outcome = .assistiveDenied
        let (engine, log) = makeEngine(ping: ping, toggle: toggle, clock: clock)
        // 不设置 onAssistiveDenied → GUI 行为：不退出
        var toggleFinished = false
        engine.onToggleDidFinish = { toggleFinished = true }

        runFailCycles(engine, clock: clock, count: 12)

        #expect(log.level(at: 12) == .error)
        #expect(log.message(at: 12) == "HeliPort 网络重启失败（稍后自动重试）")
        #expect(log.message(at: 13) == graceWarn(1))
        #expect(toggleFinished, "GUI 模式 toggle 正常返回，主循环继续")
    }

    // MARK: 缺辅助功能权限（CLI 模式）：回调触发（CLI 据此 exit(1)），不再记额外失败行

    @Test("缺辅助功能权限（CLI）：触发退出回调")
    func assistiveDeniedCliModeInvokesHandler() {
        let ping = PingStub([Bool](repeating: false, count: 12))
        let clock = ClockStub()
        let toggle = ToggleStub()
        toggle.outcome = .assistiveDenied
        let (engine, log) = makeEngine(ping: ping, toggle: toggle, clock: clock)
        var deniedCount = 0
        engine.onAssistiveDenied = { deniedCount += 1 }

        runFailCycles(engine, clock: clock, count: 12)

        #expect(deniedCount == 1)
        // 真实 HeliPort.toggle 会先经 sink 记两行权限 ERROR（fake 未模拟）；
        // CLI 模式下引擎不再记 "重启失败" 行，直接由回调退出
        #expect(log.count == 13)
        #expect(log.message(at: 12) == graceWarn(1))
    }

    // MARK: toggle 在途标志与完成回调（退出守卫依据）

    @Test("toggle 在途标志与完成回调")
    func toggleInProgressFlagAndFinishCallback() {
        let ping = PingStub([Bool](repeating: false, count: 11))
        let clock = ClockStub()
        let toggle = ToggleStub()
        let (engine, _) = makeEngine(ping: ping, toggle: toggle, clock: clock)
        var inProgressDuringToggle = false
        var finishCount = 0
        toggle.onCall = { inProgressDuringToggle = engine.isToggleInProgress }
        engine.onToggleDidFinish = { finishCount += 1 }

        #expect(!engine.isToggleInProgress)
        runFailCycles(engine, clock: clock, count: 11)

        #expect(inProgressDuringToggle)
        #expect(!engine.isToggleInProgress, "toggle 结束后标志必须复位")
        #expect(finishCount == 1)
    }

    // MARK: run()：启动日志行 + 每周期无条件 sleep(interval)

    @Test("run()：启动日志行与无条件周期 sleep")
    func runEmitsStartupLineAndSleepsUnconditionally() {
        final class Stopper {
            weak var engine: WatchdogEngine?
            var sleeps: [Double] = []
            func sleep(_ interval: Double) {
                sleeps.append(interval)
                if sleeps.count >= 3 { engine?.stop() }
            }
        }
        let stopper = Stopper()
        let clock = ClockStub()
        let log = LogRecorder()
        let engine = WatchdogEngine(
            config: WatchdogEngine.Config(),
            ping: { _ in true },
            toggle: { _ in .success },
            clock: { clock.date() },
            sleep: { stopper.sleep($0) }
        )
        stopper.engine = engine
        engine.onEvent = { log.append($0) }

        engine.run() // 阻塞直至 stop

        #expect(log.count == 1)
        #expect(log.level(at: 0) == .info)
        #expect(log.message(at: 0) == "heliport-watchdog 启动：远端 IP=192.168.100.1，判定时长=10s，探测间隔=1s，断网时长=1s，启动延迟=0s")
        // 每周期无条件 sleep(1)，即使 ping 一直成功
        #expect(stopper.sleeps == [1.0, 1.0, 1.0])
    }

    // MARK: run()：启动延迟期间不探测，延迟结束才开始主循环

    @Test("run()：启动延迟期间不探测，延迟结束才开始")
    func runWaitsStartupDelayBeforeProbing() {
        final class Stopper {
            weak var engine: WatchdogEngine?
            var sleeps: [Double] = []
            var pingCount = 0
            func sleep(_ interval: Double) {
                sleeps.append(interval)
                if sleeps.count >= 4 { engine?.stop() } // 延迟 3 次 sleep + 首个周期 sleep 后停止
            }
        }
        let stopper = Stopper()
        let clock = ClockStub()
        let log = LogRecorder()
        let engine = WatchdogEngine(
            config: WatchdogEngine.Config(startDelay: 3),
            ping: { _ in stopper.pingCount += 1; return true },
            toggle: { _ in .success },
            clock: { clock.date() },
            sleep: { stopper.sleep($0) }
        )
        stopper.engine = engine
        engine.onEvent = { log.append($0) }

        engine.run() // 阻塞直至 stop

        // 延迟按 ≤1s 步进等待，期间不 ping；之后才进入主循环
        #expect(stopper.sleeps == [1.0, 1.0, 1.0, 1.0])
        #expect(stopper.pingCount == 1)
        #expect(log.count == 3)
        #expect(log.level(at: 0) == .info)
        #expect(log.message(at: 0) == "heliport-watchdog 启动：远端 IP=192.168.100.1，判定时长=10s，探测间隔=1s，断网时长=1s，启动延迟=3s")
        #expect(log.message(at: 1) == "启动延迟探测：等待 3s 后开始（等待 HeliPort 就绪）")
        #expect(log.message(at: 2) == "启动延迟结束，开始探测")
    }

    // MARK: run()：启动延迟期间 stop() 立即退出且不探测

    @Test("run()：启动延迟期间 stop 立即退出且不探测")
    func runStopDuringStartupDelayExitsWithoutProbing() {
        final class Stopper {
            weak var engine: WatchdogEngine?
            var sleeps: [Double] = []
            var pingCount = 0
            func sleep(_ interval: Double) {
                sleeps.append(interval)
                engine?.stop()
            }
        }
        let stopper = Stopper()
        let clock = ClockStub()
        let log = LogRecorder()
        let engine = WatchdogEngine(
            config: WatchdogEngine.Config(startDelay: 60),
            ping: { _ in stopper.pingCount += 1; return true },
            toggle: { _ in .success },
            clock: { clock.date() },
            sleep: { stopper.sleep($0) }
        )
        stopper.engine = engine
        engine.onEvent = { log.append($0) }

        engine.run() // 首次步进 sleep 即 stop，等待中断退出

        #expect(stopper.sleeps == [1.0])
        #expect(stopper.pingCount == 0, "延迟期间被 stop 不应执行任何探测")
        #expect(log.count == 2, "只保留启动行与延迟等待行，无「延迟结束」行")
        #expect(log.message(at: 1) == "启动延迟探测：等待 60s 后开始（等待 HeliPort 就绪）")
    }

    // MARK: updateConfig：运行期更新配置即时生效（GUI 保存配置依据）

    @Test("updateConfig：新配置在后续周期生效")
    func updateConfigAppliesToSubsequentCycles() {
        let ping = PingStub([false, false, false])
        let clock = ClockStub()
        let toggle = ToggleStub()
        let (engine, log) = makeEngine(ping: ping, toggle: toggle, clock: clock)

        engine.updateConfig(WatchdogEngine.Config(
            remoteIP: "10.0.0.254",
            downThreshold: 2,
            pingInterval: 1,
            offDuration: 1
        ))

        // T=0：新 IP 首败
        engine.cycle()
        clock.advance(1)
        // T=1：持续 1s < 阈值 2s，不触发
        engine.cycle()
        clock.advance(1)
        #expect(toggle.callCount == 0)
        #expect(log.message(at: 0) == "ping 10.0.0.254 失败（连续失败 1 次，已持续 0s）")
        #expect(log.message(at: 1) == "ping 10.0.0.254 失败（连续失败 2 次，已持续 1s）")

        // T=2：持续 2s ≥ 阈值 2s，触发 toggle（本周期先记失败行，再记触发行）
        engine.cycle()
        #expect(toggle.callCount == 1)
        #expect(log.message(at: 2) == "ping 10.0.0.254 失败（连续失败 3 次，已持续 2s）")
        #expect(log.level(at: 3) == .warn)
        #expect(log.message(at: 3) == "连续 2s ping 不通（连续失败 3 次），重启 HeliPort 网络：关闭 1s 后重开")
        #expect(engine.currentConfig.remoteIP == "10.0.0.254")
    }
}

// MARK: - 日志格式（秒级、en_US_POSIX）

@Suite("LogFormatter 格式")
struct LogFormatterTests {

    @Test("秒级时间戳渲染")
    func renderSecondPrecision() {
        let date = makeDate(year: 2026, month: 9, day: 24, hour: 12, minute: 34, second: 56)
        let line = LogLine(date: date, level: .warn, message: "ping 失败")
        #expect(LogFormatter.render(line) == "[2026-09-24 12:34:56] [WARN] ping 失败")
    }

    @Test("级别文案")
    func levelRawValues() {
        #expect(LogLevel.info.rawValue == "INFO")
        #expect(LogLevel.warn.rawValue == "WARN")
        #expect(LogLevel.error.rawValue == "ERROR")
    }
}
