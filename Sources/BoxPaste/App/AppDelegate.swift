import AppKit
import Foundation

// ============================================================
// 应用装配
//
// 全程序只有这里把"状态中枢"和"三个界面控制器"接起来。
// 用回调而不是互相持有：AppModel ↔ 窗口控制器 互相强引用会成环，
// 而且会让"模型能不能关窗口"这种问题变得含糊。
// ============================================================

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var model: AppModel!
    private var statusItem: StatusItemController!
    private var panel: PanelController!
    private var settingsWindow: SettingsWindowController?
    /// 面板重建耗时采样（--measure-reopen）：构建 / 上屏 / 到帧
    private var reopenSamples: [(build: Double, show: Double, frame: Double)] = []
    private var reopenRounds = 0
    private let reopenRoundTarget = 6
    /// 自动重启：检查定时器与跨进程的计数状态
    private var autoRestartTimer: Timer?
    private var autoRestartState = AutoRestartState()
    /// 上次记录的「到线却没重启」原因，避免每 5 秒写一行同样的日志
    private var lastAutoRestartSkip = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 换 bundle id 之后第一次启动：把旧 id 的偏好搬过来。
        // 必须在 AppModel（读偏好）之前做，否则用户会看到一次出厂设置。
        AppIdentity.migrateLegacyDefaultsIfNeeded()

        // 诊断用：--store-root <目录> 让这次运行读写一个临时仓库，
        // --seed-heavy 先往里塞大文本/富文本/大图（见 PerfFixtures）。
        // 正常启动两个参数都没有，行为完全不变。
        let diagnosticRoot: URL? = {
            guard let index = CommandLine.arguments.firstIndex(of: "--store-root"),
                  CommandLine.arguments.count > index + 1 else { return nil }
            let root = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            if CommandLine.arguments.contains("--seed-heavy") {
                PerfFixtures.seed(into: root)
            }
            return root
        }()

        let model = diagnosticRoot.map { AppModel(store: ClipStore(root: $0)) } ?? AppModel()
        self.model = model

        // 单实例锁必须在任何写盘动作之前拿到：自动重启靠「旧进程退出 → helper 拉起
        // 新进程」，重叠的那几百毫秒里两个实例会同时写同一份 history.json。
        // 诊断实例（--store-root）各自用独立目录，锁也各自独立，互不干扰。
        guard SingleInstanceLock.acquire(in: model.store.root) else {
            FileHandle.standardError.write(Data("已有实例在使用 \(model.store.root.path)，本次启动退出\n".utf8))
            exit(0)
        }
        // 自动重启的计数要跨进程存活；用户手动打开则全部归零（他指定的规则）
        autoRestartState = AutoRestartStore.settleOnLaunch(in: model.store.root)

        // Dock 策略要在任何窗口出现之前定：先建窗口再切身份，
        // 窗口会带着旧身份的属性（比如不会出现在 ⌘Tab 里）活到下一次切换。
        NSApp.setActivationPolicy(model.prefs.value.hideDockIcon ? .accessory : .regular)

        // LSUIElement 应用没有系统菜单栏，设置页里的文本框就按不出 ⌘C/⌘V。
        // 这一份最小主菜单就是为它准备的，别删。
        buildMainMenu()

        let panel = PanelController(model: model)
        let statusItem = StatusItemController(model: model)
        self.panel = panel
        self.statusItem = statusItem
        statusItem.install()

        model.onRequestShowPanel = { [weak self] in self?.panel.toggle() }
        model.onRequestHidePanel = { [weak self] in self?.panel.hide() }
        model.onRequestShowSettings = { [weak self] in self?.showSettings() }
        model.onCopyFeedback = { [weak self] in self?.statusItem.flip() }
        model.onIconStateChanged = { [weak self] in self?.statusItem.refreshIcon() }
        model.onReactivatePreviousApp = { [weak self] in self?.panel.reactivatePreviousApp() }
        model.pasteTargetProvider = { [weak self] in self?.panel.pasteTarget }

        model.bootstrap()
        model.registerGlobalHotKeys()
        startAutoRestartMonitor()

        // 图标是否真的被摆上了菜单栏，得等系统排完版才知道（见 StatusItemController）。
        // macOS 26 上"创建成功"和"看得见"是两件事，这一步是为了不让图标静悄悄不存在。
        statusItem.verifyPlacement()

        // 没有 Dock 图标时，用户是靠菜单栏图标知道"它活着"的。
        // 启动时翻一下，比任何提示都直接。
        if model.prefs.value.animateStatusIcon {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.statusItem.flip()
            }
        }

        // 诊断入口：带 --show-panel 启动时直接把面板呼出来。
        // 用途是"看一眼界面到底长什么样"（截图核对、排查布局问题），
        // 正常双击启动不会走这里。
        if CommandLine.arguments.contains("--diagnose-status") {
            // 打完就退的话没法对着那个坐标去截图核对，所以先多活一会儿
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.statusItem.dumpDiagnostics()
                if CommandLine.arguments.contains("--keep-alive") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { exit(0) }
                } else {
                    exit(0)
                }
            }
        }

        if CommandLine.arguments.contains("--preview-memory") {
            // 预览内存诊断：逐条打开/关闭预览，每步打一次 footprint。
            // 用途是回答"按空格预览之后内存为什么涨上去就不降"这类问题——
            // 外部 footprint 命令要额外权限，只能从进程内部量。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.runPreviewMemoryDiagnostic()
            }
        }

        if CommandLine.arguments.contains("--show-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showSettings()
                // 挪到屏幕左上：截图核对排版时中部容易被别的窗口盖住
                self?.settingsWindow?.moveForDiagnostics()
            }
        }

        if CommandLine.arguments.contains("--measure-reopen") {
            // 面板视图树「拆掉 → 重建」的耗时测量。
            // 结论决定要不要做"面板隐藏久了就自动拆"：拆能省 ~79MB 视图图，
            // 但如果每次呼出要多等 100ms，这个交换就不划算。
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.runReopenMeasurement()
            }
        }

        if CommandLine.arguments.contains("--settings-close-test") {
            // 「关窗即拆」的验证入口：开窗 → 量 → 关窗 → 再量。
            // 为什么必须有这个：`contentView = nil` 之后视图树到底有没有被释放，
            // 光看代码不算数（NSHostingView 可能被别处持有）。外部 heap 只能
            // 看到进程总量，分不清是设置窗还是列表；这里把两个时点钉死。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                self.showSettings()
                // 留足采样窗口：外部要在这两段里各抓一次 heap
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                    print(String(format: "OPENED %.1f MB · 控制器%@",
                                 Support.physFootprintMB,
                                 self.settingsWindow == nil ? "缺失" : "已持有"))
                    self.settingsWindow?.close()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                        print(String(format: "CLOSED %.1f MB · 控制器%@",
                                     Support.physFootprintMB,
                                     self.settingsWindow == nil ? "已释放" : "仍持有"))
                        exit(0)
                    }
                }
            }
        }

        if CommandLine.arguments.contains("--measure-teardown") {
            // 滚完整个列表再拆视图树，量"拆掉到底能回收多少"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.runTeardownMeasurement()
            }
        }

        // 批量粘贴的端到端验证：--batch-paste-test[=N] 或 /tmp 下的触发文件。
        // 为什么要触发文件：`open -a X.app --args --flag` 实测**不传参**，
        // 而 .app 内的二进制又不许直接 exec（见 build-app.sh 的自检说明），
        // 于是只剩"启动后读一个标记文件"这条路。
        // 为什么需要这个验证：这条链路唯一致命的未知是**节奏**（间隔太短目标应用
        // 会丢条目），而节奏只有真的往一个文档里粘一次才看得出来。
        // 结果写 /tmp：经 open 启动时拿不到 stdout。
        let triggerPath = "/tmp/boxpaste-batch-test.trigger"
        let wantsBatchTest = CommandLine.arguments.contains { $0.hasPrefix("--batch-paste-test") }
            || FileManager.default.fileExists(atPath: triggerPath)
        if wantsBatchTest {
            // 触发文件内容：`3` 或 `3:12345`（条数:目标应用 pid）。
            // 为什么必须能指定 pid：`open -a` 会把前台交给**我们自己**，
            // 不指目标的话 ⌘V 全打在自己身上，接收端一个字都收不到 —— 会假通过。
            var count = 3
            var targetPID: pid_t?
            func parseSpec(_ spec: String) {
                let parts = spec.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
                if let first = parts.first, let parsed = Int(first) { count = parsed }
                if parts.count > 1, let pid = Int32(parts[1]) { targetPID = pid }
            }
            if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--batch-paste-test") }),
               let value = arg.split(separator: "=").dropFirst().first {
                parseSpec(String(value))
            } else if let text = try? String(contentsOfFile: triggerPath, encoding: .utf8) {
                parseSpec(text)
            }
            try? FileManager.default.removeItem(atPath: triggerPath)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self else { return }
                // 面板没显示过时 refresh() 只记脏不发布 items（省得给隐藏窗口重算列表），
                // 所以这里要先把脏数据落地，否则取到的永远是空列表
                self.model.panelDidShow()
                // 跳掉置顶：它们是常驻的固定块，会把可预期的 3 条挤出取样范围
                let picks = Array(self.model.flatVisibleItems.filter { !$0.pinned }.prefix(count))
                var log = ["[\(Date())] 批量粘贴验证 条数=\(count) 辅助功能=\(Paster.isAccessibilityTrusted)"]
                log.append("取件：" + picks.map { String($0.text.prefix(12)).replacingOccurrences(of: "\n", with: "⏎") }
                    .joined(separator: " | "))
                let expect = Double(picks.count) * 0.25 + 3
                // 把目标应用钉死并推到前台：正常使用时这一步由 panel.previousApp 完成
                if let targetPID, let external = NSRunningApplication(processIdentifier: targetPID) {
                    self.model.pasteTargetProvider = { external }
                    external.activate()
                    log.append("目标：\(external.localizedName ?? "?") pid=\(targetPID)")
                }
                self.model.multiSelection = Set(picks.map(\.id))
                self.model.pasteMultiSelection()
                DispatchQueue.main.asyncAfter(deadline: .now() + expect) {
                    log.append("结束")
                    try? log.joined(separator: "\n").write(toFile: "/tmp/boxpaste-batch-test.log",
                                                           atomically: true, encoding: .utf8)
                    print(log.joined(separator: "\n"))
                    exit(0)
                }
            }
        }

        if CommandLine.arguments.contains("--show-panel") || CommandLine.arguments.contains("--show-preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                self.model.onRequestShowPanel?()
                // --show-preview 额外把空格预览层也打开，用来核对预览的渲染
                if CommandLine.arguments.contains("--show-preview") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.model.isPreviewing = true
                    }
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
    }

    // ── 自动重启（内存回收）──────────────────────────────────

    /// 每 5 秒看一次：内存到线、用户静下来了、冷却也过了，就重开一次自己。
    ///
    /// 为什么用轮询而不是系统内存压力通知：用户要的是**绝对阈值**（250MB），
    /// 而 memory pressure 是系统视角（全机紧张），两者根本不是一回事。
    private func startAutoRestartMonitor() {
        autoRestartTimer?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluateAutoRestart() }
        }
        // .common：拖窗口、弹菜单时默认模式会暂停定时器
        RunLoop.main.add(timer, forMode: .common)
        autoRestartTimer = timer
    }

    private func evaluateAutoRestart() {
        // 设置里的开关关了就整个不碰（定时器空转的开销是零）
        guard model.prefs.value.autoRestartEnabled else { return }
        // 用户正在看的东西不能被抽走（面板 / 预览 / 设置任一个开着都不动）
        guard !model.isPanelVisible else { return }
        guard !model.isPreviewing else { return }
        guard settingsWindow?.isVisible != true else { return }

        let now = Date()
        let tuning = autoRestartTuning
        let decision = AutoRestartPolicy.decide(
            footprintMB: Support.physFootprintMB,
            idleFor: now.timeIntervalSince(model.lastActivityAt),
            state: autoRestartState,
            now: now,
            thresholdMB: tuning.threshold,
            idleSeconds: tuning.idle,
            cooldownSeconds: tuning.cooldown)

        switch decision {
        case .restart:
            performAutoRestart(now: now)
        case .skip(let reason):
            // 内存都没到线就别记（否则每 5 秒刷一行）；到线了但没重启的原因要留痕，
            // 不然用户问"为什么没生效"只能靠猜。
            guard Support.physFootprintMB >= tuning.threshold,
                  reason != lastAutoRestartSkip else { return }
            lastAutoRestartSkip = reason
            DiagLog.append("自动重启跳过：\(reason)")
        }
    }

    /// 端到端验证用的门槛覆盖。
    ///
    /// 为什么要有：正式门槛（250MB / 30 秒 / 30 分钟冷却）要挂几小时才可能满足，
    /// 没法验证「触发 → 落盘 → 退出 → helper 拉起 → 继承计数」这条链路。
    /// 存在 `/tmp/boxpaste-autorestart-test.trigger` 时把三项都调小；
    /// **正式使用没有这个文件，一切按用户定的规则走**。
    private var autoRestartTuning: (threshold: Double, idle: TimeInterval, cooldown: TimeInterval) {
        let marker = "/tmp/boxpaste-autorestart-test.trigger"
        guard FileManager.default.fileExists(atPath: marker) else {
            return (AutoRestartPolicy.thresholdMB,
                    AutoRestartPolicy.idleSeconds,
                    AutoRestartPolicy.cooldownSeconds)
        }
        return (5, 3, 5)
    }

    private func performAutoRestart(now: Date) {
        // 只有装在 /Applications 的正式版才重开自己：诊断实例是 .build 裸产物，
        // 重开它会变成"打开另一个 app"，而且它的数据目录本来就不是同一个。
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else {
            DiagLog.append("自动重启：非安装版，跳过")
            lastAutoRestartSkip = "非安装版"
            return
        }

        // 先把数据落干净：退出进程会丢掉内存里还没写下去的东西
        model.store.save()
        ClipboardWatcher.flushPendingBlobWrites()

        let next = AutoRestartPolicy.advanced(autoRestartState, now: now)

        // helper 起得来才退出。起不来就退出 = 应用彻底消失，比多占几十 MB 严重得多。
        guard Relauncher.schedule() else {
            lastAutoRestartSkip = "helper 启动失败"
            return
        }

        var pending = next
        pending.pending = true   // 让下一次启动「继承计数」而不是当成手动打开清零
        AutoRestartStore.write(pending, in: model.store.root)
        autoRestartState = next
        autoRestartTimer?.invalidate()
        autoRestartTimer = nil

        DiagLog.append(String(format: "自动重启：footprint %.0fMB，24h 窗口内第 %d 次",
                              Support.physFootprintMB, next.count))
        NSApp.terminate(nil)
    }

    // ── 诊断：面板视图树的重建耗时 ───────────────────────────

    /// 反复「拆掉 → 呼出」若干轮，分别记录三段耗时：
    ///   build = 建 NSHostingView + 绑定 environmentObject
    ///   show  = 加上定位 / 选中校正 / makeKeyAndOrderFront
    ///   frame = 到下一轮 runloop（Core Animation 提交这一帧，用户真正"看到"）
    ///
    /// 第一轮含一次性成本（字体、TextKit 排版机器之类）单独看；能不能做自动回收
    /// 要看**热态**（第 2 轮起）的均值——用户平时呼出面板就是热态。
    private func runReopenMeasurement() {
        // 先拆掉，保证第一轮走的是重建路径（和"隐藏久了被拆过"完全一致）
        panel.teardownContent()
        reopenSamples = []
        reopenRounds = 0

        panel.onRebuildTiming = { [weak self] build, show, frame in
            guard let self else { return }
            self.reopenSamples.append((build: build, show: show, frame: frame))
            self.reopenRounds += 1

            // 收起再拆，进入下一轮。中间留 200ms，别让上一帧的 CA 提交串进来。
            self.panel.hide()
            self.panel.teardownContent()
            if self.reopenRounds >= self.reopenRoundTarget {
                self.finishReopenMeasurement()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.panel.show()
                }
            }
        }
        panel.show()
    }

    private func finishReopenMeasurement() {
        var lines = ["── BoxPaste 面板重建耗时（\(reopenSamples.count) 轮）──", ""]
        for (index, sample) in reopenSamples.enumerated() {
            lines.append(String(format: "第 %d 轮：构建 %.1f ms · 上屏 %.1f ms · 到帧 %.1f ms",
                                index + 1, sample.build, sample.show, sample.frame))
        }
        let warm = reopenSamples.dropFirst()
        if !warm.isEmpty {
            let avgFrame = warm.map(\.frame).reduce(0, +) / Double(warm.count)
            let fastest = warm.map(\.frame).min() ?? 0
            let avgBuild = warm.map(\.build).reduce(0, +) / Double(warm.count)
            lines.append("")
            lines.append(String(format: "热态（第 2 轮起 %d 轮）：构建均值 %.1f ms · 到帧均值 %.1f ms · 最快 %.1f ms",
                                warm.count, avgBuild, avgFrame, fastest))
        }
        lines.append(String(format: "当前 footprint %.1f MB", Support.physFootprintMB))
        let text = lines.joined(separator: "\n")
        try? text.write(toFile: "/tmp/boxpaste-reopen.txt", atomically: true, encoding: .utf8)
        print(text)
        exit(0)
    }

    // ── 诊断：面板视图树的回收量 ─────────────────────────────

    /// 把列表从头滚到尾（LazyVStack 会把经过的行都建出来并留着），
    /// 然后拆掉视图树，量回收了多少。
    ///
    /// 为什么必须真滚：一开始怀疑 "216MB 里 78.8MB 视图图" 是因为用户滚过整个列表，
    /// 只有复现"滚过"这个状态，拆掉的收益才是真的。
    private var teardownDiagLines: [String] = []
    private var teardownDiagScrolled = 0

    private func runTeardownMeasurement() {
        teardownDiagLines = ["── BoxPaste 面板视图树回收测量 ──"]
        let start = Support.physFootprintMB
        model.onRequestShowPanel?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.teardownDiagLines.append(String(format: "启动 %.1f MB → 呼出后面板 %.1f MB（可见 %d 条）",
                                                 start, Support.physFootprintMB,
                                                 self.model.flatVisibleItems.count))
            self.teardownDiagScrolled = 0
            self.scrollThroughAllItems()
        }
    }

    private func scrollThroughAllItems() {
        // 每次挪 20 条，21 次覆盖 402 条；到底之后就进入收尾
        let total = model.flatVisibleItems.count
        guard teardownDiagScrolled < 24, total > 0 else {
            finishTeardownMeasurement()
            return
        }
        model.moveSelection(by: 20)
        teardownDiagScrolled += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.scrollThroughAllItems()
        }
    }

    private func finishTeardownMeasurement() {
        let scrolled = Support.physFootprintMB
        teardownDiagLines.append(String(format: "滚完整个列表：%.1f MB", scrolled))
        panel.teardownContent()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            let after = Support.physFootprintMB
            self.teardownDiagLines.append(String(format: "拆掉视图树：%.1f MB（回收 %.1f MB）",
                                                 after, scrolled - after))
            let text = self.teardownDiagLines.joined(separator: "\n")
            try? text.write(toFile: "/tmp/boxpaste-teardown.txt", atomically: true, encoding: .utf8)
            print(text)
            exit(0)
        }
    }



    // ── 诊断：预览的内存开销 ─────────────────────────────────

    /// 逐条预览 → 收起，各打一次 footprint，结果写 /tmp。
    /// 关键是要区分「预览期间暂住」和「关掉后不归还」——后者才是要修的。
    private var previewDiagQueue: [ClipItem] = []
    private var previewDiagLines: [String] = []

    private func runPreviewMemoryDiagnostic() {
        previewDiagLines = ["── BoxPaste 预览内存诊断 ──"]
        model.onRequestShowPanel?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.recordFootprint("面板已打开（含首次布局）")
                self.previewDiagQueue = Array(self.model.flatVisibleItems.prefix(20))
                self.previewDiagStep()
            }
        }
    }

    private func recordFootprint(_ label: String) {
        previewDiagLines.append(String(format: "%@：%.1f MB", label, Support.physFootprintMB))
        flushPreviewDiag()
    }

    /// 逐步落盘：预览大内容时进程可能被系统直接杀掉（jetsam），
    /// 只在最后写文件的话会一条数据都留不下。
    private func flushPreviewDiag() {
        try? (previewDiagLines.joined(separator: "\n") + "\n")
            .write(toFile: "/tmp/boxpaste-preview-memory.txt", atomically: true, encoding: .utf8)
    }

    private func previewDiagStep() {
        guard let item = previewDiagQueue.first else {
            recordFootprint("全部预览结束（预览均已关闭）")
            // 顺手记一笔：malloc_zone_pressure_relief 在这代系统上是不是真的能还页。
            // macOS 26 实测恒返回 0（xzone 分配器不让空闲页还给内核），留着当哨兵，
            // 哪天系统改了行为这里会立刻看见。
            let released = malloc_zone_pressure_relief(nil, 0)
            previewDiagLines.append(String(format: "relief 探针：malloc 报告归还 %.2f MB → %.1f MB",
                                           Double(released) / 1_000_000, Support.physFootprintMB))
            flushPreviewDiag()
            exit(0)
        }
        previewDiagQueue.removeFirst()
        model.selectedID = item.id
        let before = Support.physFootprintMB
        model.isPreviewing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let during = Support.physFootprintMB
                self.model.isPreviewing = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    MainActor.assumeIsolated {
                        let after = Support.physFootprintMB
                        self.previewDiagLines.append(String(format:
                            "  %@ · %d B · 预览前 %.1f → 预览中 %.1f（+%.1f）→ 关闭后 %.1f（残留 +%.1f）",
                            item.kind.title, item.byteCount,
                            before, during, during - before, after, after - before))
                        self.flushPreviewDiag()
                        self.previewDiagStep()
                    }
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false   // 关掉设置窗口不等于退出：这是个常驻工具
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 从 Dock / 访达再点一次图标，视为"我要用面板"
        model?.onRequestShowPanel?()
        return true
    }

    // ── 设置窗口 ─────────────────────────────────────────────

    @objc private func showSettings() {
        if settingsWindow == nil {
            let controller = SettingsWindowController(model: model)
            // 关窗后放掉控制器：设置页的视图树常驻要 17MB（实测），
            // 而它并非常驻界面。下次点"设置"重建一个新的即可。
            controller.onClose = { [weak self] in self?.settingsWindow = nil }
            settingsWindow = controller
        }
        settingsWindow?.show()
    }

    // ── 主菜单 ───────────────────────────────────────────────

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        // 应用菜单
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 BoxPaste",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 BoxPaste", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 BoxPaste", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // 编辑菜单：没有它，设置页的文本框就没有 ⌘C/⌘V/⌘A。
        // 这些 Selector 走响应链（nil target），所以谁在编辑谁处理。
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: Selector(("selectAll:")), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // 窗口菜单
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }
}
