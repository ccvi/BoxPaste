import AppKit

// ============================================================
// 自定义图标导入器（2026-10-16，用户提供的设计稿）
//
//   swift Tools/import-custom-icon.swift <输入图> [输出.png]
//
// 输入是 800×800 白底 JPG（圆角方块已画好，四角是白底）。
// 做三件事，产出 1024×1024 满幅母版：
//   1. 从四边洪泛填充：把与边缘连通的近白像素抠成透明
//      （图标内部的白色 "b" 字形不与边缘连通，不会误伤）；
//   2. 按非透明内容的包围盒裁出正方形；
//   3. 放大到 1024。
// 圆角与四周留白由 make-icon.swift 统一处理（Apple 图标网格），
// 所以这里给的是"满幅方图"，不要再自己留边。
// ============================================================

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("用法：swift import-custom-icon.swift <输入图> [输出.png]\n".utf8))
    exit(2)
}
let inURL = URL(fileURLWithPath: arguments[1])
let outURL = URL(fileURLWithPath: arguments.count > 2 ? arguments[2] : "Resources/custom-icon-master.png")

guard let img = NSImage(contentsOf: inURL),
      let tiff = img.tiffRepresentation,
      let srcRep = NSBitmapImageRep(data: tiff) else {
    FileHandle.standardError.write(Data("读不到输入图：\(inURL.path)\n".utf8))
    exit(1)
}
let w = srcRep.pixelsWide, h = srcRep.pixelsHigh

// 统一转成 8bit RGBA，免得 JPEG 解出来是别的位深/通道布局
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
NSGraphicsContext.restoreGraphicsState()

guard let buf = rep.bitmapData else {
    FileHandle.standardError.write(Data("拿不到像素缓冲\n".utf8))
    exit(1)
}

func isNearWhite(_ x: Int, _ y: Int) -> Bool {
    let o = (y * w + x) * 4
    // 235：JPEG 压缩会让纯白抖到 ~245，淡阴影灰一般到不了 235 以上
    return buf[o] > 235 && buf[o + 1] > 235 && buf[o + 2] > 235
}

// ── 1. 从四边洪泛填充近白像素 → 透明 ─────────────────────────
var visited = [Bool](repeating: false, count: w * h)
var queue: [Int] = []
for x in 0..<w {
    for y in [0, h - 1] where isNearWhite(x, y) && !visited[y * w + x] {
        visited[y * w + x] = true; queue.append(y * w + x)
    }
}
for y in 0..<h {
    for x in [0, w - 1] where isNearWhite(x, y) && !visited[y * w + x] {
        visited[y * w + x] = true; queue.append(y * w + x)
    }
}
while let i = queue.popLast() {
    let x = i % w, y = i / w
    buf[(y * w + x) * 4 + 3] = 0
    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
        let nx = x + dx, ny = y + dy
        guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
        let ni = ny * w + nx
        if !visited[ni] && isNearWhite(nx, ny) { visited[ni] = true; queue.append(ni) }
    }
}

// ── 2. 非透明内容的包围盒 → 正方形 ───────────────────────────
var minX = w, maxX = -1, minY = h, maxY = -1
for y in 0..<h {
    for x in 0..<w where buf[(y * w + x) * 4 + 3] > 0 {
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
    }
}
guard maxX > minX, maxY > minY else {
    FileHandle.standardError.write(Data("抠底后没有内容——阈值可能不对\n".utf8))
    exit(1)
}
var side = max(maxX - minX + 1, maxY - minY + 1)
// 裁剪框可能探出画布（内容贴边时），夹回画布内
let cropX = min(max((minX + maxX - side) / 2, 0), w - side)
let cropYPixels = min(max((minY + maxY - side) / 2, 0), h - side)
side = min(side, w, h)

// 位图像素 y 是从上往下数的；NSImage 绘图坐标 y 是从下往上数的。
// 像素区间 [cropYPixels, cropYPixels+side) 映射到点坐标 y ∈ [h-(cropYPixels+side), h-cropYPixels)
let cropRect = NSRect(x: CGFloat(cropX),
                      y: CGFloat(h - cropYPixels - side),
                      width: CGFloat(side), height: CGFloat(side))

let composed = NSImage(size: NSSize(width: w, height: h))
composed.addRepresentation(rep)

let cropped = NSImage(size: cropRect.size)
cropped.lockFocus()
composed.draw(in: NSRect(origin: NSPoint(x: -cropRect.minX, y: -cropRect.minY),
                         size: NSSize(width: w, height: h)))
cropped.unlockFocus()

// ── 3. 放大到 1024 满幅 ─────────────────────────────────────
let final = NSImage(size: NSSize(width: 1024, height: 1024))
final.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high
cropped.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
final.unlockFocus()

guard let outTiff = final.tiffRepresentation,
      let outRep = NSBitmapImageRep(data: outTiff),
      let png = outRep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else {
    FileHandle.standardError.write(Data("PNG 编码失败\n".utf8))
    exit(1)
}
try! png.write(to: outURL)
print("已生成：\(outURL.path)（内容包围盒 x[\(minX),\(maxX)] y[\(minY),\(maxY)]，裁剪 \(Int(cropRect.width))px）")
