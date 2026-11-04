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
