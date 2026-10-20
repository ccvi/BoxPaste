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

        let model = AppModel()
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

        if CommandLine.arguments.contains("--show-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showSettings()
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
            settingsWindow = SettingsWindowController(model: model)
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
