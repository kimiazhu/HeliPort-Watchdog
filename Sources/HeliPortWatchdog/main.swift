import Foundation
import WatchdogCore

setvbuf(stdout, nil, _IONBF, 0)

// MARK: - 配置与参数

struct Config {
    var remoteIP = "192.168.100.1"
    var downThreshold: TimeInterval = 10
    var pingInterval: TimeInterval = 1
    var offDuration: TimeInterval = 1
}

let usage = """
heliport-watchdog —— HeliPort(itlwm) 网络看门狗

周期性 ping 指定远端地址；若连续失败达到阈值，自动将 HeliPort 的
Wi-Fi 关闭指定时长后再打开（经由 HeliPort 菜单栏图标的 Wi-Fi 开关），
以恢复 itlwm 网络畅通。

用法:
  heliport-watchdog [选项]

选项:
  -ip <地址>           用于判断网络畅通的远端 IP（默认 192.168.100.1）
  -down <秒>           连续 ping 失败多少秒判定网络不通（默认 10）
  -interval <秒>       ping 探测间隔（默认 1）
  -off <秒>            判定不通后 Wi-Fi 关闭多少秒再重开（默认 1）
  -probe               只做一次 ping 探测并退出（调试用）
  -set-power <on|off>  直接设置 HeliPort Wi-Fi 开关状态并退出（调试用）
  -h, --help           显示本帮助

注意:
  控制 HeliPort 菜单依赖辅助功能权限：首次使用需在
  「系统设置 → 隐私与安全性 → 辅助功能」中，为运行本命令的
  终端程序（或 heliport-watchdog 本体）授权。
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("[错误] \(message)\n\n\(usage)\n".utf8))
    exit(2)
}

func parseSeconds(_ raw: String) -> TimeInterval? {
    var text = raw.lowercased()
    if text.hasSuffix("s") { text.removeLast() }
    guard let value = Double(text), value > 0, value < 86400 else { return nil }
    return value
}

var config = Config()
var probeOnly = false
var setPowerTarget: Bool? = nil

var args = Array(CommandLine.arguments.dropFirst())
var index = 0
while index < args.count {
    let arg = args[index]
    switch arg {
    case "-h", "--help", "-help":
        print(usage)
        exit(0)
    case "-ip", "--ip":
        index += 1
        guard index < args.count, !args[index].isEmpty else { fail("参数 \(arg) 需要 IP 地址") }
        config.remoteIP = args[index]
    case "-down", "--down", "-threshold", "--threshold":
        index += 1
        guard index < args.count, let value = parseSeconds(args[index]) else { fail("参数 \(arg) 需要正数秒，如 10") }
        config.downThreshold = value
    case "-interval", "--interval":
        index += 1
        guard index < args.count, let value = parseSeconds(args[index]) else { fail("参数 \(arg) 需要正数秒，如 1") }
        config.pingInterval = value
    case "-off", "--off":
        index += 1
        guard index < args.count, let value = parseSeconds(args[index]) else { fail("参数 \(arg) 需要正数秒，如 1") }
        config.offDuration = value
    case "-probe", "--probe":
        probeOnly = true
    case "-set-power", "--set-power":
        index += 1
        guard index < args.count else { fail("参数 \(arg) 需要 on 或 off") }
        switch args[index].lowercased() {
        case "on": setPowerTarget = true
        case "off": setPowerTarget = false
        default: fail("参数 -set-power 只接受 on 或 off")
        }
    default:
        fail("未知参数：\(arg)")
    }
    index += 1
}

// MARK: - 控制台输出

func emitConsole(_ level: LogLevel, _ message: String) {
    print(LogFormatter.render(LogLine(date: Date(), level: level, message: message)))
}

// MARK: - 调试模式

if probeOnly {
    let ok = Pinger.ping(host: config.remoteIP, timeoutSeconds: 2)
    emitConsole(.info, "probe \(config.remoteIP): \(ok ? "OK（畅通）" : "FAIL（不通）")")
    exit(ok ? 0 : 1)
}

if let target = setPowerTarget {
    do {
        try HeliPort.setPower(on: target)
        emitConsole(.info, "HeliPort Wi-Fi 开关已处于 \(target ? "on" : "off") 状态")
        exit(0)
    } catch {
        // 与 .sh 的 heliport_set_power 错误行一致（assistive 为两行）
        HeliPort.reportError(error, log: emitConsole)
        exit(1)
    }
}

// MARK: - 看门狗主循环（WatchdogEngine，行为对齐 .sh）

let engine = WatchdogEngine(config: WatchdogEngine.Config(
    remoteIP: config.remoteIP,
    downThreshold: config.downThreshold,
    pingInterval: config.pingInterval,
    offDuration: config.offDuration
))
engine.onEvent = { line in
    print(LogFormatter.render(line))
}
// 缺少辅助功能权限时与 .sh 一致：两行 ERROR（由 Engine/HeliPort 记录）后退出
engine.onAssistiveDenied = { exit(1) }

// 与 .sh 的 trap 一致：INT/TERM 记退出日志后以 0 退出
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: DispatchQueue.main)
    source.setEventHandler {
        emitConsole(.info, "heliport-watchdog 退出")
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

engine.start()
dispatchMain() // 主循环跑在引擎线程；主线程负责信号处理
