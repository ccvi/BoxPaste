import AppKit
import Carbon.HIToolbox
import SwiftUI

// ============================================================
// 设置界面
//
// 版式照参考图：顶部分段标签（通用 / 分类 / 快捷键 / 关于），
// 内容是"卡片分组 + 行内标签 + 右侧控件"，底部留一个恢复默认。
// 卡片分组而不是每行一条分隔线：设置项之间是有类别的（启动 / 反馈 /
// 粘贴 / 数据），用分组把类别本身画出来，比一长条列表好扫。
// ============================================================

struct SettingsRootView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: $tab)
            Divider().opacity(0.6)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch tab {
                    case .general:   GeneralSettings(prefs: model.prefs)
                    case .category:  CategorySettings()
                    case .shortcut:  ShortcutSettings()
                    case .about:     AboutSettings()
                    }
                }
                .padding(16)
            }
            .scrollContentBackground(.hidden)
        }
        .frame(minWidth: 600, minHeight: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, category, shortcut, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:  return "通用"
        case .category: return "分类"
        case .shortcut: return "快捷键"
        case .about:    return "关于"
        }
    }

    var symbol: String {
        switch self {
        case .general:  return "gearshape"
        case .category: return "square.grid.2x2"
        case .shortcut: return "command"
        case .about:    return "info.circle"
        }
    }
}

struct SettingsTabBar: View {
    @Binding var selection: SettingsTab
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases) { tab in
                TabButton(tab: tab,
                          isSelected: selection == tab,
                          namespace: pill) {
                    // 加一层动画：切换时高亮块滑过去，而不是"啪"地跳一下。
                    // 之前是纯 Button + 换背景色，点完除了文字变色没有任何反馈，
                    // 手感上就像点空了。
                    withAnimation(.snappy(duration: 0.18)) { selection = tab }
                }
            }
        }
        .padding(4)
        .background(Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }
}

private struct TabButton: View {
    let tab: SettingsTab
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: tab.symbol).font(.system(size: 15))
                Text(tab.title).font(.system(size: 11))
            }
            .frame(width: 84, height: 46)
            // contentShape 铺满整个 84×46：不给它的话只有图标和文字本身可点，
            // 空白处点了没反应——这就是"按钮不灵活"最直接的来源。
            .contentShape(Rectangle())
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.10))
                        .matchedGeometryEffect(id: "tab", in: namespace)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                }
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// ── 通用组件 ─────────────────────────────────────────────────

struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
                    .padding(.bottom, 6)
            }
            VStack(spacing: 0) {
                content
            }
            .background(Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            }
        }
    }
}

struct SettingsRow<Content: View>: View {
    let label: String
    var detail: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 12))
                if let detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            content
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

struct RowDivider: View {
    var body: some View {
        Divider().opacity(0.5).padding(.leading, 12)
    }
}

/// 统一的开关样式。
/// SwiftUI 的 Toggle 在 macOS 上默认画成"方形勾选框"——又小、点击热区也窄，
/// 就是参考图里被红框圈住的那一批。`.switch` 才是系统设置里那种滑动开关。
/// 全应用统一走这个包装，免得哪一处漏掉 toggleStyle 又变回勾选框。
struct SettingsSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.regular)
    }
}

// ── 通用 ─────────────────────────────────────────────────────

struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel
    // 必须直接观察 PreferencesStore：pollInterval 等 @Published 挂在它身上，
    // 只观察 AppModel 的话，滑块拖动了这一页也不重绘——数值永远停在旧值
    // （设置本身其实已生效，纯显示问题，用户实测踩过）。
    @ObservedObject var prefs: PreferencesStore
    @State private var storageSummary = ""
    // 清空历史要先过确认窗（用户指定）：两个按钮都是不可撤销的批量删除，
    // 一发滑直接见底就太危险了。
    @State private var pendingClear: ClearKind?

    enum ClearKind {
        case keepPinned, all

        var title: String { self == .keepPinned ? "保留置顶清空" : "全部清空" }
        var detail: String {
            self == .keepPinned
                ? "将删除所有未置顶条目（「收藏」保留），此操作不可撤销。"
                : "将删除所有条目（「收藏」保留），此操作不可撤销。"
        }
    }

    var body: some View {
        SettingsCard(title: "启动与窗口") {
            SettingsRow(label: "开机自动启动", detail: "登录后静默启动，不抢焦点") {
                SettingsSwitch(isOn: prefs.binding(\.launchAtLogin))
            }
            RowDivider()
            SettingsRow(label: "在 Dock 中隐藏图标",
                        detail: "初始安装时 Dock 会显示图标；打开后从 Dock 移除，只驻留菜单栏") {
                SettingsSwitch(isOn: prefs.binding(\.hideDockIcon))
            }
            RowDivider()
            SettingsRow(label: "默认视图", detail: "面板每次呼出时用哪种样式展示") {
                Picker("", selection: prefs.binding(\.defaultView)) {
                    ForEach(ViewMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.regular)
                .frame(width: 140)
            }
            RowDivider()
            SettingsRow(label: "面板置顶",
                        detail: "打开后点别处不会自动收起；也可以点面板顶部那个图钉来回切") {
                SettingsSwitch(isOn: prefs.binding(\.alwaysOnTop))
            }
        }

        SettingsCard(title: "菜单栏") {
            SettingsRow(label: "菜单栏图标", detail: menuBarDetail) {
                HStack(spacing: 8) {
                    Image(systemName: menuBarPlaced == false ? "exclamationmark.triangle.fill" : "menubar.rectangle")
                        .font(.system(size: 14))
                        .foregroundStyle(menuBarPlaced == false ? Color(nsColor: .systemOrange) : Color(nsColor: .systemGreen))
                    Button("打开「菜单栏」设置") { StatusItemController.openMenuBarSettings() }
                        .controlSize(.regular)
                }
            }
            RowDivider()
            SettingsRow(label: "菜单栏图标翻转一下", detail: "复制成功时给一个不用看屏幕也能感知的反馈") {
                SettingsSwitch(isOn: prefs.binding(\.animateStatusIcon))
            }
            RowDivider()
            SettingsRow(label: "复制成功时播放提示音") {
                HStack(spacing: 8) {
                    Button("试听") { SoundFeedback.preview(soundName: prefs.value.feedbackSound) }
                        .controlSize(.regular)
                    SettingsSwitch(isOn: prefs.binding(\.playSound))
                }
            }
            RowDivider()
            SettingsRow(label: "提示音音色", detail: "换音色后点上面的「试听」先听一下") {
                Picker("", selection: prefs.binding(\.feedbackSound)) {
                    ForEach(SoundFeedback.options, id: \.name) { option in
                        Text(option.title).tag(option.name)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            }
        }

        SettingsCard(title: "粘贴") {
            SettingsRow(label: "回车后自动粘贴",
                        detail: "需要「辅助功能」授权才能替你按 ⌘V。未授权时会自动降级为"
                              + "「已复制，你自己按 ⌘V」，不会报错。") {
                SettingsSwitch(isOn: prefs.binding(\.autoPaste))
            }
            RowDivider()
            // 授权状态用 model.accessibilityGranted（实时值，TCC 通知/轮询驱动），
            // 不直接问 Paster：后者在 SwiftUI 里是"渲染时随手一查"，没有重算时机，
            // 用户勾完授权回来看到的永远是打开窗口那一刻的状态。
            let granted = model.accessibilityGranted
            SettingsRow(label: "辅助功能授权状态",
                        detail: granted ? "已授权，回车 / 双击即粘贴" : "未授权（勾选后几秒内自动变绿）") {
                HStack(spacing: 8) {
                    Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(granted ? Color(nsColor: .systemGreen) : Color(nsColor: .systemOrange))
                    Button("打开系统设置") { Paster.openAccessibilitySettings() }
                        .controlSize(.regular)
                }
            }
        }

        SettingsCard(title: "历史") {
            SettingsRow(label: "最多保留条数", detail: "超出后从最旧的非置顶条目开始淘汰；置顶条目不受限制") {
                HStack(spacing: 8) {
                    TextField("", value: prefs.binding(\.maxItems), format: .number)
                        .frame(width: 70)
                        .textFieldStyle(.roundedBorder)
                    Stepper("", value: prefs.binding(\.maxItems), in: 50...5000, step: 50)
                        .labelsHidden()
                }
            }
            RowDivider()
            SettingsRow(label: "监听间隔", detail: "越短越及时，但读剪贴板的次数也越多；0.35 秒是常用值") {
                HStack(spacing: 8) {
                    Slider(value: prefs.binding(\.pollInterval), in: 0.15...1.0, step: 0.05)
                        .frame(width: 140)
                    Text(String(format: "%.2f 秒", prefs.value.pollInterval))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 62, alignment: .leading)
                }
            }
            RowDivider()
            SettingsRow(label: "忽略保密内容",
                        detail: "密码管理器标记为「保密/临时」的剪贴板内容不记录") {
                SettingsSwitch(isOn: prefs.binding(\.ignoreConcealed))
            }
        }

        SettingsCard(title: "数据") {
            SettingsRow(label: "当前占用", detail: storageSummary) {
                HStack(spacing: 8) {
                    Button("导出…") { model.exportHistory() }.controlSize(.regular)
                    Button("导入…") { model.importHistory() }.controlSize(.regular)
                    Button("打开数据目录") {
                        NSWorkspace.shared.open(model.store.root)
                    }
                    .controlSize(.regular)
                }
            }
            RowDivider()
            SettingsRow(label: "清空历史", detail: "「收藏」里的条目始终保留；此操作不可撤销") {
                HStack(spacing: 8) {
                    Button("保留置顶") { pendingClear = .keepPinned }.controlSize(.regular)
                    Button("全部清空") { pendingClear = .all }.controlSize(.regular)
                }
            }
            .confirmationDialog(
                pendingClear?.title ?? "",
                isPresented: Binding(
                    get: { pendingClear != nil },
                    set: { if !$0 { pendingClear = nil } }),
                titleVisibility: .visible
            ) {
                Button(pendingClear?.title ?? "确认清空", role: .destructive) {
                    model.clearHistory(keepPinned: pendingClear == .keepPinned)
                    pendingClear = nil
                }
                Button("取消", role: .cancel) { pendingClear = nil }
            } message: {
                Text(pendingClear?.detail ?? "")
            }
        }

        HStack {
            Spacer()
            Button("恢复默认设置") { prefs.resetToDefaults() }
        }
        .padding(.top, 2)
        .onAppear(perform: refreshStorage)
        .onChange(of: model.items.count) { _, _ in refreshStorage() }
    }

    private func refreshStorage() {
        storageSummary = "\(model.items.count) 条 · 图片文件 \(Support.humanByteCount(model.store.totalBlobBytes()))"
    }

    /// nil 表示还没核对。macOS 26 上第三方菜单栏项由 ControlCenter 排版，
    /// 没被收下的项窗口会停在屏幕外——属性上 `isVisible` 仍然是 true，
    /// 所以这里显示的是"真的看得见吗"，不是"创建成功了吗"。
    private var menuBarPlaced: Bool? { model.menuBarItemPlaced }

    private var menuBarDetail: String {
        switch model.menuBarItemPlaced {
        case .some(true):
            return "正常显示中。想隐藏/移动它，去「系统设置 → 菜单栏」"
        case .some(false):
            return "系统没有把图标收进菜单栏。macOS 26 的开关在「系统设置 → 菜单栏」，"
                 + "在那里把 BoxPaste 打开即可（程序无法代改）"
        case .none:
            return "启动后会自动核对一次。macOS 26 的开关在「系统设置 → 菜单栏」"
        }
    }
}

// ── 分类 ─────────────────────────────────────────────────────

struct CategorySettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard(title: "分类") {
                VStack(spacing: 0) {
                    rowIndex
                }
            }

            HStack {
                Button {
                    var category = Category(name: "新分类", symbol: "star")
                    category.rules = [Rule(field: .kind, value: ClipKind.text.rawValue)]
                    model.prefs.value.categories.append(category)
                } label: {
                    Label("新建分类", systemImage: "plus")
                }
                .controlSize(.regular)
                Spacer()
                Text("规则之间是「且」的关系；上面的顺序就是面板顶部标签的顺序")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var rowIndex: some View {
        ForEach(Array(model.prefs.value.categories.enumerated()), id: \.element.id) { index, category in
            if index > 0 { RowDivider() }
            CategoryEditor(category: binding(for: category.id))
        }
    }

    private func binding(for id: UUID) -> Binding<Category> {
        Binding(
            get: {
                model.prefs.value.categories.first { $0.id == id }
                    ?? Category(name: "已删除", symbol: "questionmark")
            },
            set: { updated in
                guard let index = model.prefs.value.categories.firstIndex(where: { $0.id == id }) else { return }
                model.prefs.value.categories[index] = updated
            })
    }
}

/// 分类排序用的小箭头。到头了置灰而不是隐藏——位置不跳，用户才敢连点。
struct ReorderButton: View {
    let symbol: String
    let help: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 16, height: 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.3))
        .disabled(!enabled)
        .help(help)
    }
}

struct CategoryEditor: View {    @EnvironmentObject var model: AppModel
    @Binding var category: Category

    private static let symbolChoices = ["star", "link", "photo", "folder", "paintpalette",
                                        "doc.text", "terminal", "code", "envelope",
                                        "cart", "bookmark", "tag"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // 排序箭头放在最左边：它作用于"整个分类"，所以贴着行首比塞在
                // 名字和删除按钮中间更清楚，也不会被误当成改名字的一部分。
                VStack(spacing: 1) {
                    ReorderButton(symbol: "chevron.up",
                                  help: "上移",
                                  enabled: model.canMoveCategory(id: category.id, by: -1)) {
                        model.moveCategory(id: category.id, by: -1)
                    }
                    ReorderButton(symbol: "chevron.down",
                                  help: "下移",
                                  enabled: model.canMoveCategory(id: category.id, by: 1)) {
                        model.moveCategory(id: category.id, by: 1)
                    }
                }
                .frame(width: 16)

                Image(systemName: category.symbol)
                    .font(.system(size: 12))
                    .frame(width: 18)
                TextField("分类名称", text: $category.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)

                Picker("", selection: $category.symbol) {
                    ForEach(Self.symbolChoices, id: \.self) { symbol in
                        Image(systemName: symbol).tag(symbol)
                    }
                }
                .labelsHidden()
                .frame(width: 70)

                if category.isBuiltin {
                    Text("内置")
                        .font(.system(size: 9))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        model.prefs.value.categories.removeAll { $0.id == category.id }
                    } label: {
                        Image(systemName: "trash").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("删除这个分类（条目本身不会删）")
                }

                Spacer(minLength: 0)

                Text("命中 \(model.categoryCount(category)) 条")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(category.rules.enumerated()), id: \.element.id) { index, rule in
                    HStack(spacing: 6) {
                        Picker("", selection: ruleBinding(index: index, keyPath: \.field)) {
                            ForEach(RuleField.allCases) { field in Text(field.title).tag(field) }
                        }
                        .labelsHidden()
                        .frame(width: 96)

                        TextField(rule.field.hint, text: ruleBinding(index: index, keyPath: \.value))
                            .textFieldStyle(.roundedBorder)

                        Button {
                            category.rules.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle").font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                Button {
                    category.rules.append(Rule(field: .textContains, value: ""))
                } label: {
                    Label("添加规则", systemImage: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
            .padding(.leading, 26)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func ruleBinding<T>(index: Int, keyPath: WritableKeyPath<Rule, T>) -> Binding<T> {
        Binding(
            get: {
                guard index < category.rules.count else { return Rule(field: .textContains, value: "")[keyPath: keyPath] }
                return category.rules[index][keyPath: keyPath]
            },
            set: { newValue in
                guard index < category.rules.count else { return }
                category.rules[index][keyPath: keyPath] = newValue
            })
    }
}

// ── 快捷键 ───────────────────────────────────────────────────

struct ShortcutSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard(title: "全局快捷键") {
                ShortcutRow(action: .recallPanel)
                RowDivider()
                ShortcutRow(action: .openSettings)
            }

            SettingsCard(title: "面板内快捷键") {
                ShortcutRow(action: .paste)
                RowDivider()
                ShortcutRow(action: .preview)
                RowDivider()
                ShortcutRow(action: .pin)
                RowDivider()
                ShortcutRow(action: .copy)
                RowDivider()
                ShortcutRow(action: .delete)
            }

            SettingsCard(title: "固定快捷键") {
                ForEach(Array(ShortcutAction.fixedShortcuts.enumerated()), id: \.element.keys) { index, entry in
                    if index > 0 { RowDivider() }
                    SettingsRow(label: entry.action) {
                        Text(entry.keys)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let message = model.statusMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .systemOrange))
            }
        }
    }
}

struct ShortcutRow: View {
    @EnvironmentObject var model: AppModel
    let action: ShortcutAction
    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var warning: String?

    var body: some View {
        SettingsRow(label: action.title, detail: warning ?? action.note) {
            HStack(spacing: 8) {
                Button {
                    isRecording ? stopRecording() : startRecording()
                } label: {
                    Text(isRecording ? "按下新键…" : model.prefs.value.spec(for: action).display)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .frame(minWidth: 76)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .tint(isRecording ? Color.accentColor : nil)

                Button {
                    model.prefs.value.shortcuts[action.rawValue] = action.defaultSpec
                    warning = nil
                } label: {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("恢复默认")
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        warning = nil
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Esc 取消录制，否则用户会被困在"按什么都没反应"的状态里
            if Int(event.keyCode) == kVK_Escape {
                stopRecording()
                return nil
            }
            let spec = KeySpec.from(event)
            if action.isGlobal && !spec.isUsableAsGlobal {
                warning = "全局快捷键至少要带 ⌘ / ⌥ / ⌃ 之一"
                stopRecording()
                return nil
            }
            if let conflict = conflictingAction(for: spec) {
                warning = "与「\(conflict.title)」冲突了"
                stopRecording()
                return nil
            }
            model.prefs.value.shortcuts[action.rawValue] = spec
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    private func conflictingAction(for spec: KeySpec) -> ShortcutAction? {
        for other in ShortcutAction.allCases where other != action {
            if model.prefs.value.spec(for: other) == spec { return other }
        }
        return nil
    }
}

// ── 关于 ─────────────────────────────────────────────────────

struct AboutSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("BoxPaste").font(.system(size: 18, weight: .semibold))
                    Text("版本 \(model.appVersion)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("作者：ccvi1223 · 邮箱：ccvi1223@qq.com")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("剪贴板历史管理器：菜单栏常驻，热键呼出，全键盘操作")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            SettingsCard(title: "数据位置") {
                SettingsRow(label: "历史与图片", detail: Support.prettyPath(model.store.root)) {
                    Button("打开") { NSWorkspace.shared.open(model.store.root) }
                        .controlSize(.regular)
                }
                RowDivider()
                SettingsRow(label: "运行自检", detail: "命令行执行：BoxPaste --selftest") {
                    Button("运行") {
                        model.statusMessage = "自检结果请看终端输出（本应用是 GUI 进程，不打印到界面）"
                    }
                    .controlSize(.regular)
                }
            }

            SettingsCard(title: "权限说明") {
                SettingsRow(label: "辅助功能", detail: "仅用于「自动粘贴」时模拟 ⌘V；不做任何输入监听、不联网") {
                    Text(model.accessibilityGranted ? "已授权" : "未授权")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
