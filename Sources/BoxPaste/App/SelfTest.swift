import AppKit
import Carbon.HIToolbox
import Foundation

// ============================================================
// 自检
//
// 用 `BoxPaste --selftest` 运行，也作为 build-app.sh 的发布门禁。
// 只覆盖**纯逻辑**：颜色/链接识别、去重与淘汰、规则匹配、存储往返、
// 导入导出往返、键位编解码、配置向后兼容。
//
// 为什么不测剪贴板与窗口：那两样需要真实系统状态和 GUI 会话，测出来的
// 是"这台机器现在什么样"，不是"代码对不对"。它们的问题靠手测剧本覆盖
// （见 build-app.sh 末尾的首次使用说明）。
// ============================================================

enum SelfTest {

    private static var failures = 0
    private static var checks = 0

    private static func check(_ condition: Bool, _ label: String, detail: String = "") {
        checks += 1
        if condition {
            print("✓ \(label)")
        } else {
            failures += 1
            print("✗ \(label)\(detail.isEmpty ? "" : " —— \(detail)")")
        }
    }

    private static func equal<T: Equatable>(_ lhs: T, _ rhs: T, _ label: String) {
        check(lhs == rhs, label, detail: "得到 \(lhs)，期望 \(rhs)")
    }

    static func run() -> Int32 {
        print("BoxPaste 自检")
        print("────────────────────────────────────────")

        colorTests()
        linkTests()
        storeTests()
        expiryTests()
        ruleTests()
        importExportTests()
        richTextTests()
        imageCaptureTests()
        blobGCTests()
        previewTests()
        memoryHygieneTests()
        shortcutTests()
        preferenceTests()
        formatTests()

        print("────────────────────────────────────────")
        if failures == 0 {
            print("全部通过（\(checks) 项）")
            return 0
        }
        print("失败 \(failures) / \(checks) 项")
        return 1
    }

    // ── 颜色 ─────────────────────────────────────────────────

    private static func colorTests() {
        // 六位
        if let color = ContentClassifier.parseColor("#1A2B3C") {
            equal(color.hex, "#1A2B3C", "六位 HEX 解析")
            equal(color.rgbString, "rgb(26, 43, 60)", "六位 HEX 的 RGB 写法")
            // 26/255 = 0.10196…；用字节反推，确认双向一致
            equal(Int((color.red * 255).rounded()), 26, "红色分量")
            equal(Int((color.blue * 255).rounded()), 60, "蓝色分量")
        } else {
            check(false, "六位 HEX 解析", detail: "返回 nil")
        }

        // 三位缩写要展开成每位重复
        if let color = ContentClassifier.parseColor("#f0a") {
            equal(color.hex, "#FF00AA", "三位缩写展开")
        } else {
            check(false, "三位缩写展开", detail: "返回 nil")
        }

        // 八位带透明度：alpha < 1 时 HEX 才补两位
        if let color = ContentClassifier.parseColor("#11223344") {
            equal(color.hex, "#11223344", "八位 HEX 保留透明度")
            check(color.alpha < 1, "八位 HEX 的 alpha < 1")
        } else {
            check(false, "八位 HEX 保留透明度", detail: "返回 nil")
        }

        equal(ContentClassifier.parseColor("0x00FF00")?.hex, "#00FF00", "0x 前缀解析")
        equal(ContentClassifier.parseColor("rgb(255, 0, 0)")?.hex, "#FF0000", "rgb() 解析")
        equal(ContentClassifier.parseColor("rgba(0, 0, 0, 0.5)")?.hex, "#00000080", "rgba() 解析")
        equal(ContentClassifier.parseColor("  #ABC  ")?.hex, "#AABBCC", "首尾空白与大小写")

        // 反例：这些绝不能被当成颜色
        let rejections: [(String, String)] = [
            ("123456", "六位纯数字（无 # 前缀）"),
            ("#12345", "五位 HEX"),
            ("#1234567", "七位 HEX"),
            ("#GGGGGG", "非十六进制字符"),
            ("rgb(300, 0, 0)", "分量越界"),
            ("issue #1234", "文本里含颜色片段"),
            ("#FF0000\n#00FF00", "两行内容"),
            ("", "空串"),
        ]
        for (text, label) in rejections {
            check(ContentClassifier.parseColor(text) == nil, "拒绝颜色：\(label)")
        }
    }

    // ── 链接 ─────────────────────────────────────────────────

    private static func linkTests() {
        check(ContentClassifier.isLink("https://example.com/a/b?c=1"), "识别 https 链接")
        check(ContentClassifier.isLink("http://127.0.0.1:8080/x"), "识别 http + 端口")
        check(!ContentClassifier.isLink("example.com"), "裸域名不算链接")
        check(!ContentClassifier.isLink("package.json"), "文件名不算链接")
        check(!ContentClassifier.isLink("file:///tmp/a.txt"), "file:// 不算链接")
        check(!ContentClassifier.isLink("https://a.com 后面还有字"), "带空格的整段不算链接")

        equal(ContentClassifier.kind(forText: "https://a.com"), .link, "链接类型判定")
        equal(ContentClassifier.kind(forText: "#FF0000"), .color, "颜色类型判定")
        equal(ContentClassifier.kind(forText: "mo update"), .text, "普通文本类型判定")
    }

    // ── 仓库：去重 / 置顶 / 淘汰 / 落盘 ───────────────────────

    private static func storeTests() {
        let root = temporaryRoot("store")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipStore(root: root)

        let first = ClipboardWatcher.textItem("mo update")
        equal(store.insert(first, maxItems: 100), .added, "首次插入是新条目")

        // 同内容再插一次：不该变两条，时间要更新（这就是"排到最前"）
        Thread.sleep(forTimeInterval: 0.02)
        var again = ClipboardWatcher.textItem("mo update")
        again.createdAt = Date()
        equal(store.insert(again, maxItems: 100), .refreshed, "同内容判为刷新而不是新增")
        equal(store.items.count, 1, "同内容不新增条目")
        check(store.items[0].createdAt >= first.createdAt, "同内容会刷新时间")

        // 大小写不同属于不同内容（剪贴板按原文去重，不按语义）
        _ = store.insert(ClipboardWatcher.textItem("MO UPDATE"), maxItems: 100)
        equal(store.items.count, 2, "大小写不同视为不同条目")

        // 落盘往返
        store.save()
        let reloaded = ClipStore(root: root)
        reloaded.load()
        equal(reloaded.items.count, 2, "落盘后重新读取条数一致")
        equal(Set(reloaded.items.map(\.hash)), Set(store.items.map(\.hash)), "落盘后 hash 集合一致")

        // 置顶豁免淘汰：上限 2，共 3 条，其中一条置顶 → 被淘汰的必须是最老的非置顶
        let pinnedTarget = store.items.first { $0.text == "MO UPDATE" }!
        store.togglePin(pinnedTarget.id)
        store.enforceLimit(2)
        equal(store.items.count, 2, "超过上限后按上限收敛")
        check(store.items.contains { $0.id == pinnedTarget.id }, "置顶条目不被淘汰")

        // 删除 → 撤销恢复
        let victim = store.items.first { $0.id != pinnedTarget.id }!
        let removed = store.remove(ids: [victim.id])
        equal(removed.count, 1, "删除返回被删条目")
        equal(store.items.count, 1, "删除后条数减少")
        store.restore(removed)
        equal(store.items.count, 2, "撤销删除后恢复")

        // 时间标签
        let now = Date()
        equal(Support.timeLabel(now, now: now).count, 5, "今天的时间戳是 HH:mm（5 个字符）")
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        check(Support.timeLabel(yesterday, now: now).hasPrefix("昨天"), "昨天带「昨天」前缀")
        equal(Support.dayTitle(now, now: now), "今天", "分区标题：今天")
        equal(Support.dayTitle(yesterday, now: now), "昨天", "分区标题：昨天")
    }

    // ── 规则匹配 ─────────────────────────────────────────────

    private static func ruleTests() {
        var item = ClipboardWatcher.textItem("Hello BoxPaste 世界")
        item.sourceAppName = "Visual Studio Code"
        item.sourceBundleID = "com.microsoft.VSCode"

        check(ContentClassifier.matches(item, rules: [Rule(field: .kind, value: "text")]), "规则：类型命中")
        check(ContentClassifier.matches(item, rules: [Rule(field: .kind, value: "文本")]), "规则：类型支持中文名")
        check(!ContentClassifier.matches(item, rules: [Rule(field: .kind, value: "image")]), "规则：类型不命中")
        check(ContentClassifier.matches(item, rules: [Rule(field: .sourceApp, value: "code")]), "规则：来源应用不区分大小写")
        check(ContentClassifier.matches(item, rules: [Rule(field: .sourceApp, value: "VSCode")]), "规则：来源可用 Bundle ID 片段")
        check(ContentClassifier.matches(item, rules: [Rule(field: .textContains, value: "boxpaste")]), "规则：包含文本不区分大小写")
        check(ContentClassifier.matches(item, rules: [Rule(field: .textRegex, value: "^Hello")]), "规则：正则命中")
        check(!ContentClassifier.matches(item, rules: [Rule(field: .textRegex, value: "^Box")]), "规则：正则不命中")
        check(!ContentClassifier.matches(item, rules: [Rule(field: .textRegex, value: "([")]), "规则：非法正则按不命中处理")

        // 多规则是 AND
        let both = [Rule(field: .kind, value: "text"), Rule(field: .textContains, value: "世界")]
        check(ContentClassifier.matches(item, rules: both), "多规则：全部满足才算命中")
        let conflicting = [Rule(field: .kind, value: "text"), Rule(field: .textContains, value: "找不到的串")]
        check(!ContentClassifier.matches(item, rules: conflicting), "多规则：有一条不满足即不命中")
        // 空规则不能"全部都收"
        check(!ContentClassifier.matches(item, rules: []), "空规则匹配不到任何条目")

        // 内置分类
        // （「收藏」排第一且没有规则，别用下标定位——按名字找要测的那一类）
        let linkItem = ClipboardWatcher.textItem("https://example.com")
        let hit = ContentClassifier.categoryIDs(for: linkItem, in: Category.builtins)
        let linkCategory = Category.builtins.first { $0.name == "链接" }!
        let imageCategory = Category.builtins.first { $0.name == "图片" }!
        check(hit.contains(linkCategory.id), "内置「链接」分类命中链接条目")
        check(!hit.contains(imageCategory.id), "内置「图片」分类不命中链接条目")

        // 手动归类叠加
        var manual = item
        manual.manualCategoryIDs = [imageCategory.id]
        let manualHit = ContentClassifier.categoryIDs(for: manual, in: Category.builtins)
        check(manualHit.contains(imageCategory.id), "手动归类的分类会被算进去")
    }

    // ── 导入导出 ─────────────────────────────────────────────

    private static func importExportTests() {
        let sourceRoot = temporaryRoot("export-src")
        let targetRoot = temporaryRoot("export-dst")
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: targetRoot)
        }

        let source = ClipStore(root: sourceRoot)
        _ = source.insert(ClipboardWatcher.textItem("第一段文本"), maxItems: 100)
        _ = source.insert(ClipboardWatcher.fileItem([URL(fileURLWithPath: "/tmp/a.txt")]), maxItems: 100)
        _ = source.insert(ClipboardWatcher.textItem("置顶的内容"), maxItems: 100)
        if let target = source.items.first(where: { $0.text == "置顶的内容" }) {
            source.togglePin(target.id)
        }

        guard let data = try? source.exportData(appVersion: "1.0.0") else {
            check(false, "导出数据")
            return
        }
        check(data.count > 0, "导出得到非空数据")

        let target = ClipStore(root: targetRoot)
        let added = (try? target.importData(data)) ?? -1
        equal(added, source.items.count, "导入条数与导出条数一致")
        equal(target.items.count, source.items.count, "导入后目标仓库条数一致")
        check(target.items.contains { $0.pinned }, "置顶状态随导出导入保留")

        // 再导一次：按 hash 去重，应该一条都不新增
        let secondRound = (try? target.importData(data)) ?? -1
        equal(secondRound, 0, "重复导入不新增条目")

        // 坏数据要明确报错，而不是静默清空
        let bogus = Data("{\"app\":\"NotBoxPaste\"}".utf8)
        do {
            _ = try target.importData(bogus)
            check(false, "坏文件应当抛错")
        } catch {
            check(true, "坏文件抛出可读错误")
        }
        equal(target.items.count, source.items.count, "导入失败不影响既有数据")

        // 缩略图名派生
        equal(ClipboardWatcher.thumbnailName(for: "abc.png"), "abc@thumb.png", "缩略图名派生")
        check(ClipboardWatcher.thumbnailName(for: "") == nil, "空 blob 名没有缩略图")
    }

    // ── 富文本存档 ────────────────────────────────────────────

    private static func richTextTests() {
        // 用真的系统剪贴板构造一份带 RTF 的内容（自检本来就允许碰剪贴板，
        // Paster 的降级测试同样用它），attachRichText 从这里取存档。
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("带格式的正文", forType: .string)
        let rtf = Data("{\\rtf1\\ansi 带格式的正文}".utf8)
        pasteboard.setData(rtf, forType: .rtf)

        let root = temporaryRoot("rich")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipStore(root: root)

        var item = ClipboardWatcher.textItem("带格式的正文")
        ClipboardWatcher.attachRichText(to: &item, from: pasteboard, store: store, maxBytes: 1024)
        // 存档写盘是异步的（见 attachRichText 的队列注释），断言文件存在前先等它写完
        ClipboardWatcher.flushPendingBlobWrites()
        check(item.rtfBlobName != nil, "富文本：RTF 被存档")
        check(item.htmlBlobName == nil, "富文本：剪贴板没有 HTML 时该字段为空")
        if let name = item.rtfBlobName {
            check(FileManager.default.fileExists(atPath: store.blobURL(named: name).path),
                  "富文本：存档文件真的写进了 blobs/")
        }

        // 去重刷新要继承旧存档：后来的一次捕获没带富文本时不能把存档抹掉
        _ = store.insert(item, maxItems: 100)
        _ = store.insert(ClipboardWatcher.textItem("带格式的正文"), maxItems: 100)
        equal(store.items.count, 1, "富文本条目同内容去重")
        check(store.items[0].rtfBlobName != nil, "去重刷新保留旧富文本存档")

        // 落盘往返：新增的可选字段要能存能读（旧历史文件没有该字段 → nil）
        store.save()
        let reloaded = ClipStore(root: root)
        reloaded.load()
        equal(reloaded.items.first?.rtfBlobName, item.rtfBlobName, "富文本字段落盘往返")

        // 删除条目连带清理富文本存档（不然 blobs/ 里全是孤儿文件）
        let storedName = item.rtfBlobName!
        let id = reloaded.items[0].id
        reloaded.remove(ids: [id])
        check(!FileManager.default.fileExists(atPath: reloaded.blobURL(named: storedName).path),
              "删除文本条目连带清理富文本存档")

        // 导出 → 导入：存档要跟着条目走
        let srcRoot = temporaryRoot("rich-export-src")
        let dstRoot = temporaryRoot("rich-export-dst")
        defer {
            try? FileManager.default.removeItem(at: srcRoot)
            try? FileManager.default.removeItem(at: dstRoot)
        }
        let source = ClipStore(root: srcRoot)
        var richItem = ClipboardWatcher.textItem("导出带格式")
        ClipboardWatcher.attachRichText(to: &richItem, from: pasteboard, store: source, maxBytes: 1024)
        ClipboardWatcher.flushPendingBlobWrites()
        _ = source.insert(richItem, maxItems: 100)
        guard let data = try? source.exportData(appVersion: "selftest") else {
            check(false, "富文本导出")
            return
        }
        let target = ClipStore(root: dstRoot)
        let added = (try? target.importData(data)) ?? -1
        equal(added, 1, "富文本导入条数")
        if let restored = target.items.first {
            check(restored.rtfBlobName != nil, "富文本导入后字段保留")
            if let name = restored.rtfBlobName {
                check(FileManager.default.fileExists(atPath: target.blobURL(named: name).path),
                      "富文本存档随导入还原成文件")
            }
        }
    }

    // ── 图片捕获（ImageIO 探测 + 缩略图）─────────────────────

    private static func imageCaptureTests() {
        // 造一张 120×60 的纯色 PNG，走真实捕获路径
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 60,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else {
            check(false, "构造测试位图")
            return
        }
        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            NSColor.systemBlue.setFill()
            NSRect(x: 0, y: 0, width: 120, height: 60).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else {
            check(false, "编码测试 PNG")
            return
        }

        // 探测：尺寸来自元数据，缩略图最长边不超过 40
        if let probe = ImageTools.probe(png: png, maxPixel: 40) {
            equal(probe.pixelWidth, 120, "图片探测：原始宽度")
            equal(probe.pixelHeight, 60, "图片探测：原始高度")
            if let thumbData = probe.thumbnailPNG {
                let thumb = NSBitmapImageRep(data: thumbData)
                check(max(thumb?.pixelsWide ?? 0, thumb?.pixelsHigh ?? 0) <= 40,
                      "图片探测：缩略图最长边不超过上限")
            } else {
                check(false, "图片探测：缩略图非空")
            }
        } else {
            check(false, "图片探测返回结果", detail: "probe 为 nil")
        }

        // 捕获：条目尺寸正确，原图与缩略图都落盘
        let root = temporaryRoot("image")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipStore(root: root)
        guard let item = ClipboardWatcher.imageItem(png: png, store: store) else {
            check(false, "图片条目构造")
            return
        }
        equal(item.pixelWidth, 120, "图片条目：宽度来自探测而非整图解码")
        equal(item.pixelHeight, 60, "图片条目：高度来自探测")
        if let url = store.imageURL(for: item) {
            check(FileManager.default.fileExists(atPath: url.path), "图片条目：原图落盘")
        }
        if let thumbURL = store.thumbnailURL(for: item) {
            check(FileManager.default.fileExists(atPath: thumbURL.path), "图片条目：缩略图落盘")
        }
    }

    // ── 孤儿 blob 对账 ───────────────────────────────────────

    // 删除路径只要漏一条，blob 就永久占着磁盘且没人记得名字。
    // 这里验证对账只清"没人引用"的，被引用的原图**和派生缩略图**都不能动。
    private static func blobGCTests() {
        let root = temporaryRoot("blobgc")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipStore(root: root)
        let manager = FileManager.default

        // 造一张真图走真实落盘路径（原图 + 缩略图都由它写出来）
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let png = rep.representation(using: .png, properties: [:]) else {
            check(false, "对账测试：造图")
            return
        }
        guard let imageItem = ClipboardWatcher.imageItem(png: png, store: store) else {
            check(false, "对账测试：图片条目")
            return
        }
        store.insert(imageItem, maxItems: 100)
        let keptBlob = store.imageURL(for: imageItem)
        let keptThumb = store.thumbnailURL(for: imageItem)

        // 再造两个"没人引用"的文件：一个像原图、一个像缩略图
        try? store.writeBlob(data: Data(repeating: 7, count: 1024), name: "orphan.png")
        try? store.writeBlob(data: Data(repeating: 7, count: 512), name: "orphan@thumb.png")
        // 富文本孤儿
        try? store.writeBlob(data: Data("{rtf}".utf8), name: "orphan.rtf")

        let swept = store.collectOrphanBlobs()
        equal(swept.count, 3, "对账：清掉 3 个孤儿文件")
        check(swept.bytes > 0, "对账：返回清理字节数")
        equal(manager.fileExists(atPath: store.blobURL(named: "orphan.png").path), false,
              "对账：孤儿原图被删")
        equal(manager.fileExists(atPath: store.blobURL(named: "orphan.rtf").path), false,
              "对账：孤儿富文本被删")
        if let keptBlob { check(manager.fileExists(atPath: keptBlob.path), "对账：在用原图保留") }
        if let keptThumb { check(manager.fileExists(atPath: keptThumb.path), "对账：在用缩略图保留") }

        // 幂等：再跑一次什么都不该删
        equal(store.collectOrphanBlobs().count, 0, "对账：第二次无孤儿可清")
    }

    // ── 预览截断 ─────────────────────────────────────────────

    // 长文本预览的护栏：超过阈值就截断，避免 SwiftUI 一次排版整篇
    // （10000 行实测会卡死主线程并被系统杀进程）。
    private static func previewTests() {
        // 短文本原样显示
        let short = "本次应用版本号不变。"
        let cappedShort = PreviewCard.cappedPreviewText(short)
        equal(cappedShort.body, short, "预览截断：短文本原样")
        check(cappedShort.note == nil, "预览截断：短文本不提示")

        // 行数超限：只留 200 行，并给出提示
        let manyLines = (1...300).map { "第 \($0) 行" }.joined(separator: "\n")
        let cappedLines = PreviewCard.cappedPreviewText(manyLines)
        equal(cappedLines.body.split(separator: "\n", omittingEmptySubsequences: false).count,
              200, "预览截断：行数上限 200")
        check(cappedLines.note != nil, "预览截断：行数超限要提示")
        check(cappedLines.body.hasPrefix("第 1 行"), "预览截断：保留的是开头")

        // 单行超长（没换行的 JSON / base64）：按字符数切
        let oneLongLine = String(repeating: "a", count: 30_000)
        let cappedLine = PreviewCard.cappedPreviewText(oneLongLine)
        equal(cappedLine.body.count, 20_000, "预览截断：单行按字符上限切")
        check(cappedLine.note != nil, "预览截断：单行超长要提示")

        // 恰好卡在上限内：不该动
        let exactly200 = (1...200).map { _ in "x" }.joined(separator: "\n")
        let cappedEdge = PreviewCard.cappedPreviewText(exactly200)
        equal(cappedEdge.body, exactly200, "预览截断：200 行整不截断")
        check(cappedEdge.note == nil, "预览截断：200 行整不提示")
    }

    // ── 快捷键 ───────────────────────────────────────────────

    private static func shortcutTests() {
        let spec = KeySpec(keyCode: 9, command: true, shift: true, label: "V")
        equal(spec.display, "⇧⌘V", "键位显示串（修饰键按 ⌃⌥⇧⌘ 顺序）")
        check(spec.isUsableAsGlobal, "带 ⌘ 的组合可做全局键")
        check(!KeySpec(keyCode: 0, shift: true, label: "A").isUsableAsGlobal, "只有 ⇧ 的组合不能做全局键")
        check(!KeySpec(keyCode: 49, label: "空格").isUsableAsGlobal, "无修饰键不能做全局键")

        // 编解码往返
        if let data = try? JSONEncoder().encode(spec),
           let decoded = try? JSONDecoder().decode(KeySpec.self, from: data) {
            equal(decoded, spec, "键位编解码往返一致")
        } else {
            check(false, "键位编解码往返一致")
        }

        // 默认值互不冲突（否则一装好就会有两个动作抢同一个键）
        var seen: Set<KeySpec> = []
        var duplicated = false
        for action in ShortcutAction.allCases {
            if seen.contains(action.defaultSpec) { duplicated = true }
            seen.insert(action.defaultSpec)
        }
        check(!duplicated, "默认快捷键之间没有冲突")
        equal(ShortcutAction.allCases.count, seen.count, "每个动作都有独立默认键")
    }

    // ── 配置兼容 ─────────────────────────────────────────────

    private static func preferenceTests() {
        // 只有 maxItems 的旧配置：其余字段要落回默认值，不能整份判为损坏
        let partial = Data("{\"maxItems\": 42}".utf8)
        if let decoded = try? JSONDecoder().decode(Preferences.self, from: partial) {
            equal(decoded.maxItems, 42, "旧配置里的字段被保留")
            equal(decoded.hideDockIcon, false, "缺失的 Dock 键落回默认值（显示图标）")
            equal(decoded.defaultView, .rich, "缺失的默认视图落回 rich")
            equal(decoded.categories.count, Category.builtins.count, "内置分类被补齐")
            // 1.0.3 之前写出来的配置里没有这个键。解码器要给它补默认值，
            // 而不是把整份设置判为损坏（那会让升级=设置全丢）。
            equal(decoded.alwaysOnTop, false, "缺失的置顶开关落回 false")
            equal(decoded.captureRichText, true, "缺失的富文本开关落回 true")
            equal(decoded.maxAgeDays, 0, "缺失的保留期限落回「不限」")
        } else {
            check(false, "旧配置可解码", detail: "字段缺失导致整份解码失败")
        }

        // 内置分类 id 必须跨版本稳定：手动归类存的就是这些 id
        let ids = Category.builtins.map(\.id)
        equal(Set(ids).count, ids.count, "内置分类 id 互不相同")
        for builtin in Category.builtins {
            check(builtin.isBuiltin, "内置分类带标记：\(builtin.name)")
            if builtin.id == Category.favoritesID {
                check(builtin.rules.isEmpty, "「收藏」是纯手动归类，不带规则")
            } else {
                check(!builtin.rules.isEmpty, "内置分类有规则：\(builtin.name)")
            }
        }

        // 「收藏」从用户分类升级为内置（1.0.14）：旧配置里它那一行
        // isBuiltin=false 且 id 就是现在的 favoritesID——合并后必须扳成 true，
        // 否则设置页会显示删除键；顺序保持用户摆的位置（不在末尾补一行）。
        let legacyFavorites = Data("""
        {"categories": [
            {"id": "7B440A97-F1BC-4BDA-9049-39D6480AFD8A", "name": "收藏",
             "symbol": "star", "rules": [], "isBuiltin": false},
            {"id": "11111111-1111-4111-8111-000000000001", "name": "链接",
             "symbol": "link",
             "rules": [{"id": "248E4582-B277-40A7-A441-8555D7347AB1",
                        "field": "kind", "value": "link"}], "isBuiltin": true}
        ]}
        """.utf8)
        if let decoded = try? JSONDecoder().decode(Preferences.self, from: legacyFavorites) {
            equal(decoded.categories.first { $0.id == Category.favoritesID }?.isBuiltin, true,
                  "存量「收藏」行升级为内置")
            let favIndex = decoded.categories.firstIndex { $0.id == Category.favoritesID }
            equal(favIndex, 0, "「收藏」保持在用户摆的位置")
            equal(decoded.categories.contains { $0.id == Category.favoritesID && $0.name == "收藏" },
                  true, "「收藏」不因内置合并而重复")
        } else {
            check(false, "含旧「收藏」行的配置可解码")
        }

        // 退役的内置分类要从旧配置里剔除（「颜色」1.0.7 下线）：
        // 光从 builtins 里删掉不够，合并逻辑会把它当"缺失的内置"补回来
        let withColor = Data("""
        {"categories": [{"id": "11111111-1111-4111-8111-000000000004",
                         "name": "颜色", "symbol": "paintpalette",
                         "rules": [], "isBuiltin": true}]}
        """.utf8)
        if let decoded = try? JSONDecoder().decode(Preferences.self, from: withColor) {
            equal(decoded.categories.contains { $0.name == "颜色" }, false, "退役分类「颜色」被剔除")
            equal(decoded.categories.count, Category.builtins.count, "剔除退役分类后内置仍被补齐")
        } else {
            check(false, "含退役分类的旧配置可解码")
        }

        // 整份设置往返
        var prefs = Preferences()
        prefs.maxItems = 777
        prefs.hideDockIcon = true
        prefs.alwaysOnTop = true
        prefs.shortcuts[ShortcutAction.paste.rawValue] = KeySpec(keyCode: 36, command: true, label: "↩")
        if let data = try? JSONEncoder().encode(prefs),
           let decoded = try? JSONDecoder().decode(Preferences.self, from: data) {
            equal(decoded.maxItems, 777, "设置往返：条数上限")
            equal(decoded.hideDockIcon, true, "设置往返：Dock 隐藏开关")
            equal(decoded.alwaysOnTop, true, "设置往返：面板置顶")
            equal(decoded.spec(for: .paste).command, true, "设置往返：自定义快捷键")
        } else {
            check(false, "设置往返")
        }

        // 旧键 showInDock 反相迁移：升级前后 Dock 实际状态不能变
        // （旧值 false=不显示 → 新键 true=隐藏）
        let legacyDock = Data("{\"showInDock\": false}".utf8)
        if let decoded = try? JSONDecoder().decode(Preferences.self, from: legacyDock) {
            equal(decoded.hideDockIcon, true, "旧 showInDock=false 反相迁移为 hideDockIcon=true")
        } else {
            check(false, "含旧 Dock 键的配置可解码")
        }

        // 下线的音效（Sosumi/Submarine）要落回默认，否则 Picker 显示空白
        let retiredSound = Data("{\"feedbackSound\": \"Sosumi\"}".utf8)
        if let decoded = try? JSONDecoder().decode(Preferences.self, from: retiredSound) {
            equal(decoded.feedbackSound, Preferences().feedbackSound, "下线音效落回默认音色")
        } else {
            check(false, "含下线音效的配置可解码")
        }

        // 保留期限：选项清单内的值原样保留，清单外的（手改配置）落回「不限」
        for days in Preferences.maxAgeOptions {
            let data = Data("{\"maxAgeDays\": \(days)}".utf8)
            if let decoded = try? JSONDecoder().decode(Preferences.self, from: data) {
                equal(decoded.maxAgeDays, days, "保留期限 \(days) 天原样保留")
            } else {
                check(false, "保留期限 \(days) 天可解码")
            }
        }
        if let decoded = try? JSONDecoder().decode(Preferences.self, from: Data("{\"maxAgeDays\": 37}".utf8)) {
            equal(decoded.maxAgeDays, 0, "清单外的保留期限落回不限")
        } else {
            check(false, "清单外保留期限可解码")
        }
        check(SoundFeedback.availableNames.contains(Preferences().feedbackSound),
              "默认音色在当前音效清单里")

        categoryOrderTests()
        identityTests()
    }

    // ── 应用身份与偏好迁移 ───────────────────────────────────

    private static func identityTests() {
        // 换 id 是修菜单栏登记的唯一手段（机制见 AppIdentity 头注释），
        // 这条断言防止有人把 id 改回去——改回去图标立刻就消失。
        check(AppIdentity.bundleIdentifier != AppIdentity.legacyBundleIdentifier,
              "bundle id 与旧 id 不同（旧 id 的菜单栏登记已烧坏）")

        // 迁移目标用一个一次性测试域验证，不碰这台机器的真实偏好。
        let target = UserDefaults(suiteName: "selftest-migrate-dst")
        guard let target else {
            check(false, "迁移测试域可用")
            return
        }
        defer {
            target.removePersistentDomain(forName: "selftest-migrate-dst")
        }
        target.removePersistentDomain(forName: "selftest-migrate-dst")
        // 手造字典而不是读某个真实域：真实域会混入全局域的几十个键，
        // 让断言依赖机器当时的状态。
        let legacy: [String: Any] = [
            "com.pcxx.boxpaste.preferences": Data([0x7b]),
            "NSStatusItem VisibleCC BoxPaste": true,
            "com.pcxx.boxpaste.panelOriginX": 881.0,
        ]

        AppIdentity.copyLegacyKeys(legacy, into: target)

        equal(target.data(forKey: "com.pcxx.boxpaste.preferences") != nil, true, "迁移：设置键被搬过来")
        equal(target.double(forKey: "com.pcxx.boxpaste.panelOriginX"), 881.0, "迁移：面板位置被搬过来")
        equal(target.object(forKey: "NSStatusItem VisibleCC BoxPaste") == nil, true,
              "迁移：NSStatusItem 键被丢弃（诊断期垃圾）")
    }

    // ── 分类排序 ─────────────────────────────────────────────

    private static func categoryOrderTests() {
        let a = Category(name: "甲", symbol: "star")
        let b = Category(name: "乙", symbol: "link")
        let c = Category(name: "丙", symbol: "photo")
        let list = [a, b, c]

        equal(Category.moving(list, id: b.id, by: -1)?.map(\.id), [b.id, a.id, c.id], "上移一格")
        equal(Category.moving(list, id: b.id, by: 1)?.map(\.id), [a.id, c.id, b.id], "下移一格")

        // 到头了要返回 nil（界面靠它把箭头置灰），而不是循环滚到另一头：
        // 顺序是用户自己排的，"按上移却跳到最后"会让人以为程序坏了。
        check(Category.moving(list, id: a.id, by: -1) == nil, "第一条不能再上移")
        check(Category.moving(list, id: c.id, by: 1) == nil, "最后一条不能再下移")
        check(Category.moving(list, id: UUID(), by: 1) == nil, "不存在的分类返回 nil")

        // 挪完元素一个不少、内容不改（只换位置）
        if let moved = Category.moving(list, id: a.id, by: 1) {
            equal(moved.count, list.count, "排序不增删元素")
            equal(Set(moved.map(\.id)), Set(list.map(\.id)), "排序不改变成员集合")
            equal(moved[1].name, "甲", "排序只挪位置、不改内容")
        } else {
            check(false, "下移第一条")
        }
    }

    // ── 显示格式 ─────────────────────────────────────────────

    private static func formatTests() {
        equal(Support.humanByteCount(999), "999 B", "字节显示")
        equal(Support.humanByteCount(1500), "1.5 KB", "十进制 KB")
        equal(Support.humanByteCount(2_500_000), "2.5 MB", "十进制 MB")

        let text = ClipboardWatcher.textItem("第一行\n第二行")
        equal(text.kind, .text, "多行文本类型")
        check(text.oneLineSummary.contains("第一行 第二行"), "摘要把换行压成空格")

        let file = ClipboardWatcher.fileItem([URL(fileURLWithPath: "/tmp/a.txt"),
                                              URL(fileURLWithPath: "/tmp/b.txt")])
        equal(file.fileURLs.count, 2, "文件条目拆出两个路径")
        check(file.oneLineSummary.contains("等 2 个文件"), "多文件摘要带数量")

        // 哈希稳定性：同内容同类型必须同 hash，否则去重会漏
        equal(ClipboardWatcher.textItem("same").hash, ClipboardWatcher.textItem("same").hash, "同文本 hash 稳定")
        check(ClipboardWatcher.textItem("same").hash != ClipboardWatcher.textItem("https://same").hash,
              "不同类型不共用 hash")
    }

    // ── 工具 ─────────────────────────────────────────────────

    // ── 内存口径 / 正则缓存 ──────────────────────────────────

    /// 这两项都属于"算错了不报错、只会悄悄多吃内存或 CPU"的类型，
    /// 界面上看不出来，只能靠断言钉住口径。
    private static func memoryHygieneTests() {
        // 1) 缩略图按**解码后的位图字节**计费（600×600×4 = 1.44MB），
        //    而不是 PNG 文件字节（平均 132KB）。算错十倍 = 缓存上限形同虚设。
        let image = NSImage(size: NSSize(width: 600, height: 600))
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 600,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0) {
            image.addRepresentation(rep)
        }
        equal(ThumbnailCache.bitmapBytes(of: image), 600 * 600 * 4,
              "缩略图按像素计费（600×600×4）")

        // 2) 同一 pattern 必须复用同一个编译结果
        let first = ContentClassifier.cachedRegex(#"^\d{3,5}$"#)
        let second = ContentClassifier.cachedRegex(#"^\d{3,5}$"#)
        check(first != nil && first === second, "正则缓存命中同一实例")

        // 3) 非法 pattern 返回 nil，且不影响后续编译
        check(ContentClassifier.cachedRegex("([") == nil, "非法正则返回 nil")
        check(ContentClassifier.cachedRegex("^ok$") != nil, "非法正则之后仍能正常编译")

        // 4) 超过缓存上限（64）后仍要能正常工作，不能因为整表清空就失效
        for index in 0..<80 { _ = ContentClassifier.cachedRegex("^cache-test-\(index)$") }
        check(ContentClassifier.cachedRegex("^cache-test-79$") != nil, "缓存超上限后仍可编译")
        check(ContentClassifier.cachedRegex(#"^\d{3,5}$"#) != nil, "缓存超上限后旧 pattern 可重建")
    }

    // ── 保留期限 ─────────────────────────────────────────────

    // 到期清理的判定完全是"createdAt 早于 cutoff"，这里把边界钉死：
    // 刚好卡在期限上的那条不能删（否则用户会看到"设 30 天，第 30 天就没了"）。
    private static func expiryTests() {
        let root = temporaryRoot("expiry")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipStore(root: root)
        let now = Date()

        func makeItem(_ text: String, daysAgo: Double) -> ClipItem {
            var item = ClipboardWatcher.textItem(text)
            item.createdAt = now.addingTimeInterval(-daysAgo * 86_400)
            return item
        }

        let expired = makeItem("40 天前", daysAgo: 40)
        let fresh = makeItem("20 天前", daysAgo: 20)
        let edge = makeItem("刚好 30 天", daysAgo: 30)
        let expiredFavorite = makeItem("40 天前但收藏了", daysAgo: 40)
        for item in [expired, fresh, edge, expiredFavorite] {
            store.insert(item, maxItems: 100)
        }

        let removed = store.purgeExpired(maxAgeDays: 30, keeping: [expiredFavorite.id], now: now)
        equal(removed.count, 1, "到期清理只删超期的非收藏条目")
        equal(store.items.count, 3, "清理后条数正确")
        check(store.items.contains { $0.hash == fresh.hash }, "未到期条目保留")
        check(store.items.contains { $0.hash == edge.hash }, "刚好卡在期限上不算过期")
        check(store.items.contains { $0.hash == expiredFavorite.hash }, "收藏条目到期也保留")

        // 不限（0）时一次都不能删
        equal(store.purgeExpired(maxAgeDays: 0, keeping: [], now: now).count, 0, "不限时不清任何条目")
        equal(store.items.count, 3, "不限时条数不变")

        // 60/90 天：剩下的都在期限内
        equal(store.purgeExpired(maxAgeDays: 90, keeping: [], now: now).count, 0, "90 天内无过期条目")
        equal(store.purgeExpired(maxAgeDays: 45, keeping: [], now: now).count, 0, "45 天内无过期条目")
        // 豁免是调用方传进来的，不是内建规则：不传 keep 时那条收藏也会过期
        equal(store.purgeExpired(maxAgeDays: 30, keeping: [], now: now).count, 1, "不传豁免时收藏条目也过期")
        equal(store.purgeExpired(maxAgeDays: 30, keeping: [], now: now).count, 0, "再跑一次幂等")
    }

    private static func temporaryRoot(_ name: String) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("boxpaste-selftest-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
