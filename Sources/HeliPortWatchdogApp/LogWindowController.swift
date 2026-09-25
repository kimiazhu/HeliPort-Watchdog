import AppKit
import WatchdogCore

/// 主窗口：上半部分为配置区（可编辑，保存后持久化并即时生效），下半部分为实时日志。
/// 标题栏只有最小化与关闭（无最大化）；最小化进托盘，关闭退出应用。
/// 日志 NSTextView 只读可选、Menlo、彩色行、自动滚底（用户上滚不强拉）、环形保留最近 ~5000 行。
final class LogWindowController: NSWindowController, NSWindowDelegate {

    static let maxRetainedLines = 5000
    private static let trimBatch = 500
    private static let font = NSFont(name: "Menlo-Regular", size: 12)
        ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    /// 「保存配置」回调（校验通过、已落盘后触发；GUI 层负责更新引擎并回显日志）
    var onSave: ((WatchdogEngine.Config) -> Void)?

    private var ipField: NSTextField!
    private var downField: NSTextField!
    private var intervalField: NSTextField!
    private var offField: NSTextField!
    private var hintLabel: NSTextField!
    private var hintClearWork: DispatchWorkItem?

    private var textView: NSTextView?
    private var scrollView: NSScrollView?
    private var bufferedLines: [NSAttributedString] = []
    private var appendsSinceTrim = 0

    init(config: WatchdogEngine.Config = .init()) {
        let window = LogWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 580),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "HeliPort Watchdog"
        window.minSize = NSSize(width: 660, height: 470)
        window.center()
        super.init(window: window)
        window.delegate = self
        setupContent(config: config)
        setupButtons()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 视图

    private func setupContent(config: WatchdogEngine.Config) {
        guard let window = window, let contentView = window.contentView else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.distribution = .fill
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        // -- 配置区 --
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 12
        grid.columnSpacing = 16
        // 标签列靠左，输入框列填满剩余宽度（grid 经 stack .width 对齐拉伸到全宽）
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .fill

        ipField = makeField(placeholder: "192.168.100.1")
        downField = makeField(placeholder: "10")
        intervalField = makeField(placeholder: "1")
        offField = makeField(placeholder: "1")
        ipField.stringValue = config.remoteIP
        downField.stringValue = formatSeconds(config.downThreshold)
        intervalField.stringValue = formatSeconds(config.pingInterval)
        offField.stringValue = formatSeconds(config.offDuration)

        grid.addRow(with: [makeLabel("目标地址"), ipField])
        grid.addRow(with: [makeLabel("判断为网络不通时长（秒）"), downField])
        grid.addRow(with: [makeLabel("PING 间隔（秒）"), intervalField])
        grid.addRow(with: [makeLabel("网络不通后关闭 WiFi 时长（秒）"), offField])

        let saveButton = NSButton(title: "保存配置", target: self, action: #selector(saveConfig(_:)))
        saveButton.bezelStyle = .rounded
        saveButton.font = .systemFont(ofSize: 15)
        let buttonRow = NSView()
        buttonRow.addSubview(saveButton)
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            saveButton.centerXAnchor.constraint(equalTo: buttonRow.centerXAnchor),
            saveButton.topAnchor.constraint(equalTo: buttonRow.topAnchor),
            saveButton.bottomAnchor.constraint(equalTo: buttonRow.bottomAnchor),
        ])

        hintLabel = NSTextField(labelWithString: "")
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.isHidden = true

        let separator = NSBox()
        separator.boxType = .separator

        // -- 日志区 --
        let logScroll = makeLogArea()
        logScroll.setContentHuggingPriority(.init(1), for: .vertical)

        stack.addArrangedSubview(grid)
        stack.addArrangedSubview(buttonRow)
        stack.addArrangedSubview(hintLabel)
        stack.addArrangedSubview(separator)
        stack.addArrangedSubview(logScroll)
        stack.setCustomSpacing(4, after: buttonRow)
        stack.setCustomSpacing(14, after: hintLabel)

        // 须以默认 contentView 为父视图打边距约束；
        // 直接把 stack 设为 contentView 会造成对自身的自引用约束（失效），边距丢失
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            logScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
    }

    private func makeLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 15)
        return label
    }

    private func makeField(placeholder: String) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 15)
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    private func makeLogArea() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = false
        scroll.borderType = .noBorder

        // 初始宽度必须为 0：autoresizing .width 会把 clip 视图首次布局的宽度增量
        // 累加到初始宽度上（非 0 会得到 2 倍宽度），导致容器过宽、长行永不换行
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 0, height: 300))
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

        textView = text
        scrollView = scroll
        return scroll
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

    // MARK: - 配置保存

    @objc private func saveConfig(_ sender: Any) {
        let ip = ipField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ip.isEmpty else {
            return showHint("保存失败：目标地址不能为空", error: true)
        }
        guard let down = parseSeconds(downField, lowerBound: 1, upperBound: 86_400) else {
            return showHint("保存失败：「判断为网络不通时长」需为 1–86400 的整数秒", error: true)
        }
        guard let interval = parseSeconds(intervalField, lowerBound: 1, upperBound: 3_600) else {
            return showHint("保存失败：「PING 间隔」需为 1–3600 的整数秒", error: true)
        }
        guard let off = parseSeconds(offField, lowerBound: 1, upperBound: 3_600) else {
            return showHint("保存失败：「网络不通后关闭 WiFi 时长」需为 1–3600 的整数秒", error: true)
        }

        let config = WatchdogEngine.Config(
            remoteIP: ip,
            downThreshold: TimeInterval(down),
            pingInterval: TimeInterval(interval),
            offDuration: TimeInterval(off)
        )
        AppSettings.save(config)
        showHint("配置已保存，下次启动自动加载", error: false)
        onSave?(config)
    }

    private func parseSeconds(_ field: NSTextField, lowerBound: Int, upperBound: Int) -> Int? {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(text), value >= lowerBound, value <= upperBound else { return nil }
        return value
    }

    /// .sh 中配置均为整数秒，%g 保证 10.0 显示为 "10"
    private func formatSeconds(_ value: TimeInterval) -> String {
        String(format: "%g", value)
    }

    private func showHint(_ text: String, error: Bool) {
        hintClearWork?.cancel()
        hintClearWork = nil
        hintLabel.stringValue = text
        hintLabel.textColor = error ? .systemRed : .systemGreen
        hintLabel.isHidden = false
        guard !error else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.hintLabel.isHidden = true
        }
        hintClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
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
        // 长行按词换行（无横向滚动条）；续行缩进 24pt，与首行区分、表明非新日志
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.headIndent = 24
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
