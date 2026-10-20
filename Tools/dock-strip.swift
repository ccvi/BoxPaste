import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// ============================================================
// 家族 Dock 对照图（对照工具，不参与打包，可以随时删）
//
//   swift Tools/dock-strip.swift <要博看.png> <BoxDock.png> <BoxPlayer.png> <BoxMusic.png> \
//                                <候选A.png> <候选B.png> <候选C.png> <输出.png>
//
// 单看一张 icon 判断不出「和同门会不会撞色」，只有并排放进同一条 Dock 才看得出来。
// 入参是各项目 Resources/icon-source.png（满幅母版），
// 这里按 macOS 图标网格缩进后画成 Dock 条，候选排在最后一位。
// ============================================================

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 8 else {
    FileHandle.standardError.write(Data("参数不足：需要 4 个同门 + 3 个候选 + 1 个输出\n".utf8))
    exit(2)
}

func loadImage(_ path: String) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

var family: [CGImage] = []
for path in args[0..<4] {
    guard let image = loadImage(path) else {
        FileHandle.standardError.write(Data("读不到 \(path)\n".utf8))
        exit(1)
    }
    family.append(image)
}
var candidates: [CGImage] = []
for path in args[4..<7] {
    guard let image = loadImage(path) else {
        FileHandle.standardError.write(Data("读不到 \(path)\n".utf8))
        exit(1)
    }
    candidates.append(image)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let iconSide: CGFloat = 128
let iconGap: CGFloat = 22
let barPadding: CGFloat = 22
let iconCount = family.count + 1
let barWidth = CGFloat(iconCount) * iconSide + CGFloat(iconCount - 1) * iconGap + barPadding * 2
let barHeight = iconSide + barPadding * 2
let stripHeight: CGFloat = barHeight + 74
let sheetWidth = barWidth + 120
let sheetHeight = 90 + stripHeight * CGFloat(candidates.count)

guard let ctx = CGContext(data: nil,
                          width: Int(sheetWidth), height: Int(sheetHeight),
                          bitsPerComponent: 8, bytesPerRow: 0,
                          space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
ctx.translateBy(x: 0, y: sheetHeight)
ctx.scaleBy(x: 1, y: -1)
ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func drawAppIcon(_ image: CGImage, side: CGFloat, at origin: CGPoint) {
    let contentSide = side * 824 / 1024
    let radius = contentSide * 0.225
    let rect = CGRect(x: origin.x + (side - contentSide) / 2,
                      y: origin.y + (side - contentSide) / 2,
                      width: contentSide, height: contentSide)
    ctx.saveGState()
    ctx.translateBy(x: rect.minX, y: rect.minY + rect.height)
    ctx.scaleBy(x: 1, y: -1)
    let local = CGRect(origin: .zero, size: rect.size)
    ctx.addPath(CGPath(roundedRect: local, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    ctx.draw(image, in: local)
    ctx.restoreGState()
}

func drawText(_ string: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight, color: CGColor) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor(cgColor: color) ?? .black,
    ]
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    NSAttributedString(string: string, attributes: attributes).draw(at: point)
    NSGraphicsContext.restoreGraphicsState()
}

// 底：模拟深色壁纸下的桌面
ctx.setFillColor(rgb(0x24242A))
ctx.fill(CGRect(x: 0, y: 0, width: sheetWidth, height: sheetHeight))

drawText("同门并排对照：要博看 / BoxDock / 盒子播放器 / BoxMusic / BoxPaste（候选）",
         at: CGPoint(x: 60, y: 30), size: 24, weight: .regular, color: rgb(0xEBEBF5))

let candidateNames = ["候选 A（青碧 · 剪贴板）", "候选 B（珊瑚 · 双层卡片）", "候选 C（玫红 · 开口盒夹纸）"]

for (index, candidate) in candidates.enumerated() {
    let stripTop = 90 + stripHeight * CGFloat(index)

    // Dock 条本体
    ctx.setFillColor(rgb(0x5A5A66, 0.42))
    let barRect = CGRect(x: 60, y: stripTop, width: barWidth, height: barHeight)
    ctx.addPath(CGPath(roundedRect: barRect, cornerWidth: 40, cornerHeight: 40, transform: nil))
    ctx.fillPath()
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.10))
    ctx.setLineWidth(1)
    ctx.addPath(CGPath(roundedRect: barRect, cornerWidth: 40, cornerHeight: 40, transform: nil))
    ctx.strokePath()

    // 图标：同门四个 + 候选一个
    for (slot, image) in family.enumerated() {
        let x = 60 + barPadding + CGFloat(slot) * (iconSide + iconGap)
        drawAppIcon(image, side: iconSide, at: CGPoint(x: x, y: stripTop + barPadding))
    }
    let lastX = 60 + barPadding + CGFloat(family.count) * (iconSide + iconGap)
    drawAppIcon(candidate, side: iconSide, at: CGPoint(x: lastX, y: stripTop + barPadding))

    drawText(candidateNames[index], at: CGPoint(x: 60, y: stripTop + barHeight + 16),
             size: 20, weight: .medium, color: rgb(0xEBEBF5))
}

let outputURL = URL(fileURLWithPath: args[7])
guard let image = ctx.makeImage(),
      let destination = CGImageDestinationCreateWithURL(outputURL as CFURL,
                                                        UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { exit(1) }
print("已生成家族对照图 → \(outputURL.path)")
