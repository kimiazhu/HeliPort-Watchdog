import Foundation
@testable import WatchdogCore

// 本文件只 import Foundation、不 import Testing：
// CLT 的 _Testing_Foundation.framework 未携带 Swift module，
// 同一文件同时 import Testing 与 Foundation 会触发无法满足的 cross-import overlay。

final class LogRecorder {
    private(set) var lines: [LogLine] = []
    func append(_ line: LogLine) { lines.append(line) }
    var messages: [String] { lines.map(\.message) }
    var count: Int { lines.count }
    func message(at index: Int) -> String { lines[index].message }
    func level(at index: Int) -> LogLevel { lines[index].level }
}

final class PingStub {
    private var results: [Bool]
    init(_ results: [Bool]) { self.results = results }
    func pop() -> Bool { results.isEmpty ? false : results.removeFirst() }
}

final class ToggleStub {
    private(set) var callCount = 0
    var outcome: HeliPort.ToggleOutcome = .success
    var onCall: (() -> Void)?
    func call(_ sink: HeliPort.LogSink) -> HeliPort.ToggleOutcome {
        callCount += 1
        onCall?()
        return outcome
    }
}

final class ClockStub {
    var now: Date
    init(_ now: Date = Date(timeIntervalSince1970: 1_000_000)) { self.now = now }
    func date() -> Date { now }
    func advance(_ seconds: Double) { now.addTimeInterval(seconds) }
}

/// 构造本地时区的指定时刻，供日志格式断言使用
func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) -> Date {
    var comps = DateComponents()
    comps.year = year
    comps.month = month
    comps.day = day
    comps.hour = hour
    comps.minute = minute
    comps.second = second
    return Calendar.current.date(from: comps)!
}
