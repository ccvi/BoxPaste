import Foundation

// ============================================================
// 数据模型：剪贴板条目 / 分类 / 分类规则
//
// 这一层刻意不碰 AppKit 与剪贴板，纯值类型 —— 自检（SelfTest）能直接
// 构造它们跑断言，不需要 GUI，也不需要真的去动系统剪贴板。
// ============================================================

/// 条目类型。判定顺序在 ClipboardWatcher 里：文件 > 图像 > 文本，
/// 文本再细分出链接与颜色。
enum ClipKind: String, Codable, CaseIterable, Identifiable {
    case text
    case link
    case color
    case image
    case file

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text:  return "文本"
        case .link:  return "链接"
        case .color: return "颜色"
        case .image: return "图像"
        case .file:  return "文件"
        }
    }

    /// SF Symbol 名。小尺寸下要能一眼分辨，所以尽量选轮廓差异大的
    /// （doc / link / paintpalette / photo / folder）。
    var symbol: String {
        switch self {
        case .text:  return "doc.text"
        case .link:  return "link"
        case .color: return "paintpalette"
        case .image: return "photo"
        case .file:  return "folder"
        }
    }
}

/// 一条剪贴板历史。
///
/// `text` 的含义随类型变化：文本/链接/颜色存原文；文件存若干行路径；
/// 图像留空（真身在 blobs/ 里，靠 blobName 找）。
struct ClipItem: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var kind: ClipKind
    var text: String = ""
    /// blobs/ 下的文件名（图像才有）。缩略图由它派生：`<hash>@thumb.png`
    var blobName: String?
    /// 记录来源应用：复制发生时最前面的那个 app
    var sourceAppName: String?
    var sourceBundleID: String?
    var createdAt: Date = Date()
    var pinned: Bool = false
    /// 内容字节数（文本按 UTF-8，图像按 PNG），列表里显示体积用
    var byteCount: Int = 0
    /// 内容指纹（sha256，前缀含类型），去重与导入合并都按它
    var hash: String = ""
    /// 用户手动归入的分类（规则命中的分类不落盘，实时算）
    var manualCategoryIDs: [UUID] = []
    /// 图像的像素尺寸（可选，用于预览信息）
    var pixelWidth: Int?
    var pixelHeight: Int?
    /// 富文本存档（blobs/ 下的文件名）。捕获时若剪贴板带了 RTF/HTML 就存下来，
    /// 写回剪贴板时一并挂上，粘贴到文字处理软件里还能保住格式。
    /// 两个都是可选：1.0.14 及以前的条目、以及关闭"记录富文本"后捕获的条目没有。
    var rtfBlobName: String?
    var htmlBlobName: String?

    /// 参与搜索与「包含/正则」规则匹配的正文。
    /// 文件条目把路径也纳入，这样搜文件名能命中。
    var searchableText: String {
        if kind == .file {
            return (text + "\n" + fileURLs.map(\.lastPathComponent).joined(separator: "\n"))
        }
        return text
    }

    var fileURLs: [URL] {
        guard kind == .file else { return [] }
        return text.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }

    /// 列表/网格里的单行摘要
    var oneLineSummary: String {
        switch kind {
        case .text, .link, .color:
            let collapsed = text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: false)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return collapsed.isEmpty ? "（空白内容）" : collapsed
        case .image:
            if let w = pixelWidth, let h = pixelHeight { return "图像 \(w) × \(h)" }
            return "图像"
        case .file:
            let names = fileURLs.map(\.lastPathComponent)
            if names.count == 1 { return names[0] }
            if names.count > 1 { return "\(names[0]) 等 \(names.count) 个文件" }
            return "文件"
        }
    }
}

// ── 分类 ────────────────────────────────────────────────────

/// 规则字段。用户要求的三类维度分别对应：
/// 类型 → .kind；应用来源 → .sourceApp；文本内容 → .textContains / .textRegex。
/// 创建日期不做成规则（列表里按日期分区展示更直观，也没必要让用户配）。
enum RuleField: String, Codable, CaseIterable, Identifiable {
    case kind
    case sourceApp
    case textContains
    case textRegex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .kind:         return "类型是"
        case .sourceApp:    return "来源应用"
        case .textContains: return "包含文本"
        case .textRegex:    return "匹配正则"
        }
    }

    var hint: String {
        switch self {
        case .kind:         return "文本 / 链接 / 颜色 / 图像 / 文件"
        case .sourceApp:    return "应用名或 Bundle ID 的一部分"
        case .textContains: return "任意子串，不区分大小写"
        case .textRegex:    return "NSRegularExpression 语法"
        }
    }
}

struct Rule: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var field: RuleField
    var value: String
}

struct Category: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var symbol: String
    var rules: [Rule] = []
    /// 内置分类：可改名但不能删（删了面板顶栏会空掉，"全部"之外一个都没有）
    var isBuiltin: Bool = false

    /// 内置三类。用固定 UUID 而不是随机 UUID：内置分类要能在多次启动之间
    /// 稳定地对上（手动归类的 manualCategoryIDs 里存的就是这些 id），
    /// 随机 UUID 会让每次重启都换一批 id，归类结果全部失效。
    ///
    /// （「颜色」分类 1.0.7 应用户要求下线：HEX 颜色内容的识别与预览都还在，
    /// 只是顶栏不再单出一页——用的人少，一页 tab 的代价不值。）
    /// 「收藏」的固定 id。历史包袱要记住：它 1.0.13 及以前是用户自建分类，
    /// id 是当时随机生成的这串——升级为内置时**沿用同一个 id**，
    /// 条目 manualCategoryIDs 里存的全是它，换 id 等于收藏全丢。
    static let favoritesID = UUID(uuidString: "7B440A97-F1BC-4BDA-9049-39D6480AFD8A")!

    static let builtins: [Category] = [
        // 收藏排第一（用户一直把它摆在最前）。没有规则：纯手动归类，
        // 条目经"移到分类"进来；清空历史时整类保留。
        Category(id: favoritesID,
                 name: "收藏", symbol: "star",
                 rules: [], isBuiltin: true),
        Category(id: UUID(uuidString: "11111111-1111-4111-8111-000000000001")!,
                 name: "链接", symbol: "link",
                 rules: [Rule(field: .kind, value: ClipKind.link.rawValue)], isBuiltin: true),
        Category(id: UUID(uuidString: "11111111-1111-4111-8111-000000000002")!,
                 name: "图片", symbol: "photo",
                 rules: [Rule(field: .kind, value: ClipKind.image.rawValue)], isBuiltin: true),
        Category(id: UUID(uuidString: "11111111-1111-4111-8111-000000000003")!,
                 name: "文件", symbol: "folder",
                 rules: [Rule(field: .kind, value: ClipKind.file.rawValue)], isBuiltin: true),
    ]

    /// 曾经是内置、后来下线的分类 id。只从 `builtins` 里删掉是不够的：
    /// 解码时的合并逻辑会按 id 把"缺失的内置"补回来，旧配置里的它永远阴魂不散。
    /// 退役的必须在这里点名，合并时一并从旧配置里剔除。
    static let retiredBuiltinIDs: [UUID] = [
        UUID(uuidString: "11111111-1111-4111-8111-000000000004")!,   // 颜色
    ]

    /// 把某个分类在数组里挪一格；返回 nil 表示"不用动"（找不到，或者已经在头/尾）。
    ///
    /// 抽成纯函数是为了能进自检：真正的调用点（AppModel.moveCategory）还要过
    /// @Published 和落盘，那层测起来要拖一整个 AppModel 起来，成本高得多。
    /// 用 id 而不是下标：设置页是 ForEach 渲染的，改动过程中下标会错位。
    static func moving(_ list: [Category], id: UUID, by offset: Int) -> [Category]? {
        guard let index = list.firstIndex(where: { $0.id == id }) else { return nil }
        let target = index + offset
        guard list.indices.contains(target) else { return nil }
        var copy = list
        let moved = copy.remove(at: index)
        copy.insert(moved, at: target)
        return copy
    }
}

/// 列表里的一条：置顶区 / 今天 / 昨天 / 更早。
/// 类型、来源应用这些维度走顶栏分类，日期维度走这里的分区——
/// 两个维度都用同一种 UI（顶栏）会挤成一团。
struct DisplaySection: Identifiable {
    var id: String { title }
    var title: String
    var items: [ClipItem]
}
