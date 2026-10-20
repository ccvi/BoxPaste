import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// ============================================================
// 图标草案对比图（临时脚本，定稿后可删）
//
//   swift Tools/icon-drafts.swift <A.png> <B.png> <C.png> <输出.png>
//
// 把三个母版按 macOS 真实图标网格渲染出来（1024 画布 → 内容缩到 824、
// 圆角 22.5%），并排给出 240 / 128 / 64 / 32 / 16 px 五档，
// 最后一行放在深色底上——Dock 在深色壁纸下就是那个观感。
// 小尺寸那一列才是真正的判据：16 px 糊不糊，肉眼一看就知道。
// ============================================================

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 4 else {
    FileHandle.standardError.write(Data("用法：swift icon-drafts.swift <A.png> <B.png> <C.png> <输出.png>\n".utf8))
    exit(2)
}

let variantLabels = ["A  剪贴板", "B  双层卡片", "C  开口盒夹纸"]
let variantNotes = ["青碧 / 推荐", "珊瑚", "玫红"]

func loadImage(_ path: String) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

var masters: [CGImage] = []
for path in args[0..<3] {
    guard let image = loadImage(path) else {
        FileHandle.standardError.write(Data("读不到 \(path)\n".utf8))
        exit(1)
    }
    masters.append(image)
}

// ── 画布 ────────────────────────────────────────────────────

let sheetWidth: CGFloat = 1200
let headerHeight: CGFloat = 120
let rowHeight: CGFloat = 310
let darkStripHeight: CGFloat = 210
let sheetHeight = headerHeight + rowHeight * CGFloat(masters.count) + darkStripHeight

let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil,
                          width: Int(sheetWidth), height: Int(sheetHeight),
                          bitsPerComponent: 8, bytesPerRow: 0,
                          space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    exit(1)
}
// y 向下，方便按视觉位置写坐标
ctx.translateBy(x: 0, y: sheetHeight)
ctx.scaleBy(x: 1, y: -1)
ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

// ── 图像绘制（在 y 向下的上下文里，图像必须再翻一次，否则是倒的）──

/// 按 macOS 真实图标网格画：画布 side → 内容 824/1024、圆角 22.5%
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

// ── 底 ─────────────────────────────────────────────────────

ctx.setFillColor(rgb(0xF4F4F7))
ctx.fill(CGRect(x: 0, y: 0, width: sheetWidth, height: sheetHeight))

// ── 表头 ────────────────────────────────────────────────────

drawText("BoxPaste 图标草案", at: CGPoint(x: 40, y: 28), size: 40, weight: .semibold, color: rgb(0x1C1C1E))
drawText("从左到右：240 / 128 / 64 / 32 / 16 px（已按 macOS 图标网格缩进 824/1024）",
         at: CGPoint(x: 40, y: 78), size: 24, weight: .regular, color: rgb(0x6E6E73))

let columns: [(side: CGFloat, x: CGFloat)] = [
    (240, 300), (128, 640), (64, 860), (32, 980), (16, 1050),
]

// ── 三行草案 ────────────────────────────────────────────────

for (index, master) in masters.enumerated() {
    let rowTop = headerHeight + rowHeight * CGFloat(index)

    // 交替底色，行界更清楚
    ctx.setFillColor(rgb(index % 2 == 0 ? 0xFFFFFF : 0xECECF1))
    ctx.fill(CGRect(x: 24, y: rowTop, width: sheetWidth - 48, height: rowHeight))

    drawText(variantLabels[index], at: CGPoint(x: 56, y: rowTop + 118),
             size: 34, weight: .semibold, color: rgb(0x1C1C1E))
    drawText(variantNotes[index], at: CGPoint(x: 56, y: rowTop + 164),
             size: 24, weight: .regular, color: rgb(0x6E6E73))

    for column in columns {
        let y = rowTop + (rowHeight - column.side) / 2
        drawAppIcon(master, side: column.side, at: CGPoint(x: column.x, y: y))
    }
}

// ── 深色底对照（Dock 在深色壁纸下的观感）────────────────────

let stripTop = headerHeight + rowHeight * CGFloat(masters.count)
ctx.setFillColor(rgb(0x1C1C1E))
ctx.fill(CGRect(x: 24, y: stripTop + 8, width: sheetWidth - 48, height: darkStripHeight - 16))

drawText("深色底对照（64 px）", at: CGPoint(x: 56, y: stripTop + 40),
         size: 26, weight: .semibold, color: rgb(0xEBEBF5))

for (index, master) in masters.enumerated() {
    let x = 400 + CGFloat(index) * 220
    drawAppIcon(master, side: 64, at: CGPoint(x: x, y: stripTop + 100))
    drawText(String(["A", "B", "C"][index]), at: CGPoint(x: x + 22, y: stripTop + 174),
             size: 20, weight: .medium, color: rgb(0x98989D))
}

// ── 输出 ────────────────────────────────────────────────────

let outputURL = URL(fileURLWithPath: args[3])
guard let image = ctx.makeImage(),
      let destination = CGImageDestinationCreateWithURL(outputURL as CFURL,
                                                        UTType.png.identifier as CFString, 1, nil) else {
    exit(1)
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { exit(1) }
print("已生成草案对比图 → \(outputURL.path)")
