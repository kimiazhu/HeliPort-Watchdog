import Foundation

enum Pinger {
    /// 对指定地址执行一次 ICMP ping，返回是否收到应答。
    /// - Parameters:
    ///   - host: 目标 IP 或主机名
    ///   - timeoutSeconds: 整体超时（秒）
    static func ping(host: String, timeoutSeconds: Int = 2) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ping")
        process.arguments = [
            "-c", "1",              // 只发一个探测包
            "-W", "1000",           // 单包等待应答超时 1000ms
            "-t", String(timeoutSeconds),
            host
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Log.error("启动 ping 失败：\(error.localizedDescription)")
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
