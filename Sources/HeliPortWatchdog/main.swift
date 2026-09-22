import Foundation

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

// MARK: - 调试模式

if probeOnly {
    let ok = Pinger.ping(host: config.remoteIP, timeoutSeconds: 2)
    Log.info("probe \(config.remoteIP): \(ok ? "OK（畅通）" : "FAIL（不通）")")
    exit(ok ? 0 : 1)
}

if let target = setPowerTarget {
    do {
        try HeliPort.setPower(on: target)
        Log.info("HeliPort Wi-Fi 开关已处于 \(target ? "on" : "off") 状态")
        exit(0)
    } catch {
        Log.error("设置 HeliPort Wi-Fi 开关失败：\(error)")
        exit(1)
    }
}

// MARK: - 看门狗主循环

Log.info("heliport-watchdog 启动：远端 IP=\(config.remoteIP)，"
    + "判定时长=\(String(format: "%g", config.downThreshold))s，"
    + "探测间隔=\(String(format: "%g", config.pingInterval))s，"
    + "断网时长=\(String(format: "%g", config.offDuration))s")

var failureStart: Date? = nil
// 修复动作后的宽限期：等待 Wi-Fi 重连，期间不计失败，
// 避免重连期间再次触发重启；宽限期在首次 ping 成功时提前结束。
var suppressUntil: Date? = nil

while true {
    let cycleStart = Date()
    let reachable = Pinger.ping(host: config.remoteIP, timeoutSeconds: 2)
    let now = Date()

    if reachable {
        if failureStart != nil {
            Log.info("网络恢复：ping \(config.remoteIP) 成功")
        }
        failureStart = nil
        suppressUntil = nil
    } else {
        if let until = suppressUntil {
            if now < until {
                Log.info("ping \(config.remoteIP) 失败（修复后宽限期内，忽略）")
            } else {
                Log.info("宽限期结束，重新开始统计连续失败时长")
                suppressUntil = nil
                failureStart = nil
            }
        } else {
            if failureStart == nil { failureStart = now }
            let downSeconds = now.timeIntervalSince(failureStart!)
            Log.warn("ping \(config.remoteIP) 失败（已持续 \(Int(downSeconds.rounded(.up)))s）")

            if downSeconds >= config.downThreshold {
                Log.warn("连续 \(String(format: "%g", downSeconds))s ping 不通，"
                    + "重启 HeliPort 网络：关闭 \(String(format: "%g", config.offDuration))s 后重开")
                do {
                    try HeliPort.toggle(offDuration: config.offDuration)
                    Log.info("HeliPort 网络重启完成，等待重连")
                } catch let error as HeliPortError where String(describing: error).contains("辅助功能") {
                    Log.error("\(error)")
                    Log.error("获得权限前无法继续，退出")
                    exit(1)
                } catch {
                    Log.error("HeliPort 网络重启失败：\(error)（稍后自动重试）")
                }
                failureStart = nil
                suppressUntil = Date().addingTimeInterval(max(30, config.downThreshold * 2))
            }
        }
    }

    let elapsed = Date().timeIntervalSince(cycleStart)
    let remaining = config.pingInterval - elapsed
    if remaining > 0 {
        Thread.sleep(forTimeInterval: remaining)
    }
}
