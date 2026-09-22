import Foundation

enum Log {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static func emit(_ level: String, _ message: String) {
        print("[\(formatter.string(from: Date()))] [\(level)] \(message)")
    }

    static func info(_ message: String) { emit("INFO", message) }
    static func warn(_ message: String) { emit("WARN", message) }
    static func error(_ message: String) { emit("ERROR", message) }
}
