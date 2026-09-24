import AppKit
import WatchdogCore

/// 日志窗口：标题栏只有最小化与关闭（无最大化）；最小化进托盘，关闭退出应用。
/// NSTextView 只读可选、Menlo、彩色行、自动滚底（用户上滚不强拉）、环形保留最近 ~5000 行。
final class LogWindowController: NSWindowController, NSWindowDelegate {

    static let maxRetainedLines = 5000
    private static let trimBatch = 500
    private static let font = NSFont(name: "Menlo-Regular", size: 12)
        ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private var textView: NSTextView?
    private var scrollView: NSScrollView?
    private var bufferedLines: [NSAttributedString] = []
    private var appendsSinceTrim = 0

    init() {
        let window = LogWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 500),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "HeliPort Watchdog"
        window.center()
        super.init(window: window)
        window.delegate = self
        setupContent()
        setupButtons()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 视图

    private func setupContent() {
        guard let window = window else { return }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        scroll.borderType = .noBorder

        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 780, height: 500))
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = true
        text.importsGraphics = false
        text.font = Self.font
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = text

        window.contentView = scroll
        textView = text
        scrollView = scroll
    }

    private func setupButtons() {
        guard let window = window else { return }
        // 标题栏无最大化按钮
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        // 最小化按钮与 Cmd+M（performMiniaturize）同路由：LogWindow.performMiniaturize → 进托盘
        let miniaturize = window.standardWindowButton(.miniaturizeButton)
        miniaturize?.target = window
        miniaturize?.action = #selector(LogWindow.performMiniaturize(_:))
    }

    // MARK: - 追加日志（须在主线程调用）

    func append(_ line: LogLine) {
        assert(Thread.isMainThread)
        guard let text = textView else { return }
        let attr = Self.attributedLine(line)
        bufferedLines.append(attr)
        appendsSinceTrim += 1

        let stick = isAtBottom()
        text.textStorage?.append(attr)
        if appendsSinceTrim >= Self.trimBatch {
            trim(stick: stick)
        }
        if stick {
            scrollToBottom()
        }
    }

    private static func attributedLine(_ line: LogLine) -> NSAttributedString {
        // 对齐 .sh 配色：INFO 绿、WARN/ERROR 红
        let color: NSColor
        switch line.level {
        case .info: color = .systemGreen
        case .warn, .error: color = .systemRed
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(
            string: LogFormatter.render(line) + "\n",
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        )
    }

    // MARK: - 滚动与环形保留

    private func isAtBottom() -> Bool {
        guard let scroll = scrollView, let document = scroll.documentView else { return true }
        return scroll.contentView.bounds.maxY >= document.bounds.height - 2
    }

    private func scrollToBottom() {
        guard let text = textView else { return }
        text.scrollRangeToVisible(NSRange(location: (text.string as NSString).length, length: 0))
    }

    /// 环形保留最近 ~5000 行；仅当视图贴底时重建文本，避免打断用户上滚阅读
    private func trim(stick: Bool) {
        appendsSinceTrim = 0
        guard bufferedLines.count > Self.maxRetainedLines else { return }
        bufferedLines.removeFirst(bufferedLines.count - Self.maxRetainedLines)
        guard stick, let text = textView else { return }
        let full = NSMutableAttributedString()
        for line in bufferedLines {
            full.append(line)
        }
        text.textStorage?.setAttributedString(full)
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 关闭按钮 / Cmd+W → 退出应用
        NSApp.terminate(nil)
        return false
    }
}

/// 自定义窗口：最小化 = 进托盘（隐藏窗口而非 Dock 缩放动画目标），
/// 最小化按钮与 Cmd+M 均路由到 performMiniaturize。
final class LogWindow: NSWindow {
    override func performMiniaturize(_ sender: Any?) {
        orderOut(nil)
    }
}
