import AppKit
import Foundation

// ============================================================
// 内容识别与分类规则匹配
//
// 全部是纯函数，自检直接调用。刻意不依赖剪贴板，方便用文本喂断言。
// ============================================================

// ── 颜色 ────────────────────────────────────────────────────

/// 解析出来的一份颜色。同时给出几种常见写法，
/// 因为"复制这个颜色"的下一步通常是粘进 CSS、SwiftUI 或设计工具。
struct ColorValue: Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    private func byte(_ value: Double) -> Int { Int((value * 255).rounded()) }

    /// 有透明度时才输出 #RRGGBBAA，否则输出 #RRGGBB —— 多两位少两位
    /// 在 CSS 里是两种不同的东西，不能一律补齐。
    var hex: String {
        let base = String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
        return alpha >= 0.999 ? base : base + String(format: "%02X", byte(alpha))
    }

    var rgbString: String {
        if alpha >= 0.999 {
            return String(format: "rgb(%d, %d, %d)", byte(red), byte(green), byte(blue))
        }
        return String(format: "rgba(%d, %d, %d, %.2f)", byte(red), byte(green), byte(blue), alpha)
    }

    var hslString: String {
        let maxValue = max(red, green, blue)
        let minValue = min(red, green, blue)
        let lightness = (maxValue + minValue) / 2
        var hue: Double = 0
        var saturation: Double = 0
        if maxValue != minValue {
            let delta = maxValue - minValue
            saturation = lightness > 0.5 ? delta / (2 - maxValue - minValue) : delta / (maxValue + minValue)
            switch maxValue {
            case red:   hue = (green - blue) / delta + (green < blue ? 6 : 0)
            case green: hue = (blue - red) / delta + 2
            default:    hue = (red - green) / delta + 4
            }
            hue /= 6
        }
        return String(format: "hsl(%.0f, %.0f%%, %.0f%%)",
                      (hue * 360).rounded(), (saturation * 100).rounded(), (lightness * 100).rounded())
    }

    var platformColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

enum ContentClassifier {

    // ── 颜色解析 ─────────────────────────────────────────────

    /// 严格整串匹配，不做"文本里含颜色"的模糊识别。
    /// 为什么严格：`#1234` 在议题号、坐标、错误码里到处都是，
    /// 一旦允许子串匹配，剪贴板里半数文本都会被打上"颜色"标签。
    static func parseColor(_ raw: String) -> ColorValue? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 32, !text.contains("\n") else { return nil }

        if text.hasPrefix("#") {
            let digits = String(text.dropFirst())
            return color(fromHexDigits: digits)
        }
        if text.lowercased().hasPrefix("0x") {
            return color(fromHexDigits: String(text.dropFirst(2)))
        }
        if let match = firstMatch(#"^rgba?\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*(?:,\s*(0|1|0?\.\d+)\s*)?\)$"#,
                                  in: text) {
            guard let r = Double(match[1]), let g = Double(match[2]), let b = Double(match[3]),
                  (0...255).contains(r), (0...255).contains(g), (0...255).contains(b) else { return nil }
            let a = match[4].isEmpty ? 1 : (Double(match[4]) ?? 1)
            return ColorValue(red: r / 255, green: g / 255, blue: b / 255, alpha: min(max(a, 0), 1))
        }
        return nil
    }

    private static func color(fromHexDigits digits: String) -> ColorValue? {
        guard digits.allSatisfy({ $0.isHexDigit }) else { return nil }
        let chars = Array(digits)
        func component(_ slice: ArraySlice<Character>) -> Double {
            Double(Int(String(slice), radix: 16) ?? 0) / 255
        }
        switch chars.count {
        case 3, 4:
            // #RGB / #RGBA：每一位重复成两位（#f00 → #ff0000）
            let expanded = chars.map { "\($0)\($0)" }.joined()
            return color(fromHexDigits: expanded)
        case 6:
            return ColorValue(red: component(chars[0..<2]), green: component(chars[2..<4]),
                              blue: component(chars[4..<6]), alpha: 1)
        case 8:
            return ColorValue(red: component(chars[0..<2]), green: component(chars[2..<4]),
                              blue: component(chars[4..<6]), alpha: component(chars[6..<8]))
        default:
            return nil
        }
    }

    // ── 链接判定 ─────────────────────────────────────────────

    /// 整串（允许前后空白）是一个 http/https 地址才算链接。
    /// 不放行裸域名（example.com）：剪贴板里"文件名.js""package.json"
    /// 这类文本太多，裸域名判定会大面积误伤。
    static func isLink(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 2048, !text.contains("\n"), !text.contains(" ") else { return false }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return false }
        guard scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host, host.contains(".") else { return false }
        return true
    }

    /// 文本类内容的细分：链接 → 颜色 → 普通文本
    static func kind(forText text: String) -> ClipKind {
        if isLink(text) { return .link }
        if parseColor(text) != nil { return .color }
        return .text
    }

    // ── 规则匹配 ─────────────────────────────────────────────

    /// 一个分类的多条规则是 **AND** 关系；空规则列表**匹配不到任何条目**。
    /// 空规则当成"全部都收"是很直觉的写法，但那会让新建的空分类立刻吞掉
    /// 整个历史，用户却以为自己还没配规则。
    static func matches(_ item: ClipItem, rules: [Rule]) -> Bool {
        guard !rules.isEmpty else { return false }
        return rules.allSatisfy { matches(item, rule: $0) }
    }

    static func matches(_ item: ClipItem, rule: Rule) -> Bool {
        let needle = rule.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        switch rule.field {
        case .kind:
            return item.kind.rawValue.caseInsensitiveCompare(needle) == .orderedSame
                || item.kind.title == needle
        case .sourceApp:
            let name = item.sourceAppName ?? ""
            let bundle = item.sourceBundleID ?? ""
            return name.localizedCaseInsensitiveContains(needle)
                || bundle.localizedCaseInsensitiveContains(needle)
        case .textContains:
            return item.searchableText.localizedCaseInsensitiveContains(needle)
        case .textRegex:
            guard let regex = cachedRegex(needle) else { return false }
            let range = NSRange(item.searchableText.startIndex..., in: item.searchableText)
            return regex.firstMatch(in: item.searchableText, range: range) != nil
        }
    }

    // ── 正则缓存 ─────────────────────────────────────────────
    //
    // 为什么必须缓存：matches 会被「分类数 × 条目数」次调用
    //（rebuildCategoryCounts 就是 4 个分类 × 402 条 = 1608 次），
    // 而 NSRegularExpression(pattern:) 编译一次要几十微秒 —— 每次刷新
    // 白烧几十毫秒 CPU。pattern 来自用户配置、总共就那么几条，缓存下来毫无压力。
    //
    // 加锁：目前调用都在主线程，但这是纯函数层的共享可变状态，
    // 将来放到后台算（比如异步刷新）时会静默数据竞争，锁的成本远低于编译。

    private static var regexCache: [String: NSRegularExpression] = [:]
    private static let regexCacheLock = NSLock()
    /// 规则条数本来就少；给个上限防止长期运行下无限增长
    private static let regexCacheLimit = 64

    static func cachedRegex(_ pattern: String) -> NSRegularExpression? {
        regexCacheLock.lock()
        if let hit = regexCache[pattern] {
            regexCacheLock.unlock()
            return hit
        }
        regexCacheLock.unlock()

        // 编译放在锁外：编译是慢操作，别让并发调用排队等它
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        regexCacheLock.lock()
        if regexCache.count >= regexCacheLimit { regexCache.removeAll(keepingCapacity: true) }
        regexCache[pattern] = regex
        regexCacheLock.unlock()
        return regex
    }

    /// 条目命中的所有分类（规则命中 ∪ 手动归入）
    static func categoryIDs(for item: ClipItem, in categories: [Category]) -> Set<UUID> {
        var result = Set(item.manualCategoryIDs)
        for category in categories where matches(item, rules: category.rules) {
            result.insert(category.id)
        }
        return result
    }

    // ── 小工具 ───────────────────────────────────────────────

    /// 取第一个匹配的各捕获组（下标 0 是整串）。捕获组没参与匹配时给空串，
    /// 于是调用方不用到处写 optional 解包。
    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        // 走同一份缓存：颜色解析在每次 kind 判定时都会调（402 条就是 402 次编译）
        guard let regex = cachedRegex(pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        var groups: [String] = []
        for index in 0..<match.numberOfRanges {
            if let groupRange = Range(match.range(at: index), in: text) {
                groups.append(String(text[groupRange]))
            } else {
                groups.append("")
            }
        }
        return groups
    }
}
