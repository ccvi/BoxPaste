import AppKit
import Combine
import Foundation
import SwiftUI

// ============================================================
// 设置项：一份 Codable 结构 + 一个带落盘的容器
//
// 为什么不用一堆 @AppStorage：
//   分类是数组、快捷键是字典，@AppStorage 处理不了；而且"改了要立刻生效"
//   这件事（换 Dock 显示策略、重注册热键）需要一个统一的变更回调，
//   @AppStorage 的散点写法会让这类副作用散落各处。
// ============================================================

enum ViewMode: String, Codable, CaseIterable, Identifiable {
    case grid
    case compact
    case rich

    var id: String { rawValue }

    /// ⌥数字快捷键的编号（WindowControllers 里 ⌥1/2/3 按视图**类型**绑定；
    /// ⌘1-9 已让位给"直接粘贴第 N 条"——Maccy 的习惯键位，更高频）。
    /// 顶部按钮的显示顺序（丰富→简洁→网格，用户指定）与它无关——
    /// 按钮换了位置快捷键还认类型，tooltip 的编号要从这里取，别用显示下标。
    var shortcutDigit: Int {
        switch self {
        case .grid:    return 1
        case .compact: return 2
        case .rich:    return 3
        }
    }

    var title: String {
        switch self {
        case .grid:    return "网格视图"
        case .compact: return "简洁列表"
        case .rich:    return "丰富列表"
        }
    }

    var shortTitle: String {
        switch self {
        case .grid:    return "网格"
        case .compact: return "简洁"
        case .rich:    return "丰富"
        }
    }

    var symbol: String {
        switch self {
        case .grid:    return "square.grid.2x2"
        case .compact: return "list.bullet"
        case .rich:    return "list.bullet.rectangle"
        }
    }
}

struct Preferences: Codable, Equatable {
    var maxItems: Int = 500
    /// 最长保存时间（天）。0 = 不限。
    /// 到期清理时「收藏」豁免：收藏是用户手动挑出来的，跟"按时间清扫"是两回事。
    var maxAgeDays: Int = 0
    /// 在 Dock 里隐藏图标。默认关：初始安装时 Dock 显示图标（用户指定，
    /// 1.0.14 由旧的 showInDock 反转而来——语义从"要不要显示"变成"要不要藏"）。
    var hideDockIcon: Bool = false
    /// 旧键（1.0.13 及以前，true=显示）。只为读旧配置存在，
    /// 解码后保留原值随 encode 写回，新代码一律读 hideDockIcon。
    var showInDock: Bool?
    /// 复制成功后菜单栏图标翻转一下
    var animateStatusIcon: Bool = true
    /// 复制成功后的提示音
    var playSound: Bool = true
    /// 回车粘贴时是否模拟 ⌘V（需要辅助功能授权，未授权自动降级）
    var autoPaste: Bool = true
    /// 复制成功后的提示音（系统音效名）。候选清单在 SoundFeedback.options。
    var feedbackSound: String = "Glass"
    /// 剪贴板轮询间隔（秒）
    var pollInterval: Double = 0.35
    /// 忽略密码管理器等标记为"保密/临时"的剪贴板内容
    var ignoreConcealed: Bool = true
    /// 记录富文本（RTF/HTML）：开着粘贴能保住格式，代价是 blobs 目录变大。
    /// 菜单栏右键可随时开关（用户要求），默认开。
    var captureRichText: Bool = true
    var defaultView: ViewMode = .rich
    var categories: [Category] = Category.builtins
    var shortcuts: [String: KeySpec] = Preferences.defaultShortcuts
    var launchAtLogin: Bool = false
    var panelWidth: Double = 380
    var panelHeight: Double = 580
    /// 面板置顶：打开后失焦也不收起，适合一边看资料一边往里粘贴。
    var alwaysOnTop: Bool = false
    /// 占用到线且空闲时自动重开自己（内存回收，规则见 AutoRestartPolicy）。
    /// 默认开：动作本身是安全的——先落盘再退出、helper 拉起失败就不退。
    /// 关掉它 = 用户接受内存随使用增长。
    var autoRestartEnabled: Bool = true

    /// 「最长保存时间」的可选值（单位：天，0 = 不限）。显示顺序按用户给的 30/45/60/90/不限。
    static let maxAgeOptions: [Int] = [30, 45, 60, 90, 0]

    static func maxAgeTitle(_ days: Int) -> String {
        days > 0 ? "\(days) 天" : "不限"
    }

    static var defaultShortcuts: [String: KeySpec] {
        var table: [String: KeySpec] = [:]
        for action in ShortcutAction.allCases {
            table[action.rawValue] = action.defaultSpec
        }
        return table
    }

    func spec(for action: ShortcutAction) -> KeySpec {
        shortcuts[action.rawValue] ?? action.defaultSpec
    }

    func category(id: UUID?) -> Category? {
        guard let id else { return nil }
        return categories.first { $0.id == id }
    }

    // 手写解码：新增字段时缺字段就用默认值。
    // 用合成的解码器会因为一个新增字段把整份旧配置判为不可解，
    // 结果是"升级一次版本，设置全丢"。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Preferences()
        maxItems = try container.decodeIfPresent(Int.self, forKey: .maxItems) ?? fallback.maxItems
        maxAgeDays = try container.decodeIfPresent(Int.self, forKey: .maxAgeDays) ?? fallback.maxAgeDays
        // 只认选项里的值：手改过配置、或将来改了选项清单的，一律落回「不限」，
        // 免得 Picker 因为选中项不存在显示空白（音效清单就是这么踩过一次）
        if !Preferences.maxAgeOptions.contains(maxAgeDays) { maxAgeDays = fallback.maxAgeDays }
        showInDock = try container.decodeIfPresent(Bool.self, forKey: .showInDock)
        // 新键优先；没有新键时从旧键反相迁移（!旧值），保证升级前后 Dock 实际状态不变
        if let legacy = showInDock {
            hideDockIcon = try container.decodeIfPresent(Bool.self, forKey: .hideDockIcon) ?? !legacy
        } else {
            hideDockIcon = try container.decodeIfPresent(Bool.self, forKey: .hideDockIcon) ?? fallback.hideDockIcon
        }
        animateStatusIcon = try container.decodeIfPresent(Bool.self, forKey: .animateStatusIcon) ?? fallback.animateStatusIcon
        playSound = try container.decodeIfPresent(Bool.self, forKey: .playSound) ?? fallback.playSound
        feedbackSound = try container.decodeIfPresent(String.self, forKey: .feedbackSound) ?? fallback.feedbackSound
        // 音效清单换过一轮（Sosumi/Submarine 下线）：旧值不在当前清单里就落回默认，
        // 否则设置页的 Picker 会因为选中项不存在而显示空白。
        if !SoundFeedback.availableNames.contains(feedbackSound) {
            feedbackSound = fallback.feedbackSound
        }
        autoPaste = try container.decodeIfPresent(Bool.self, forKey: .autoPaste) ?? fallback.autoPaste
        pollInterval = try container.decodeIfPresent(Double.self, forKey: .pollInterval) ?? fallback.pollInterval
        ignoreConcealed = try container.decodeIfPresent(Bool.self, forKey: .ignoreConcealed) ?? fallback.ignoreConcealed
        captureRichText = try container.decodeIfPresent(Bool.self, forKey: .captureRichText) ?? fallback.captureRichText
        defaultView = try container.decodeIfPresent(ViewMode.self, forKey: .defaultView) ?? fallback.defaultView
        categories = try container.decodeIfPresent([Category].self, forKey: .categories) ?? fallback.categories
        shortcuts = try container.decodeIfPresent([String: KeySpec].self, forKey: .shortcuts) ?? fallback.shortcuts
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? fallback.launchAtLogin
        panelWidth = try container.decodeIfPresent(Double.self, forKey: .panelWidth) ?? fallback.panelWidth
        panelHeight = try container.decodeIfPresent(Double.self, forKey: .panelHeight) ?? fallback.panelHeight
        alwaysOnTop = try container.decodeIfPresent(Bool.self, forKey: .alwaysOnTop) ?? fallback.alwaysOnTop
        autoRestartEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoRestartEnabled) ?? fallback.autoRestartEnabled

        // 内置分类必须始终存在：用户升级前删过、或配置来自更早的版本时，
        // 补回来并保留同 id 的用户改动（改名/改规则都算）。
        // 退役的内置分类（见 Category.retiredBuiltinIDs）反过来要从旧配置里剔除——
        // 光从 builtins 里删掉不够，合并逻辑会把它们当"缺失的内置"重新补回来。
        var merged = categories.filter { !Category.retiredBuiltinIDs.contains($0.id) }
        for builtin in Category.builtins where !merged.contains(where: { $0.id == builtin.id }) {
            merged.append(builtin)
        }
        // 「收藏」1.0.14 起是内置分类，但旧配置里它那一行的 isBuiltin 是 false
        // （当年是用户自建）——按 id 对上的存量行要扳成 true，
        // 否则设置页照样显示删除按钮。id 没变，条目上的手动归类不用迁移。
        for index in merged.indices
        where Category.builtins.contains(where: { $0.id == merged[index].id }) && !merged[index].isBuiltin {
            merged[index].isBuiltin = true
        }
        categories = merged
    }

    init() {}

    enum CodingKeys: String, CodingKey {
        case maxItems, maxAgeDays, hideDockIcon, showInDock, animateStatusIcon, playSound, feedbackSound, autoPaste, pollInterval
        case ignoreConcealed, captureRichText, defaultView, categories, shortcuts, launchAtLogin
        case panelWidth, panelHeight, alwaysOnTop
        case autoRestartEnabled
    }
}

/// 设置的读写与变更广播。
@MainActor
final class PreferencesStore: ObservableObject {
    @Published var value: Preferences {
        didSet {
            guard value != oldValue else { return }
            save()
            didChange?(oldValue, value)
        }
    }

    /// 变更回调：AppModel 用它做副作用（换 Dock 策略、重注册热键、重启轮询等）
    var didChange: (@MainActor (Preferences, Preferences) -> Void)?

    private let defaults: UserDefaults
    private static let key = "com.pcxx.boxpaste.preferences"

    /// 一次性迁移的哨兵键：默认面板宽度 430 → 380（1.0.7，用户要求"面板窄一点"）。
    private static let panelWidthMigrationKey = "migration.1.0.7.panelWidth380"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(Preferences.self, from: data) {
            value = decoded
        } else {
            value = Preferences()
        }
        // 默认宽度变了，但只搬"存的还是旧默认值"的人：手动调过宽度的尊重用户的选择。
        // 放在解码后而不是解码器里：这不是"字段缺失补默认"，是跨版本的一次性搬运。
        if defaults.object(forKey: Self.panelWidthMigrationKey) == nil {
            defaults.set(true, forKey: Self.panelWidthMigrationKey)
            if value.panelWidth == 430 { value.panelWidth = 380 }
        }
        // 首次启动时把开机启动状态对齐真实情况（用户可能手动删过 plist）
        if value.launchAtLogin != LoginItem.isEnabled {
            value.launchAtLogin = LoginItem.isEnabled
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: Self.key)
    }

    func resetToDefaults() {
        value = Preferences()
    }

    /// 给 SwiftUI 控件用的绑定。
    /// 为什么不直接把 @Published 的 value 传进视图：设置项里既有嵌套结构
    /// （分类数组里的规则）又有字典（快捷键），一层层写显式 Binding 会失控，
    /// 统一从 keyPath 造绑定最省心，而且任何写操作都会走 @Published 的 didSet
    /// —— 也就是"改完立刻生效"那条通路不会被绕过。
    func binding<T>(_ keyPath: WritableKeyPath<Preferences, T>) -> Binding<T> {
        Binding(get: { self.value[keyPath: keyPath] },
                set: { self.value[keyPath: keyPath] = $0 })
    }
}
