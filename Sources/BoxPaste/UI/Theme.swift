import AppKit
import SwiftUI

// ============================================================
// 外观常量与应用图标取用
// ============================================================

enum Theme {
    static let panelCorner: CGFloat = 16
    static let cardCorner: CGFloat = 10
    static let cardCornerSmall: CGFloat = 8
    static let contentPadding: CGFloat = 12
    static let rowSpacing: CGFloat = 6
    static let cardPadding: CGFloat = 10
    static let gridMinCard: CGFloat = 118

    /// 各类型的强调色：只用在类型徽标与色块上，不铺大面积。
    /// 大面积上色会让"剪贴板"这种信息密度高的列表变得吵。
    static func accent(for kind: ClipKind) -> Color {
        switch kind {
        case .text:  return Color(nsColor: .systemGray)
        case .link:  return Color(nsColor: .systemBlue)
        case .color: return Color(nsColor: .systemOrange)
        case .image: return Color(nsColor: .systemTeal)
        case .file:  return Color(nsColor: .systemIndigo)
        }
    }

    static let selectionStroke = Color.accentColor
    static let cardBorder = Color.primary.opacity(0.07)
    static let hoverFill = Color.primary.opacity(0.05)
    static let selectionFill = Color.accentColor.opacity(0.10)
}

/// 应用图标（来源应用 / 文件）取用与缓存。
/// NSWorkspace 每次取图标都会去问 LaunchServices，列表滚动时反复调用会明显卡，
/// 所以按 bundle id / 路径缓存。
enum AppIcons {
    private static var bundleCache: [String: NSImage] = [:]
    private static var fileCache: [String: NSImage] = [:]

    static func icon(forBundleID bundleID: String) -> NSImage? {
        if let hit = bundleCache[bundleID] { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        bundleCache[bundleID] = image
        return image
    }

    static func icon(forFile path: String) -> NSImage {
        if let hit = fileCache[path] { return hit }
        let image = NSWorkspace.shared.icon(forFile: path)
        fileCache[path] = image
        return image
    }

    /// 通用应用的兜底图标
    static let genericApp: NSImage = NSWorkspace.shared.icon(for: .application)
}
