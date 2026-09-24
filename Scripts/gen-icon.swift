import AppKit

// gen-icon.swift —— 生成 HeliPortWatchdog.app 图标
// 设计：偏黑渐变圆角方框 + 白色加粗斜体字母 H（透明四角，macOS 图标留边）
//
// 用法: swift Scripts/gen-icon.swift <输出目录>
// 输出: <输出目录>/AppIcon.iconset/*.png（随后用 iconutil -c icns 打包）

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("用法: swift Scripts/gen-icon.swift <输出目录>\n".utf8))
    exit(2)
}
let outputDir = URL(fileURLWithPath: args[1], isDirectory: true)
let iconsetDir = outputDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

/// 绘制一个像素尺寸为 pixelSize 的图标，写入指定路径
func render(pixelSize: Int, to url: URL) throws {
    let size = CGFloat(pixelSize)

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "gen-icon", code: 1)
    }
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
        throw NSError(domain: "gen-icon", code: 2)
    }
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }

    // macOS 图标规范：圆角方框占画布约 80%，四角透明
    let inset = size * 0.10
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.225
    let frame = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // 偏黑色：深灰黑渐变（上浅下深）
    let dark = NSGradient(
        starting: NSColor(srgbRed: 0.16, green: 0.16, blue: 0.18, alpha: 1),
        ending: NSColor(srgbRed: 0.06, green: 0.06, blue: 0.07, alpha: 1)
    ) ?? NSGradient(starting: .black, ending: .black)!
    dark.draw(in: frame, angle: -90)

    // 极淡描边，增加轮廓感
    frame.lineWidth = max(2, size * 0.006)
    NSColor(white: 1.0, alpha: 0.10).setStroke()
    frame.stroke()

    // 白色加粗斜体 H
    let font = NSFont(name: "HelveticaNeue-BoldItalic", size: rect.width * 0.72)
        ?? NSFont(name: "Arial Bold Italic", size: rect.width * 0.72)
        ?? NSFont.boldSystemFont(ofSize: rect.width * 0.72)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white
    ]
    let letter = NSAttributedString(string: "H", attributes: attributes)
    let textSize = letter.size()
    let origin = NSPoint(
        x: rect.midX - textSize.width / 2,
        y: rect.midY - textSize.height / 2 + size * 0.008
    )
    letter.draw(at: origin)

    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "gen-icon", code: 3)
    }
    try png.write(to: url)
}

// iconset 标准命名与像素尺寸
let entries: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for entry in entries {
    let url = iconsetDir.appendingPathComponent(entry.name)
    try render(pixelSize: entry.pixels, to: url)
    print("生成 \(entry.name) (\(entry.pixels)px)")
}
print("iconset 目录: \(iconsetDir.path)")
