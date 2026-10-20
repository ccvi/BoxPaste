import AppKit
import Combine
import Foundation

// ============================================================
// 全局状态中枢
//
// 界面（面板、预览、设置）都只跟它说话；它再去指挥仓库、监听器、热键。
// 需要反向操作窗口的地方（关面板、开设置、切 Dock 策略）走回调而不是
// 直接持有控制器，免得 AppModel ↔ 窗口控制器 互相强引用成环。
// ============================================================

@MainActor
final class AppModel: ObservableObject {

    // ── 数据 ─────────────────────────────────────────────────

    @Published private(set) var items: [ClipItem] = []
    @Published var query: String = "" {
        didSet { if query != oldValue { ensureValidSelection() } }
    }
    @Published var selectedCategoryID: UUID? = nil {
        didSet { if selectedCategoryID != oldValue { ensureValidSelection() } }
    }
    @Published var viewMode: ViewMode = .rich
    @Published var selectedID: UUID? {
        didSet { if selectedID != oldValue { isPreviewing = false } }
    }
    @Published var isPreviewing = false
    @Published var searchFocused = false
    @Published var showsShortcutHelp = false
    /// 面板顶部的一行提示（授权提醒、删除撤销等），几秒后自动消失
    @Published var hint: String?
    @Published var statusMessage: String?
    /// 菜单栏图标是否真的被系统摆上了菜单栏（nil = 还没核对）。
    /// macOS 26 上"创建成功"和"看得见"是两件事，所以这个状态得单独拿出来给设置页显示。
    @Published var menuBarItemPlaced: Bool?
    /// 辅助功能授权状态（实时）。设置页用它渲染状态行：
    /// 不用这个中间值的话，行内容只在窗口重开时重算，用户勾完授权回来
    /// 看到的还是"未授权"，会以为授权没生效（实测踩过）。
    @Published private(set) var accessibilityGranted = Paster.isAccessibilityTrusted

    let store: ClipStore
    let prefs: PreferencesStore
    let watcher: ClipboardWatcher

    // ── 反向操作回调（由 AppDelegate 装配）─────────────────────

    var onRequestHidePanel: (() -> Void)?
    var onRequestShowPanel: (() -> Void)?
    var onRequestShowSettings: (() -> Void)?
    /// 状态栏图标翻转
    var onCopyFeedback: (() -> Void)?
    /// 粘贴前把焦点还给"上一个外部应用"
    var onReactivatePreviousApp: (() -> Void)?
    /// 粘贴目标（上一个外部应用）。AppDelegate 把 panel.pasteTarget 接过来，
    /// 发 ⌘V 前用来确认焦点真的切回目标了。
    var pasteTargetProvider: (() -> NSRunningApplication?)?

    private var hintTask: DispatchWorkItem?
    private var undoStack: [[ClipItem]] = []
    private var accessibilityObserver: NSObjectProtocol?

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    // ── 生命周期 ─────────────────────────────────────────────

    /// prefs 用 optional 而不是 `= PreferencesStore()`：默认参数表达式在**调用方**
    /// 的隔离上下文里求值，而 PreferencesStore 是 @MainActor 的，编译期就不让过。
    /// 传 nil 时在 init 体里（主 isolate 上）再建，语义一样。
    init(store: ClipStore = ClipStore(), prefs: PreferencesStore? = nil) {
        self.store = store
        self.prefs = prefs ?? PreferencesStore()
        self.watcher = ClipboardWatcher(store: store)
    }

    func bootstrap() {
        store.load()
        store.enforceLimit(prefs.value.maxItems)
        refresh()
        viewMode = prefs.value.defaultView

        watcher.onCapture = { [weak self] item in
            self?.handleCapture(item)
        }
        watcher.start(interval: prefs.value.pollInterval,
                      ignoreConcealed: prefs.value.ignoreConcealed)

        prefs.didChange = { [weak self] old, new in
            self?.applyPreferences(from: old, to: new)
        }

        // TCC 在辅助功能清单变化时会发这个分布式通知。
        // 靠它把授权状态行实时点亮：用户切到系统设置勾完授权回来，
        // 不重开设置窗口也能立刻看到"已授权"。
        accessibilityObserver = DistributedNotificationCenter.default.addObserver(
            forName: Paster.accessibilityChangedNotice, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshAccessibilityStatus(announce: true)
            }
        }
        // 通知不是百分之百可靠（个别系统版本不发），设个 3 秒的兜底轮询。
        // 状态没变化时写 @Published 会因 Equatable 拦截而不触发重绘，成本可以忽略。
        let poll = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshAccessibilityStatus(announce: false)
            }
        }
        RunLoop.main.add(poll, forMode: .common)
    }

    /// 重新读一次授权状态；变了就更新（驱动设置页重绘）并给一句确认提示。
    func refreshAccessibilityStatus(announce: Bool) {
        let now = Paster.isAccessibilityTrusted
        guard now != accessibilityGranted else { return }
        accessibilityGranted = now
        if announce {
            showHint(now ? "辅助功能授权成功，回车 / 双击即可自动粘贴"
                         : "辅助功能授权已撤销，自动粘贴降级为手动 ⌘V",
                     seconds: 5)
        }
    }

    func shutdown() {
        if let accessibilityObserver {
            DistributedNotificationCenter.default.removeObserver(accessibilityObserver)
        }
        watcher.stop()
        store.save()
    }

    private func applyPreferences(from old: Preferences, to new: Preferences) {
        if old.pollInterval != new.pollInterval || old.ignoreConcealed != new.ignoreConcealed {
            watcher.updateInterval(new.pollInterval, ignoreConcealed: new.ignoreConcealed)
        }
        if old.shortcuts != new.shortcuts {
            registerGlobalHotKeys()
        }
        if old.hideDockIcon != new.hideDockIcon {
            DiagLog.append("Dock 策略：hideDockIcon=\(new.hideDockIcon)")
            NSApp.setActivationPolicy(new.hideDockIcon ? .accessory : .regular)
        }
        if old.launchAtLogin != new.launchAtLogin {
            DiagLog.append("launchAtLogin \(old.launchAtLogin)→\(new.launchAtLogin)")
            do {
                try LoginItem.setEnabled(new.launchAtLogin)
                DiagLog.append("LaunchAgent 写入 ✓ exists=\(LoginItem.isEnabled)")
            } catch {
                // 失败要留痕：开关弹回这类问题没日志只能瞎猜（用户实测踩过）
                DiagLog.append("LaunchAgent 写入 ✗：\(error)")
                statusMessage = error.localizedDescription
                // 写失败就把开关拨回去，别让界面显示一个没生效的状态
                prefs.value.launchAtLogin = LoginItem.isEnabled
            }
        }
        if old.maxItems != new.maxItems {
            store.enforceLimit(new.maxItems)
            store.save()
            refresh()
        }
        if old.categories != new.categories {
            objectWillChange.send()
        }
    }

    func registerGlobalHotKeys() {
        // 每次全量替换：改一个键位也要把旧的注销掉，否则 RegisterEventHotKey
        // 会因为"键位已被占用"失败。整批传进去，避免两次调用互相清空。
        let entries: [(spec: KeySpec, action: @MainActor () -> Void)] = [
            (prefs.value.spec(for: .recallPanel), { [weak self] in self?.onRequestShowPanel?() }),
            (prefs.value.spec(for: .openSettings), { [weak self] in self?.onRequestShowSettings?() }),
        ]
        let failed = HotKeyCenter.shared.replaceAll(with: entries)
        if let first = failed.first {
            statusMessage = "全局热键 \(first.display) 注册失败（可能被别的应用占用或与另一个动作重复），请在设置里换一个"
        } else {
            statusMessage = nil
        }
    }

    // ── 采集 ─────────────────────────────────────────────────

    private func handleCapture(_ item: ClipItem) {
        let outcome = store.insert(item, maxItems: prefs.value.maxItems)
        store.save()
        refresh()

        // 去重命中的也反馈：用户刚按了 ⌘C，本来就该有"收到了"的回应
        SoundFeedback.playCopyFeedback(enabled: prefs.value.playSound,
                                             soundName: prefs.value.feedbackSound)
        if prefs.value.animateStatusIcon { onCopyFeedback?() }
        _ = outcome

        // 面板开着的时候自动跳到最新那条吗？不跳。
        // 用户正在翻历史、挑一条要粘贴，这时候选择被抢走是最烦人的交互。
    }

    // ── 过滤 / 分区 ──────────────────────────────────────────

    /// 「收藏」分类的 id。它 1.0.14 起是内置分类，id 跨版本稳定
    /// （见 Category.favoritesID），直接用常量——按名字找会在用户
    /// 给内置分类改名后失效。只用于"清空数据时保留收藏条目"；
    /// 面板默认落在「全部」（用户指定）。
    var defaultCategoryID: UUID? {
        guard prefs.value.categories.contains(where: { $0.id == Category.favoritesID }) else { return nil }
        return Category.favoritesID
    }

    var filteredItems: [ClipItem] {
        let category = prefs.value.category(id: selectedCategoryID)
        let tokens = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: " ")
            .map(String.init)

        return items.filter { item in
            if let category {
                let hit = ContentClassifier.categoryIDs(for: item, in: [category]).contains(category.id)
                if !hit { return false }
            }
            guard !tokens.isEmpty else { return true }
            // 多个词是 AND：剪贴板搜索经常是"我记得里面有 A 和 B"
            let haystack = (item.searchableText + "\n" + (item.sourceAppName ?? "") + "\n" + item.kind.title).lowercased()
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }

    /// 列表分区：只有**搜索**时才给不分区的平铺列表（用户要的是搜索结果）；
    /// 只选了分类（比如默认落在「收藏」）时保持"已置顶 + 按天归档"——
    /// 收藏是常驻视图，没有日期分组就没法定位"那条是哪天存的"。
    var sections: [DisplaySection] {
        let visible = filteredItems
        let hasSearch = !query.trimmingCharacters(in: .whitespaces).isEmpty
        if hasSearch {
            return [DisplaySection(title: "", items: visible)]
        }

        var sections: [DisplaySection] = []
        let pinned = visible.filter(\.pinned)
        if !pinned.isEmpty {
            sections.append(DisplaySection(title: "已置顶", items: pinned))
        }
        let unpinned = visible.filter { !$0.pinned }
        var buckets: [String: [ClipItem]] = [:]
        var order: [String] = []
        for item in unpinned {
            let title = Support.dayTitle(item.createdAt)
            if buckets[title] == nil { order.append(title) }
            buckets[title, default: []].append(item)
        }
        for title in order {
            sections.append(DisplaySection(title: title, items: buckets[title] ?? []))
        }
        return sections
    }

    var flatVisibleItems: [ClipItem] { sections.flatMap(\.items) }

    var selectedItem: ClipItem? {
        guard let selectedID else { return nil }
        return items.first { $0.id == selectedID }
    }

    var selectedIndex: Int? {
        guard let selectedID else { return nil }
        return flatVisibleItems.firstIndex { $0.id == selectedID }
    }

    var countSummary: String {
        let visible = flatVisibleItems.count
        if query.isEmpty && selectedCategoryID == nil {
            return "共 \(visible) 项"
        }
        return "\(visible) / \(items.count) 项"
    }

    func ensureValidSelection() {
        let visible = flatVisibleItems
        if let selectedID, visible.contains(where: { $0.id == selectedID }) { return }
        selectedID = visible.first?.id
        isPreviewing = false
    }

    func refresh() {
        items = store.items
        if selectedID == nil || !items.contains(where: { $0.id == selectedID }) {
            ensureValidSelection()
        }
    }

    // ── 选择移动 ─────────────────────────────────────────────

    /// 键盘导航把选中项挪出可视区时，列表要滚一下跟过去；但鼠标点选
    /// 不需要——点中的那行本来就在光标底下，再 scrollTo(.center) 会把
    /// 列表抽走一截，紧跟着的第二下就点歪了（用户实测）。
    /// moveSelection 置位、视图的 onChange 消费并复位。
    var pendingScrollReveal = false

    func moveSelection(by offset: Int) {
        let visible = flatVisibleItems
        guard !visible.isEmpty else { selectedID = nil; return }
        guard let current = selectedIndex else { selectedID = visible[0].id; return }
        let next = min(max(current + offset, 0), visible.count - 1)
        pendingScrollReveal = true
        selectedID = visible[next].id
    }

    func selectFirst() {
        pendingScrollReveal = true
        selectedID = flatVisibleItems.first?.id
    }
    func selectLast() { selectedID = flatVisibleItems.last?.id }

    /// 网格视图里左右移动要按列跳；列数由视图算好后传进来。
    func moveSelectionHorizontally(by offset: Int, columns: Int) {
        moveSelection(by: offset * max(columns, 1))
    }

    // ── 条目操作 ─────────────────────────────────────────────

    func pasteSelected() {
        // 粘贴链路的诊断留痕：双击/回车不生效时，先看这条日志走到哪一步断的。
        // 写 /tmp 而不是 os_log：排查时一条 cat 就能看完，不用翻控制台。
        var trace: [String] = ["—— \(Date()) 双击/回车粘贴 ——"]
        defer { Self.appendTrace(trace.joined(separator: "\n") + "\n") }
        guard let item = selectedItem else {
            trace.append("✗ 没有选中条目")
            return
        }
        trace.append("条目：\(item.kind.rawValue) · \(String(item.text.prefix(20)))")
        let writeOK = Paster.write(item, store: store, watcher: watcher)
        trace.append("写回剪贴板：\(writeOK ? "✓" : "✗ 失败")")
        guard writeOK else {
            showHint("这条内容已经不在了（图片或文件可能被删掉）")
            return
        }
        store.bump(item.id)
        store.save()
        refresh()

        let wantedAutoPaste = prefs.value.autoPaste
        if wantedAutoPaste && !Paster.isAccessibilityTrusted {
            // 说清"已经复制好了、只差一步"，而不是关掉面板让用户对着屏幕发呆
            trace.append("✗ 未授权，降级为手动 ⌘V")
            showHint("已复制到剪贴板，按 ⌘V 粘贴（自动粘贴未授权，去设置里开）")
            return
        }
        onRequestHidePanel?()
        // 无论自不自动粘贴，都要把焦点还给上一个应用：
        // 不还的话用户接着按 ⌘V 会打在一个已经没有窗口的进程上，什么都没发生。
        onReactivatePreviousApp?()
        trace.append("面板已收起，焦点已还原")
        guard wantedAutoPaste else { return }
        sendPasteWhenFrontmost()
    }

    /// 往 /tmp 的诊断文件追加一行。文件不存在就建。
    private static func appendTrace(_ text: String) {
        let path = "/tmp/boxpaste-paste-debug.txt"
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// 等"上一个应用"真的回到最前面再发 ⌘V。
    /// 固定延迟是在赌焦点切换能在窗口期内完成——1.0.10 的日志显示
    /// ⌘V 每次都"已发出"但用户那边什么都没粘上，大概率打在了
    /// 还没切走焦点的自己（或半路插进来的 Finder）身上。
    /// 轮询比对 pid：不对就再催一次 activate，最多等 ~1.2s；
    /// 发键时把目标/实际最前台都记进日志，再失败日志直接给出真凶。
    private func sendPasteWhenFrontmost(attempt: Int = 0) {
        let front = NSWorkspace.shared.frontmostApplication
        let target = pasteTargetProvider?()
        // 没记到目标（比如面板从我们自己的设置窗口呼出）就退化为"不是自己"
        let reached: Bool
        if let target {
            reached = front?.processIdentifier == target.processIdentifier
        } else {
            reached = front?.bundleIdentifier != Bundle.main.bundleIdentifier
        }
        if reached || attempt >= 24 {
            let sent = Paster.sendPasteKeystroke()
            Self.appendTrace("模拟 ⌘V：\(sent ? "✓ 已发出" : "✗ 发送失败")"
                + " · 目标=\(target?.localizedName ?? "未记录")"
                + " · 实际最前面=\(front?.localizedName ?? "nil")"
                + " · 等了 \(attempt) 轮\n")
            return
        }
        // 焦点还没到位：activate 是异步的，每 4 轮（0.2s）重新催一次，
        // 防止上一次激活请求丢了。
        if attempt % 4 == 3 { onReactivatePreviousApp?() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.sendPasteWhenFrontmost(attempt: attempt + 1)
        }
    }

    /// 图片 OCR → 剪贴板（右键菜单，仅图片条目）。
    /// 全程后台：全分辨率解码 + Vision 识别都是秒级操作，主线程碰不得。
    func ocrToClipboard(_ item: ClipItem) {
        guard item.kind == .image, let url = store.imageURL(for: item) else { return }
        showHint("正在识别文字…", seconds: 10)
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let cgImage = ImageTools.fullCGImage(at: url) else {
                await MainActor.run { self?.showHint("图片文件已不存在") }
                return
            }
            let text = (try? await OCRService.recognizeText(in: cgImage)) ?? ""
            await MainActor.run {
                guard let self else { return }
                if text.isEmpty {
                    self.showHint("没识别出文字")
                    return
                }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                // 故意不 ignore 这次剪贴板变化：OCR 出来的文字就该像普通复制一样
                // 作为一条文本进历史列表（用户反馈过"应用里怎么没有这段文字"），
                // 监听器下一轮轮询会自然把它收进来。
                self.showHint("已识别 \(text.count) 字，进了剪贴板和列表")
            }
        }
    }

    func copySelectedToList() {
        guard let item = selectedItem else { return }
        guard Paster.write(item, store: store, watcher: watcher) else {
            showHint("这条内容已经不在了")
            return
        }
        store.bump(item.id)
        store.save()
        refresh()
        SoundFeedback.playCopyFeedback(enabled: prefs.value.playSound,
                                             soundName: prefs.value.feedbackSound)
        showHint("已复制到剪贴板")
    }

    func togglePinSelected() {
        guard let item = selectedItem else { return }
        let pinned = store.togglePin(item.id)
        store.save()
        refresh()
        showHint(pinned ? "已置顶" : "已取消置顶")
    }

    func deleteSelected() {
        guard let item = selectedItem else { return }
        let removed = store.remove(ids: [item.id])
        store.save()
        undoStack.append(removed)
        if undoStack.count > 20 { undoStack.removeFirst() }
        refresh()
        ensureValidSelection()
        showHint("已删除（⌘Z 撤销）")
    }

    func undoLastDelete() {
        guard let last = undoStack.popLast(), !last.isEmpty else { return }
        store.restore(last)
        store.save()
        refresh()
        showHint("已恢复 \(last.count) 项")
    }

    func clearHistory(keepPinned: Bool) {
        // 「收藏」里的条目是用户手动挑出来的心血，清空时永远保留——
        // 两个清空按钮都保留（用户指定）。置顶是否保留由 keepPinned 决定。
        var keep = Set<UUID>()
        if keepPinned {
            keep.formUnion(items.filter(\.pinned).map(\.id))
        }
        if let fav = defaultCategoryID {
            for item in items where
                ContentClassifier.categoryIDs(for: item, in: prefs.value.categories).contains(fav) {
                keep.insert(item.id)
            }
        }
        store.clearAll(keeping: keep)
        store.save()
        refresh()
        ensureValidSelection()
        showHint(keepPinned ? "已清空（置顶与收藏保留）" : "已清空（收藏保留）")
    }

    // ── 视图 / 分类 ──────────────────────────────────────────

    func setViewMode(_ mode: ViewMode) {
        viewMode = mode
        prefs.value.defaultView = mode
    }

    func cycleCategory(forward: Bool) {
        var options: [UUID?] = [nil]
        options.append(contentsOf: prefs.value.categories.map { Optional($0.id) })
        guard let current = options.firstIndex(where: { $0 == selectedCategoryID }) else { return }
        let next = (current + (forward ? 1 : options.count - 1)) % options.count
        selectedCategoryID = options[next]
    }

    func categoryCount(_ category: Category) -> Int {
        items.reduce(0) { partial, item in
            partial + (ContentClassifier.categoryIDs(for: item, in: [category]).contains(category.id) ? 1 : 0)
        }
    }

    /// 分类排序：面板顶部的分类标签、Tab 轮换、右键「移到分类」都读同一个数组，
    /// 所以顺序只维护这一处就够了。真正的挪动逻辑是 Category.moving（纯函数，有自检）。
    func moveCategory(id: UUID, by offset: Int) {
        guard let moved = Category.moving(prefs.value.categories, id: id, by: offset) else { return }
        prefs.value.categories = moved
    }

    func canMoveCategory(id: UUID, by offset: Int) -> Bool {
        Category.moving(prefs.value.categories, id: id, by: offset) != nil
    }

    /// 面板置顶：开着的时候失焦也不收起（见 PanelController.windowDidResignKey）。
    func toggleAlwaysOnTop() {
        prefs.value.alwaysOnTop.toggle()
        showHint(prefs.value.alwaysOnTop ? "面板已置顶：点别处不会自动收起" : "已取消置顶")
    }

    // ── 导入导出 ─────────────────────────────────────────────

    func exportHistory() {
        let panel = NSSavePanel()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        panel.nameFieldStringValue = "BoxPaste-\(formatter.string(from: Date())).json"
        panel.allowedContentTypes = [.json]
        panel.title = "导出剪贴板历史"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try store.exportData(appVersion: appVersion)
            try data.write(to: url, options: .atomic)
            statusMessage = "已导出 \(items.count) 项到 \(url.lastPathComponent)"
        } catch {
            statusMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    func importHistory() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.title = "导入剪贴板历史"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let added = try store.importData(data)
            store.enforceLimit(prefs.value.maxItems)
            store.save()
            refresh()
            statusMessage = added > 0 ? "已导入 \(added) 项（重复内容已跳过）" : "没有新内容可导入"
        } catch {
            statusMessage = "导入失败：\(error.localizedDescription)"
        }
    }

    // ── 拖入收集 ─────────────────────────────────────────────

    /// 拖进面板的内容也进历史。走的是和剪贴板监听同一套 hash 与构造逻辑，
    /// 所以"拖进来的"和"复制进来的"同一条内容会被正确合并成一条。
    func collect(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let item = ClipboardWatcher.textItem(text)
        store.insert(item, maxItems: prefs.value.maxItems)
        store.save()
        refresh()
        showHint("已加入历史")
    }

    func collect(files: [URL]) {
        guard !files.isEmpty else { return }
        let item = ClipboardWatcher.fileItem(files)
        store.insert(item, maxItems: prefs.value.maxItems)
        store.save()
        refresh()
        showHint("已加入 \(files.count) 个文件")
    }

    func collect(imageData: Data) {
        // 拖进来的图可能是 TIFF/HEIC，统一转成 PNG 再存：
        // 后面预览、导出、写回剪贴板都按"blob 是 PNG"这个前提写，别处就不用再判格式。
        let png: Data?
        if let rep = NSBitmapImageRep(data: imageData) {
            png = rep.representation(using: .png, properties: [:])
        } else {
            png = nil
        }
        guard let png, let item = ClipboardWatcher.imageItem(png: png, store: store) else {
            showHint("这张图片无法识别")
            return
        }
        store.insert(item, maxItems: prefs.value.maxItems)
        store.save()
        refresh()
        showHint("已加入历史")
    }

    // ── 网格列数（供键盘左右移动用）───────────────────────────

    @Published var gridColumns: Int = 3

    func updateGridColumns(_ count: Int) {
        let clamped = max(1, count)
        if clamped != gridColumns { gridColumns = clamped }
    }

    // ── 提示 ─────────────────────────────────────────────────

    func showHint(_ text: String, seconds: Double = 2.6) {
        hint = text
        hintTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.hint == text { self.hint = nil }
        }
        hintTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: task)
    }
}
