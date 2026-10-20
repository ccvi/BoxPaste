import AppKit
import CryptoKit
import Foundation

// ============================================================
// 零碎工具：路径、哈希、格式化、缩略图缓存、开机启动
// ============================================================

enum Support {

    /// 数据落盘根目录：~/Library/Application Support/BoxPaste
    /// 结构与家族其他项目一致（history.json + blobs/），方便用户自己备份。
    static var appSupportRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("BoxPaste", isDirectory: true)
    }

    /// 大文件/图片的清单直接存 App Support，但**不进** iCloud 备份之外的任何地方；
    /// 这里不设 .isExcludedFromBackup —— 剪贴板历史属于用户自己会想保留的数据。

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ text: String) -> String {
        sha256(Data(text.utf8))
    }

    /// 十进制单位（与家族其他项目一致：macOS 自己的容量显示也是十进制的）。
    static func humanByteCount(_ bytes: Int) -> String {
        let value = Double(bytes)
        if bytes < 1000 { return "\(bytes) B" }
        if value < 1000 * 1000 { return String(format: "%.1f KB", value / 1000) }
        if value < 1000 * 1000 * 1000 { return String(format: "%.1f MB", value / 1_000_000) }
        return String(format: "%.2f GB", value / 1_000_000_000)
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    /// 列表右侧的时间戳：今天只给时刻，昨天加"昨天"，更早给月-日。
    static func timeLabel(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return clockFormatter.string(from: date)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨天 " + clockFormatter.string(from: date)
        }
        return shortDateFormatter.string(from: date)
    }

    static func dayTitle(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "今天" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "昨天" }
        if let week = calendar.date(byAdding: .day, value: -7, to: now), date > week { return "本周早些时候" }
        return "更早"
    }

    /// 绝对路径 → 显示用（家目录缩成 ~）
    static func prettyPath(_ url: URL) -> String {
        let path = url.path
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

// ── 缩略图缓存 ───────────────────────────────────────────────

/// 列表/网格里同一张图会被反复请求（滚动、切视图、搜索重算），
/// 每次都从盘上解 PNG 会让滚动明显发涩，所以按 URL 缓存 NSImage。
/// 只缓存缩略图，不缓存原图——原图只在预览里用一次，缓存它纯属占内存。
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSURL, NSImage>()

    private init() {
        cache.countLimit = 400
        // 只限条数不限字节的话，长跑下来缩略图位图会把 footprint 顶上去
        //（内存排查：7 小时从 29MB 涨到 104MB 的组成部分之一）。20MB 封顶。
        cache.totalCostLimit = 20 * 1024 * 1024
    }

    func thumbnail(at url: URL) -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        guard let image = NSImage(contentsOf: url) else { return nil }
        // 成本按文件字节算：NSCache 超过 totalCostLimit 时优先淘汰大的
        let cost = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 64 * 1024
        cache.setObject(image, forKey: url as NSURL, cost: cost)
        return image
    }

    func forget(_ url: URL) {
        cache.removeObject(forKey: url as NSURL)
    }
}

// ── 开机启动 ─────────────────────────────────────────────────

/// 诊断留痕（/tmp/boxpaste-diag.log）：
///   "开关拨上去又自己弹回来"这类问题，值在模型里是对的、界面画错，
///   或者写入其实失败——不看日志只能瞎猜。登录项 / Dock 策略链路都写这里。
enum DiagLog {
    static func append(_ line: String) {
        let path = "/tmp/boxpaste-diag.log"
        let text = "—— \(Date()) \(line)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

/// 用 LaunchAgent 而不是 SMAppService：
///   本项目是 ad-hoc 签名的自用应用，SMAppService 对签名身份有要求，
///   在未用正式证书签名时注册会失败（而且报错信息很难看懂）。
///   LaunchAgent 就是一个 plist，写进去就生效、删掉就取消，完全可控、可验证。
enum LoginItem {
    /// Label 与文件名都跟 bundle id 走：launchd 用 Label 去重，文件名只是习惯，
    /// 但两者不一致会让「删文件没删 Label」这种半途而废很难查。
    private static var plistURL: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return base.appendingPathComponent("LaunchAgents/\(AppIdentity.bundleIdentifier).plist")
    }

    private static var appPath: String {
        // 从 bundle 里启动时用 bundle 路径；直接跑裸可执行文件（swift run）时
        // 没有 bundle 可注册，这时候如实抛错而不是写一个指向临时目录的启动项。
        Bundle.main.bundlePath
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard appPath.hasSuffix(".app") else {
                throw NSError(domain: "BoxPaste", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "当前不是从 .app 里运行，无法设置开机启动（请先打包）",
                ])
            }
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            // -g 让它在后台启动，不抢焦点（开机时突然跳出一个窗口很烦）。
            let plist: [String: Any] = [
                "Label": AppIdentity.bundleIdentifier,
                "ProgramArguments": ["/usr/bin/open", "-g", appPath],
                "RunAtLoad": true,
                "KeepAlive": false,
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
            DiagLog.append("[LoginItem] 写入 \(plistURL.path) ✓")
        } else {
            if FileManager.default.fileExists(atPath: plistURL.path) {
                try FileManager.default.removeItem(at: plistURL)
            }
            DiagLog.append("[LoginItem] 已移除 plist")
        }
    }
}
