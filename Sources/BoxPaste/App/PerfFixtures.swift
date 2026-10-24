import AppKit
import Foundation

// ============================================================
// 性能诊断用的合成数据
//
// 只在启动参数带 `--seed-heavy` 时写进 `--store-root` 指定的临时目录，
// **绝不碰用户的真实历史**。用途：复现"预览长文/大图之后内存涨上去"的场景，
// 手头的历史往往是些短文本，量不出问题来。
// ============================================================

enum PerfFixtures {

    static func seed(into root: URL) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ClipStore(root: root)

        // ── 1. 大文本：2 万行、约 1 MB ──
        var lines: [String] = []
        lines.reserveCapacity(20_000)
        for index in 1...10_000 {
            lines.append("第 \(index) 行 · 一些用来撑长度的正文内容 abcdefghijklmnop")
        }
        let bigText = lines.joined(separator: "\n")
        _ = store.insert(ClipboardWatcher.textItem(bigText), maxItems: 100)

        // ── 2. 富文本：带粗体/颜色的 2000 段 ──
        let richText = String(repeating: "富文本段落，带粗体与颜色。\n", count: 1_000)
        var richItem = ClipboardWatcher.textItem(richText)
        let attributed = NSMutableAttributedString(string: richText)
        let full = NSRange(location: 0, length: attributed.length)
        attributed.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 13), range: full)
        attributed.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: full)
        if let rtf = try? attributed.data(from: full,
                                          documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            let name = "\(richItem.hash).rtf"
            try? store.writeBlob(data: rtf, name: name)
            richItem.rtfBlobName = name
        }
        _ = store.insert(richItem, maxItems: 100)

        // ── 3. 大图：3000×2000 ──
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2400, pixelsHigh: 1600,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0) {
            NSGraphicsContext.saveGraphicsState()
            if let context = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.current = context
                NSColor.systemIndigo.setFill()
                NSRect(x: 0, y: 0, width: 2400, height: 1600).fill()
                // 加点噪声让 PNG 不至于压缩成几十 KB：更接近真实截图
                NSColor.white.withAlphaComponent(0.6).setFill()
                for index in stride(from: 0, to: 2400, by: 7) {
                    NSRect(x: index, y: 0, width: 2, height: 1600).fill()
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            if let png = rep.representation(using: .png, properties: [:]) {
                if let item = ClipboardWatcher.imageItem(png: png, store: store) {
                    _ = store.insert(item, maxItems: 100)
                }
            }
        }

        store.save()
        FileHandle.standardError.write(Data("已生成诊断数据：\(store.items.count) 条 @ \(root.path)\n".utf8))
    }
}
