import Foundation

/// 日志级别，与 .sh 的 log() 级别一致。
/// 配色约定（.sh）：INFO 绿色，WARN/ERROR 红色。
public enum LogLevel: String {
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

/// 单条日志：`[yyyy-MM-dd HH:mm:ss] [LEVEL] message`（秒级精度，对齐 .sh）。
public struct LogLine {
    public let date: Date
    public let level: LogLevel
    public let message: String

    public init(date: Date = Date(), level: LogLevel, message: String) {
        self.date = date
        self.level = level
        self.message = message
    }
}

/// 日志文本格式化。DateFormatter 固定 en_US_POSIX，防止本地化/时区设置漂移。
public enum LogFormatter {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    public static func timestamp(_ date: Date) -> String {
        formatter.string(from: date)
    }

    public static func render(_ line: LogLine) -> String {
        "[\(timestamp(line.date))] [\(line.level.rawValue)] \(line.message)"
    }
}
