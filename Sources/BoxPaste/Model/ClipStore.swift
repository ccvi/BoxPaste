import AppKit
import Foundation

// ============================================================
// 历史仓库：落盘、去重、淘汰、导入导出
//
// 落盘结构（与家族其他项目一致，用户能自己备份/迁移）：
//   ~/Library/Application Support/BoxPaste/
//     history.json          条目元数据（不含图片二进制）
//     blobs/<hash>.png      图像原图
//     blobs/<hash>@thumb.png 列表用缩略图
//
// 为什么图片不进 JSON：一条 300 KB 的截图 base64 之后是 400 KB 文本，
// 而每次追加一条都要把整个 JSON 重写一遍 —— 历史一多就变成"复制一次卡一下"。
// ============================================================

final class ClipStore {

    enum InsertOutcome: Equatable {
        /// 新内容
        case added
        /// 之前就有，被刷新时间后提到最前（这就是"复制成功的记录排到最前"）
        case refreshed
    }

    struct ExportBundle: Codable {
        var app: String
        var version: String
        var exportedAt: Date
        var items: [ClipItem]
        /// 文件名 → base64。只带图像；文本本身就在 items 里。
        var blobs: [String: String]
    }

    enum StoreError: LocalizedError {
        case badFormat
        var errorDescription: String? {
            switch self {
            case .badFormat: return "文件不是 BoxPaste 导出的历史文件"
            }
        }
    }

    let root: URL
    private(set) var items: [ClipItem] = []

    init(root: URL = Support.appSupportRoot) {
        self.root = root
    }

    // ── 路径 ─────────────────────────────────────────────────

    var historyURL: URL { root.appendingPathComponent("history.json") }
    var blobsDirectory: URL { root.appendingPathComponent("blobs", isDirectory: true) }

    func blobURL(named name: String) -> URL { blobsDirectory.appendingPathComponent(name) }

    /// 缩略图路径：由原图名派生，避免再存一个字段（存了就会不一致）。
    func thumbnailURL(for item: ClipItem) -> URL? {
        guard let blobName = item.blobName else { return nil }
        let base = (blobName as NSString).deletingPathExtension
        let ext = (blobName as NSString).pathExtension
        return blobURL(named: "\(base)@thumb.\(ext.isEmpty ? "png" : ext)")
    }

    func imageURL(for item: ClipItem) -> URL? {
        guard let blobName = item.blobName else { return nil }
        return blobURL(named: blobName)
    }

    // ── 读写 ─────────────────────────────────────────────────

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // sortedKeys：让同一份历史每次编码得到相同字节，自检里好做往返比对，
        // 也让用户用 git/diff 备份时不会因为键序抖动而满屏变化。
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func load() {
        items = Self.readItems(root: root)
    }

    /// 从磁盘读条目。**静态纯函数**：只碰磁盘与解码、不碰 self，
    /// 所以能整个放到后台线程跑（启动路径异步化的关键），主线程只负责收结果。
    /// 日期策略必须与 makeDecoder() 一致（iso8601），否则旧历史整份读不出来。
    static func readItems(root: URL) -> [ClipItem] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: root.appendingPathComponent("history.json")),
              let decoded = try? decoder.decode([ClipItem].self, from: data) else {
            return []
        }
        return decoded
    }

    /// 把后台读出来的条目装进仓库（配合 readItems 使用）。
    func applyLoaded(_ loaded: [ClipItem]) {
        items = loaded
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let data = try makeEncoder().encode(items)
            // 原子写：直接覆写的话，中途崩溃/断电会留下一份半截 JSON，
            // 下一次启动就是"历史全没了"。.atomic 走临时文件 + rename。
            try data.write(to: historyURL, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("写入历史失败：\(error)\n".utf8))
        }
    }

    // ── 写入 / 去重 ──────────────────────────────────────────

    /// 存入一条。同内容（hash 相同）不新增，只把时间刷新到最新 ——
    /// 这条同时满足需求里的"复制/剪切/粘贴成功的记录排到最前"。
    @discardableResult
    func insert(_ item: ClipItem, maxItems: Int) -> InsertOutcome {
        if let index = items.firstIndex(where: { $0.hash == item.hash }) {
            var existing = items[index]
            existing.createdAt = item.createdAt
            // 来源应用换成最近一次复制它的应用：用户感知里"这条来自 A"更符合直觉
            existing.sourceAppName = item.sourceAppName ?? existing.sourceAppName
            existing.sourceBundleID = item.sourceBundleID ?? existing.sourceBundleID
            // 富文本存档同样沿用旧值：去重命中的新捕获可能没带富文本
            // （开关关着、或老条目本来就没有），不能反过来把旧存档抹掉
            existing.rtfBlobName = item.rtfBlobName ?? existing.rtfBlobName
            existing.htmlBlobName = item.htmlBlobName ?? existing.htmlBlobName
            // 置顶状态与手动归类沿用旧的（用户手工动作不该被自动流程抹掉）
            items[index] = existing
            enforceLimit(maxItems)
            sortInPlace()
            return .refreshed
        }
        items.append(item)
        enforceLimit(maxItems)
        sortInPlace()
        return .added
    }

    /// 把某条提到最前（粘贴成功后调用）
    func bump(_ id: UUID, at date: Date = Date()) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].createdAt = date
        sortInPlace()
    }

    @discardableResult
    func togglePin(_ id: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        items[index].pinned.toggle()
        sortInPlace()
        return items[index].pinned
    }

    func setManualCategories(_ ids: [UUID], for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].manualCategoryIDs = ids
    }

    /// 删除（连带清掉 blob 文件）。返回被删掉的条目，供"撤销删除"用。
    @discardableResult
    func remove(ids: [UUID]) -> [ClipItem] {
        let removed = items.filter { ids.contains($0.id) }
        items.removeAll { ids.contains($0.id) }
        for item in removed { deleteBlobs(of: item) }
        return removed
    }

    /// 清空历史，但 keep 里的条目原样保留。
    /// keep 由调用方算好（置顶 + 收藏分类）：store 不认识分类器，只认 id。
    func clearAll(keeping keep: Set<UUID>) {
        let doomed = items.filter { !keep.contains($0.id) }
        remove(ids: doomed.map(\.id))
    }

    /// 超出保留期就删掉（keep 里的 id 豁免，调用方传「收藏」）。
    ///
    /// 为什么不按「天数差」算日期边界：用户要的是"30 天前的东西没了"，
    /// 用 30×86400 秒的滚动窗口最直观，也不受时区/夏令时影响。
    /// 置顶**不豁免**：这一项是按时间清扫，唯一例外是用户手动收藏的条目。
    @discardableResult
    func purgeExpired(maxAgeDays: Int, keeping keep: Set<UUID>, now: Date = Date()) -> [ClipItem] {
        guard maxAgeDays > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-Double(maxAgeDays) * 86_400)
        let doomed = items.filter { !keep.contains($0.id) && $0.createdAt < cutoff }
        guard !doomed.isEmpty else { return [] }
        return remove(ids: doomed.map(\.id))
    }

    /// 把先前删掉的条目塞回来（撤销删除）。blob 文件也一起捡回来。
    func restore(_ restored: [ClipItem]) {
        for item in restored where !items.contains(where: { $0.hash == item.hash }) {
            items.append(item)
        }
        sortInPlace()
    }

    // ── 图片落盘 ─────────────────────────────────────────────

    func writeBlob(data: Data, name: String) throws {
        try FileManager.default.createDirectory(at: blobsDirectory, withIntermediateDirectories: true)
        try data.write(to: blobURL(named: name), options: .atomic)
    }

    func deleteBlobs(of item: ClipItem) {
        let manager = FileManager.default
        if item.kind == .image {
            if let blobURL = imageURL(for: item) {
                try? manager.removeItem(at: blobURL)
                ThumbnailCache.shared.forget(blobURL)
            }
            if let thumbURL = thumbnailURL(for: item) {
                try? manager.removeItem(at: thumbURL)
                ThumbnailCache.shared.forget(thumbURL)
            }
        }
        // 富文本存档（文本类条目 1.0.15 起可能带）：条目没了存档就是孤儿文件
        for name in [item.rtfBlobName, item.htmlBlobName].compactMap({ $0 }) {
            try? manager.removeItem(at: blobURL(named: name))
        }
    }

    /// 对账 blobs 目录：删掉没有任何条目引用的文件，返回（个数, 字节）。
    ///
    /// 为什么需要这一手：删除路径再怎么写也总有漏网的时候 —— 老版本漏删、
    /// 导入/恢复覆盖了历史、进程恰好在「写完 blob、还没存 history」之间被杀。
    /// 这些文件没人记得名字，只能靠「当前所有条目真正引用的名字」反推。
    ///
    /// 安全前提：**条目为空时不要调**。历史文件损坏被读成空数组时，
    /// 这里会把所有 blob 当孤儿删光——宁可留垃圾，也不能删用户数据。
    @discardableResult
    func collectOrphanBlobs() -> (count: Int, bytes: Int) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: blobsDirectory,
                                                             includingPropertiesForKeys: [.fileSizeKey]) else {
            return (0, 0)
        }
        // 缩略图名由原图名派生（见 thumbnailURL），所以引用集要一起算进去
        var referenced = Set<String>()
        for item in items {
            if let name = item.blobName {
                referenced.insert(name)
                if item.kind == .image {
                    let base = (name as NSString).deletingPathExtension
                    let ext = (name as NSString).pathExtension
                    referenced.insert("\(base)@thumb.\(ext.isEmpty ? "png" : ext)")
                }
            }
            if let name = item.rtfBlobName { referenced.insert(name) }
            if let name = item.htmlBlobName { referenced.insert(name) }
        }
        var count = 0
        var bytes = 0
        for url in entries {
            guard !referenced.contains(url.lastPathComponent) else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard (try? manager.removeItem(at: url)) != nil else { continue }
            ThumbnailCache.shared.forget(url)
            count += 1
            bytes += size
        }
        return (count, bytes)
    }

    func totalBlobBytes() -> Int {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: blobsDirectory,
                                                                        includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        return entries.reduce(0) { partial, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return partial + size
        }
    }

    // ── 排序 / 淘汰 ──────────────────────────────────────────

    private func sortInPlace() {
        items.sort { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            return lhs.createdAt > rhs.createdAt
        }
    }

    /// 超过上限就丢最老的**非置顶**条目。
    /// 置顶的豁免是刻意的：用户按住图钉就是在说"这条对我重要"，
    /// 让它被后续复制挤掉等于这个按钮白做。
    func enforceLimit(_ maxItems: Int) {
        guard maxItems > 0 else { return }
        sortInPlace()
        var kept: [ClipItem] = []
        var remaining = maxItems
        var dropped: [ClipItem] = []
        for item in items {
            if item.pinned {
                kept.append(item)
                continue
            }
            if remaining > 0 {
                kept.append(item)
                remaining -= 1
            } else {
                dropped.append(item)
            }
        }
        guard !dropped.isEmpty else {
            items = kept
            return
        }
        items = kept
        for item in dropped { deleteBlobs(of: item) }
    }

    // ── 导入 / 导出 ──────────────────────────────────────────

    /// 导出成单个 JSON。图片内嵌 base64（默认只带 8 MB 以下的，
    /// 剪贴板里的截图基本都在这个量级，再大的图内嵌会让文件大得没法用）。
    func exportData(appVersion: String, embedImages: Bool = true,
                    maxEmbedBytes: Int = 8_000_000) throws -> Data {
        var bundle = ExportBundle(app: "BoxPaste", version: appVersion,
                                  exportedAt: Date(), items: items, blobs: [:])
        if embedImages {
            for item in items {
                // 图像与富文本存档统一走 blobs 字典（名字 → base64），
                // 导入端只认条目上引用的名字，不区分种类。
                var names: [String] = []
                if item.kind == .image { names.append(item.blobName ?? "") }
                names.append(contentsOf: [item.rtfBlobName, item.htmlBlobName].compactMap { $0 })
                for name in names where !name.isEmpty {
                    guard let data = try? Data(contentsOf: blobURL(named: name)),
                          data.count <= maxEmbedBytes else { continue }
                    bundle.blobs[name] = data.base64EncodedString()
                }
            }
        }
        let encoder = makeEncoder()
        return try encoder.encode(bundle)
    }

    /// 导入并合并。返回真正新增的条数。
    /// 合并策略：按内容 hash 去重 —— 同一张图/同一段文本不会因为导入两份
    /// 备份文件而变成两条。
    @discardableResult
    func importData(_ data: Data) throws -> Int {
        let decoder = makeDecoder()
        guard let bundle = try? decoder.decode(ExportBundle.self, from: data) else {
            throw StoreError.badFormat
        }
        var added = 0
        var skippedImages = 0
        for var item in bundle.items {
            if items.contains(where: { $0.hash == item.hash }) { continue }

            if item.kind == .image {
                guard let blobName = item.blobName,
                      let base64 = bundle.blobs[blobName],
                      let blobData = Data(base64Encoded: base64) else {
                    // 图像条目没有图就没意义：留在列表里只会显示一张裂图
                    skippedImages += 1
                    continue
                }
                try? writeBlob(data: blobData, name: blobName)
                if let thumbName = thumbnailName(for: blobName),
                   !FileManager.default.fileExists(atPath: blobURL(named: thumbName).path) {
                    // 缩略图不存在时用原图补一张，省得列表里全是占位图标
                    try? writeBlob(data: blobData, name: thumbName)
                }
            }
            // 富文本存档也一并还原（旧备份文件里没有这两个名字就静默跳过）
            for name in [item.rtfBlobName, item.htmlBlobName].compactMap({ $0 }) {
                if let base64 = bundle.blobs[name], let blobData = Data(base64Encoded: base64) {
                    try? writeBlob(data: blobData, name: name)
                }
            }
            // 导入的条目不该空降到"最新"，但也不能时间戳为未来：
            // 保持原时间即可，列表按时间倒序自然归位。
            if item.createdAt > Date() { item.createdAt = Date() }
            items.append(item)
            added += 1
        }
        sortInPlace()
        if skippedImages > 0 {
            FileHandle.standardError.write(Data("导入时跳过 \(skippedImages) 条缺少图片数据的图像\n".utf8))
        }
        return added
    }

    private func thumbnailName(for blobName: String) -> String? {
        guard !blobName.isEmpty else { return nil }
        let base = (blobName as NSString).deletingPathExtension
        let ext = (blobName as NSString).pathExtension
        return "\(base)@thumb.\(ext.isEmpty ? "png" : ext)"
    }
}
