import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("用法：make_dmg_background.swift 输出路径\n", stderr)
    exit(2)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let size = NSSize(width: 660, height: 420)
let image = NSImage(size: size)

image.lockFocus()

let bounds = NSRect(origin: .zero, size: size)
let background = NSGradient(colors: [
    NSColor(calibratedRed: 0.055, green: 0.075, blue: 0.13, alpha: 1),
    NSColor(calibratedRed: 0.10, green: 0.15, blue: 0.25, alpha: 1)
])!
background.draw(in: bounds, angle: -35)

func drawGlow(center: NSPoint, color: NSColor) {
    for step in stride(from: 8, through: 1, by: -1) {
        let radius = CGFloat(step) * 17
        let alpha = CGFloat(9 - step) * 0.008
        color.withAlphaComponent(alpha).setFill()
        NSBezierPath(ovalIn: NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )).fill()
    }
}

drawGlow(center: NSPoint(x: 160, y: 205), color: .systemBlue)
drawGlow(center: NSPoint(x: 500, y: 205), color: .systemGreen)

let titleStyle: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 25, weight: .semibold),
    .foregroundColor: NSColor.white
]
let title = NSString(string: "安装 Codex Token Bar")
let titleSize = title.size(withAttributes: titleStyle)
title.draw(
    at: NSPoint(x: (size.width - titleSize.width) / 2, y: 348),
    withAttributes: titleStyle
)

let subtitleStyle: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 14, weight: .regular),
    .foregroundColor: NSColor.white.withAlphaComponent(0.68)
]
let subtitle = NSString(string: "将左侧应用拖入右侧“应用程序”文件夹")
let subtitleSize = subtitle.size(withAttributes: subtitleStyle)
subtitle.draw(
    at: NSPoint(x: (size.width - subtitleSize.width) / 2, y: 317),
    withAttributes: subtitleStyle
)

let arrowColor = NSColor(calibratedRed: 0.35, green: 0.72, blue: 1.0, alpha: 0.95)
arrowColor.setStroke()
arrowColor.setFill()

let shaft = NSBezierPath()
shaft.move(to: NSPoint(x: 270, y: 207))
shaft.curve(
    to: NSPoint(x: 402, y: 207),
    controlPoint1: NSPoint(x: 312, y: 225),
    controlPoint2: NSPoint(x: 360, y: 225)
)
shaft.lineWidth = 9
shaft.lineCapStyle = .round
shaft.stroke()

let head = NSBezierPath()
head.move(to: NSPoint(x: 402, y: 207))
head.line(to: NSPoint(x: 378, y: 229))
head.line(to: NSPoint(x: 384, y: 194))
head.close()
head.fill()

let hintStyle: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
    .foregroundColor: NSColor.white.withAlphaComponent(0.84)
]
NSString(string: "拖到这里完成安装").draw(
    at: NSPoint(x: 275, y: 150),
    withAttributes: hintStyle
)

let footerStyle: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 11),
    .foregroundColor: NSColor.white.withAlphaComponent(0.42)
]
let footer = NSString(string: "Codex Token Bar · macOS 13+")
let footerSize = footer.size(withAttributes: footerStyle)
footer.draw(
    at: NSPoint(x: (size.width - footerSize.width) / 2, y: 28),
    withAttributes: footerStyle
)

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
else {
    fputs("无法生成 DMG 背景图\n", stderr)
    exit(1)
}

try png.write(to: outputURL, options: .atomic)
