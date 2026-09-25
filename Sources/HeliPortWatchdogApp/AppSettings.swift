import Foundation
import WatchdogCore

/// 配置持久化：UserDefaults 存 JSON，key 带版本号。
/// 「保存配置」点击时写入；启动时读取，缺失/损坏/越界回落 .sh 默认值。
enum AppSettings {

    private static let key = "watchdog.config.v1"

    private struct Payload: Codable {
        var remoteIP: String
        var downThreshold: TimeInterval
        var pingInterval: TimeInterval
        var offDuration: TimeInterval
    }

    static func load() -> WatchdogEngine.Config {
        let defaults = WatchdogEngine.Config()
        guard let data = UserDefaults.standard.data(forKey: key),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return defaults
        }
        return WatchdogEngine.Config(
            remoteIP: payload.remoteIP.isEmpty ? defaults.remoteIP : payload.remoteIP,
            downThreshold: max(1, payload.downThreshold),
            pingInterval: max(1, payload.pingInterval),
            offDuration: max(1, payload.offDuration)
        )
    }

    static func save(_ config: WatchdogEngine.Config) {
        let payload = Payload(
            remoteIP: config.remoteIP,
            downThreshold: config.downThreshold,
            pingInterval: config.pingInterval,
            offDuration: config.offDuration
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
