import AppKit

// ============================================================
// 菜单栏图标备选方案生成器（只出预览图，不改应用内图标）
//
// 用户要求：参考参考图里那种「粗圆笔画的小写字母 P」风格，
// 把 BoxPaste 的菜单栏图标（现在是描边剪贴板）改成字母 b。
// 本脚本画三版候选，拼一张对照图（深色/浅色菜单栏 + 大图）。
// 用户确认选哪版后，再把对应画法搬进 StatusItemController.statusImage。
//
// 用法：swift Tools/menubar-icon-drafts.swift [--out 路径]
// ============================================================

enum Variant: String, CaseIterable {
    case a = "A 实心 b"
    case b = "B b + 夹子"
    case c = "C 描边 b"

    var note: String {
        switch self {
        case .a: return "最接近参考 P 的气质：粗圆笔画、饱满"
        case .b: return "在 A 的基础上顶一个剪贴板夹子，带品牌记忆点"
        case .c: return "描边风格，和现应用的剪贴板线稿一脉相承"
        }
    }
}

/// 画一个 b 字形。canvas 18×18，菜单栏标准尺寸。
/// - stroke: 笔画宽度（按 18pt 画布设计；内部 scaleBy 会随尺寸等比放大）
/// - withClip: 是否在 stem 顶端加剪贴板夹子
/// - color: 字形颜色（深底预览传白）
func drawGlyph(size: CGFloat, stroke: CGFloat, withClip: Bool, color: NSColor = .black) -> NSImage {
    let s = size / 18.0   // 缩放系数：所有坐标按 18pt 画布设计
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        color.set()
        guard let context = NSGraphicsContext.current?.cgContext else { return true }
        context.scaleBy(x: s, y: s)

        let lineCap: CGLineCap = .round
        // 竖笔（stem）：从顶部一直到底部，圆头。
        // y 大 = 屏幕上方（NSImage flipped:false）。
        let stemX: CGFloat = 5.9
        let stemUpper = withClip ? 13.4 : 15.0    // 给夹子腾出顶端位置
        let stemLower: CGFloat = 3.2
        context.setLineWidth(stroke)
        context.setLineCap(lineCap)
        context.move(to: CGPoint(x: stemX, y: stemUpper))
        context.addLine(to: CGPoint(x: stemX, y: stemLower))
        context.strokePath()

        // 圆碗（bowl）：b 的圆环，圆心在 stem 右侧
        let bowlCenter = CGPoint(x: 10.1, y: 8.6)
        let bowlRadius: CGFloat = 3.8
        // 从正上方起笔、转到正上方收笔，接缝藏在和竖笔相接处
        context.addArc(center: bowlCenter, radius: bowlRadius,
                       startAngle: .pi / 2, endAngle: .pi / 2 + 2 * .pi, clockwise: false)
        context.strokePath()

        if withClip {
            // 剪贴板夹子：压在 stem 顶端上方的一小坨（与现图标同语言）
            let clip = NSBezierPath(roundedRect: NSRect(x: stemX - 2.2, y: 13.2,
                                                        width: 4.4, height: 2.6),
                                    xRadius: 1.1, yRadius: 1.1)
            clip.fill()
        }
        return true
    }
    return image
}

func render(_ image: NSImage, background: NSColor, scale: CGFloat) -> NSBitmapImageRep {
    let px = Int(image.size.width * scale)
    let py = Int(image.size.height * scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: py,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = image.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    background.setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: image.size)).fill()
    image.draw(in: NSRect(origin: .zero, size: image.size))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// ── 拼对照图 ─────────────────────────────────────────────────

let darkBar = NSColor(calibratedRed: 0.16, green: 0.16, blue: 0.18, alpha: 1)
let lightBar = NSColor(calibratedWhite: 0.92, alpha: 1)
let sheetBG = NSColor(calibratedWhite: 0.97, alpha: 1)

let cellW: CGFloat = 220, cellH: CGFloat = 190
let sheet = NSImage(size: NSSize(width: cellW * 3 + 40, height: cellH + 70), flipped: false) { _ in
    sheetBG.setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: NSSize(width: cellW * 3 + 40, height: cellH + 70))).fill()

    let titleFont = NSFont.boldSystemFont(ofSize: 15)
    let noteFont = NSFont.systemFont(ofSize: 10.5)
    let barFont = NSFont.systemFont(ofSize: 10)

    for (index, variant) in Variant.allCases.enumerated() {
        let x0 = 20 + CGFloat(index) * cellW
        let stroke: CGFloat
        let withClip: Bool
        switch variant {
        case .a: stroke = 2.6; withClip = false
        case .b: stroke = 2.6; withClip = true
        case .c: stroke = 1.9; withClip = false
        }

        // 大图预览（96pt，深色底看形状）
        // stroke 不手动乘缩放——drawGlyph 内部 scaleBy 已按尺寸等比放大线宽
        let big = drawGlyph(size: 96, stroke: stroke, withClip: withClip, color: .white)
        let bigCell = NSRect(x: x0 + (cellW - 116) / 2, y: 210, width: 116, height: 116)
        NSColor(calibratedWhite: 0.22, alpha: 1).setFill()
        NSBezierPath(roundedRect: bigCell, xRadius: 10, yRadius: 10).fill()
        big.draw(in: bigCell.insetBy(dx: 10, dy: 10))

        // 深色菜单栏条（3 个图标模拟真实密度）
        let darkStrip = NSRect(x: x0 + 10, y: 168, width: cellW - 20, height: 30)
        darkBar.setFill()
        NSBezierPath(roundedRect: darkStrip, xRadius: 6, yRadius: 6).fill()
        for i in 0..<3 {
            let g = drawGlyph(size: 18, stroke: stroke, withClip: withClip)
            let rep = render(g, background: .clear, scale: 2)
            let img = NSImage(cgImage: rep.cgImage!, size: NSSize(width: 18, height: 18))
            // 深色菜单栏上模板图渲染为白（sourceAtop 只染已有像素，保留透明背景）
            img.lockFocus()
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.setBlendMode(.sourceAtop)
                NSColor.white.setFill()
                ctx.fill(NSRect(x: 0, y: 0, width: 18, height: 18))
                ctx.setBlendMode(.normal)
            }
            img.unlockFocus()
            img.draw(in: NSRect(x: darkStrip.minX + 16 + CGFloat(i) * 30, y: darkStrip.minY + 6, width: 18, height: 18))
        }

        // 浅色菜单栏条
        let lightStrip = NSRect(x: x0 + 10, y: 130, width: cellW - 20, height: 30)
        lightBar.setFill()
        NSBezierPath(roundedRect: lightStrip, xRadius: 6, yRadius: 6).fill()
        for i in 0..<3 {
            let g = drawGlyph(size: 18, stroke: stroke, withClip: withClip)
            g.draw(in: NSRect(x: lightStrip.minX + 16 + CGFloat(i) * 30, y: lightStrip.minY + 6, width: 18, height: 18))
        }

        // 文字
        let title = NSAttributedString(string: variant.rawValue, attributes: [.font: titleFont, .foregroundColor: NSColor.black])
        title.draw(at: NSPoint(x: x0 + 10, y: 100))
        let note = NSAttributedString(string: variant.note, attributes: [.font: noteFont, .foregroundColor: NSColor.gray])
        note.draw(in: NSRect(x: x0 + 10, y: 78, width: cellW - 24, height: 20))
        let barLabel = NSAttributedString(string: "上：深色菜单栏    下：浅色菜单栏", attributes: [.font: barFont, .foregroundColor: NSColor.gray])
        barLabel.draw(at: NSPoint(x: x0 + 10, y: 58))
    }
    return true
}

let out = CommandLine.arguments.count > 2 && CommandLine.arguments[1] == "--out"
    ? CommandLine.arguments[2] : "/tmp/boxpaste-menubar-drafts.png"
guard let tiff = sheet.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else {
    print("生成失败"); exit(1)
}
try! png.write(to: URL(fileURLWithPath: out))
print("已生成：\(out)")
