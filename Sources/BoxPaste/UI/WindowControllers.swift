import AppKit
import Carbon.HIToolbox
import SwiftUI

// ============================================================
// 窗口与状态栏控制器
//   · StatusItemController —— 菜单栏图标（代码绘制 + 翻转动画 + 右键菜单）
//   · PanelWindow / PanelController —— 呼出面板、定位、键盘路由、失焦收起
//   · SettingsWindowController —— 设置窗口
//
// 键盘路由集中放在 PanelController.handle(event:)，因为它是唯一
// 能同时看到"面板是否 key"和"事件属于哪个窗口"的地方。
// ============================================================

extension NSApplication {
    /// macOS 14 起 activate(ignoringOtherApps:) 被弃用，改用 activate()；
    /// 低版本上仍要那个参数才有效。这里包一层，别处就不用各写一遍 if #available。
    func bringForward() {
        if #available(macOS 14.0, *) {
            activate()
        } else {
            activate(ignoringOtherApps: true)
        }
    }
}

// ── 菜单栏图标 ───────────────────────────────────────────────

@MainActor
final class StatusItemController: NSObject {

    private let model: AppModel
    private let statusItem: NSStatusItem
    private var frames: [NSImage] = []
    private var animationTimer: Timer?
    private var animationStep = 0
    private lazy var menu = buildMenu()

    /// 翻转帧数：12 帧 / 0.48 秒 ≈ 25 fps，翻一整圈够顺又不至于太花。
    private let frameCount = 12

    /// 「系统设置 → 菜单栏」那一页的锚点。
    /// macOS 26 起第三方菜单栏项的开关收在这里，应用侧没有任何 API 能代改，
    /// 所以只能把用户送过去（这是我们踩了整整一轮才确认的事）。
    static let menuBarSettingsURL =
        "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension"

    /// 图标到底有没有被摆到菜单栏上。
    /// 26 上第三方状态栏项由 ControlCenter 统一排版，没被收下的项会停在屏幕外的
    /// 默认位置（y 为负、高度 22），而 `isVisible` 依然是 true —— 只看属性查不出来，
    /// 只能看窗口几何：落位正常时 y 在屏幕顶部、高度约 33/34。
    var isPlacedInMenuBar: Bool {
        guard let frame = statusItem.button?.window?.frame else { return false }
        return frame.origin.y >= 0 && frame.height > 24
    }

    /// 装好之后核对一次，没落位就明确告诉用户——而不是让图标静悄悄地不存在。
    ///
    /// 文案刻意不把「去系统设置打开」当成唯一答案：现在已知的另一种成因是
    /// bundle id 的状态栏登记被烧坏（机制见 AppIdentity 头注释），那种情况
    /// 只能换 id，指路系统设置只会让用户白点一趟。
    func verifyPlacement(after delay: Double = 1.5) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let placed = self.isPlacedInMenuBar
            self.model.menuBarItemPlaced = placed
            if !placed {
                self.model.statusMessage =
                    "菜单栏图标没有被排进菜单栏。可先退出 BoxPaste 再重新打开一次；"
                    + "若仍不行，检查「系统设置 → 菜单栏」里 BoxPaste 的开关是否打开。"
                self.model.showHint("菜单栏图标没显示？重启一次 BoxPaste 试试", seconds: 6)
            }
        }
    }

    init(model: AppModel) {
        self.model = model
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
    }

    func install() {
        guard let button = statusItem.button else { return }
        // 二分用开关：「窗口没上屏」和「图标画不出来」在外部看一模一样，
        // 一个是空窗口、一个是画了空图，只有换成纯文字才能一次分开。
        if CommandLine.arguments.contains("--status-title") {
            button.title = "BP"
            button.imagePosition = .noImage
        } else {
            refreshIcon()
            button.imagePosition = .imageOnly
        }
        button.target = self
        button.action = #selector(handleClick(_:))
        // 左右键都要收：左键开关面板，右键出菜单
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "BoxPaste —— 剪贴板历史（\(model.prefs.value.spec(for: .recallPanel).display)）"

        // 这里曾经设置过 `autosaveName = "BoxPaste"` 和 `behavior = [.removalAllowed]`，
        // 依据是「不设 autosaveName 系统就叫 Item-0、多应用撞名导致排不进菜单栏」。
        // 那个理论后来被对照实验推翻：本机菜单栏上所有第三方项在窗口服务器里
        // 都叫 Item-0，照样共存；真正的成因是 bundle id 的登记被烧坏
        // （见 AppIdentity 头注释）。FastFind 与 minimal 这两个正常落位的实现
        // 都没有设置这两项 —— 按已验证可用的最简配置来，少两个变量。
        frames = (0..<frameCount).map { index in
            // 绕竖直轴翻一整圈：正面 → 侧面（压扁） → 背面（水平镜像） → 正面。
            // 只压扁不镜像的话，动得最多 1~2px，肉眼看是"没动"（用户实测反馈过），
            // 背面镜像才是"翻了个面"的关键。
            let angle = Double(index) / Double(frameCount) * 2 * .pi
            let squash = CGFloat(abs(cos(angle)))
            let mirrored = cos(angle) < 0
            return Self.statusImage(squash: max(0.12, squash), mirrored: mirrored)
        }
    }

    /// 复制成功后翻一下：给一个不需要看屏幕就能感知的反馈，同时不打扰。
    func flip() {
        let previous = animationTimer
        previous?.invalidate()
        animationStep = 0
        // 0.07s × 12 帧 ≈ 0.84s：0.04s 太快，一晃而过感知不到（用户实测反馈）；
        // 放慢到接近 1 秒才有"翻了一下"的观感，又不至于拖沓。
        let timer = Timer(timeInterval: 0.07, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.animationStep += 1
            if self.animationStep >= self.frames.count {
                timer.invalidate()
                // 用 refreshIcon 而不是直接画普通图标：暂停态下翻完要回到暂停图标
                self.refreshIcon()
                self.animationTimer = nil
                return
            }
            self.statusItem.button?.image = self.frames[self.animationStep]
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    // ── 诊断 ─────────────────────────────────────────────────

    /// 把状态栏项在系统里的真实状态打出来。
    /// 排查"菜单栏图标看不见"只有这一条路：图标画不出来、被挤到刘海后面、
    /// 或者压根没装上，三种原因在外部看都是"没有图标"，必须从进程内部问。
    func dumpDiagnostics() {
        // 写到文件而不是只 print：GUI 进程被信号掐掉时 stdout 缓冲区不会刷，
        // 结果就是"跑了但什么都没留下"（这一条在家族里踩过不止一次）。
        var lines: [String] = []
        func out(_ text: String) { lines.append(text); print(text) }
        defer {
            let body = lines.joined(separator: "\n") + "\n"
            try? body.write(toFile: "/tmp/boxpaste-status-diagnostic.txt", atomically: true, encoding: .utf8)
        }
        out("── BoxPaste 菜单栏诊断 ──")
        out("statusItem.isVisible: \(statusItem.isVisible)")
        if let button = statusItem.button {
            out("button.image: \(button.image.map { "\($0.size)" } ?? "nil")")
            out("button.isHidden: \(button.isHidden)")
            out("button.frame: \(button.frame)")
            if let window = button.window {
                out("button.window.frame: \(window.frame)")
                out("button.window.isVisible: \(window.isVisible)")
                out("button.window.screen: \(window.screen?.localizedName ?? "nil")")
            } else {
                out("button.window: nil —— 状态栏项没有被系统放进菜单栏")
            }
        } else {
            out("button: nil")
        }
        out("statusBar.thickness: \(NSStatusBar.system.thickness)")
        for (index, screen) in NSScreen.screens.enumerated() {
            out("screen[\(index)] frame: \(screen.frame) visible: \(screen.visibleFrame)")
            out("  safeAreaInsets: \(screen.safeAreaInsets)")
            out("  auxiliaryTopLeft: \(String(describing: screen.auxiliaryTopLeftArea))")
            out("  auxiliaryTopRight: \(String(describing: screen.auxiliaryTopRightArea))")
        }
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier != Bundle.main.bundleIdentifier && $0.activationPolicy == .accessory
        }
        out("其它常驻类应用（占菜单栏的候选）: \(others.count) 个")

        // AppKit 说的 frame 是"我以为我在这儿"，CGWindowList 说的才是
        // "窗口服务器真的把我摆在这儿了"。两者不一致时，问题在放置环节；
        // 一致但屏幕上没东西，问题在绘制环节。
        out("── 窗口服务器里的本进程窗口 ──")
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                kCGNullWindowID) as? [[String: Any]] {
            let mine = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == ProcessInfo.processInfo.processIdentifier }
            if mine.isEmpty { out("（屏幕上没有本进程的窗口）") }
            for info in mine {
                let number = info[kCGWindowNumber as String] as? Int ?? -1
                let layer = info[kCGWindowLayer as String] as? Int ?? -1
                let alpha = info[kCGWindowAlpha as String] as? Double ?? -1
                let name = info[kCGWindowName as String] as? String ?? ""
                var bounds = "?"
                if let dict = info[kCGWindowBounds as String] as? [String: Any],
                   let rect = CGRect(dictionaryRepresentation: dict as CFDictionary) {
                    bounds = "\(rect)"
                }
                out("  window#\(number) layer=\(layer) alpha=\(alpha) bounds=\(bounds) name=\(name)")
            }
        }
        out("statusItem.button.window.windowNumber: \(statusItem.button?.window?.windowNumber ?? -1)")
    }

    // ── 图标绘制 ─────────────────────────────────────────────

    /// 菜单栏图标：剪贴板轮廓 + 顶部夹子 + 两条内容行。
    /// 用 template（isTemplate = true）交给系统着色，明暗菜单栏都自动适配。
    /// `-squash`（scaleBy 为负）就是水平镜像，一帧画出"背面"。
    /// paused = true 时内容行换成两根竖条（"暂停"符号），一眼分辨记录状态。
    private static func statusImage(squash: CGFloat, mirrored: Bool = false,
                                    paused: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            if let context = NSGraphicsContext.current?.cgContext {
                context.translateBy(x: 9, y: 9)
                // 图标整体加宽 10%：18pt 画布里剪贴板略窄高（用户要求）。
                // 乘进横向缩放里，翻转动画的压扁/镜像照常工作。
                context.scaleBy(x: (mirrored ? -squash : squash) * 1.1, y: 1)
                context.translateBy(x: -9, y: -9)
            }

            let body = NSBezierPath(roundedRect: NSRect(x: 4.2, y: 2.4, width: 9.6, height: 13.4),
                                    xRadius: 2.6, yRadius: 2.6)
            body.lineWidth = 1.5
            body.stroke()

            // 夹子：压在上边框上的一小坨
            NSBezierPath(roundedRect: NSRect(x: 6.4, y: 13.6, width: 5.2, height: 2.8),
                         xRadius: 1.4, yRadius: 1.4).fill()

            if paused {
                // 暂停态：两根竖条占住内容区（国际通用的"暂停"符号）
                for x in [6.5, 9.2] {
                    NSBezierPath(roundedRect: NSRect(x: x, y: 5.2, width: 2.2, height: 7.6),
                                 xRadius: 0.9, yRadius: 0.9).fill()
                }
            } else {
                // 内容行
                for y in [9.6, 6.6] {
                    NSBezierPath(roundedRect: NSRect(x: 6.4, y: y, width: 5.2, height: 1.5),
                                 xRadius: 0.75, yRadius: 0.75).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// 按当前状态重画图标。暂停/恢复记录、翻转动画收尾都走这里，
    /// 避免动画把暂停图标覆盖回普通图标。
    func refreshIcon() {
        guard let button = statusItem.button else { return }
        button.image = Self.statusImage(squash: 1, paused: model.isPaused)
    }

    // ── 菜单 ─────────────────────────────────────────────────

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        // 1.0.9 裁剪：导出/导入在设置页里已有、清空历史放这里太危险
        // （两下误点就没了）、"菜单栏设置"只是排查期的一时之需。
        // 1.0.15 起加回两个状态开关（用户要求）：暂停记录（隐私模式）、
        // 记录富文本——都是"看情况切一下"的低频动作，放菜单栏最顺手。
        menu.addItem(item("打开面板", #selector(openPanel)))

        let pauseItem = item(model.isPaused ? "恢复记录" : "暂停记录", #selector(togglePaused))
        menu.addItem(pauseItem)

        let richItem = item("记录富文本", #selector(toggleCaptureRichText))
        richItem.state = model.prefs.value.captureRichText ? .on : .off
        menu.addItem(richItem)

        menu.addItem(.separator())
        menu.addItem(item("设置…", #selector(openSettings)))
        menu.addItem(.separator())
        menu.addItem(item("关于 BoxPaste", #selector(showAbout)))
        // 帮助放在「关于」下面（用户指定位置）。文档本身随包分发
        // （Resources/Help.html → Contents/Resources/Help.html），离线可看。
        menu.addItem(item("使用帮助", #selector(openHelp)))
        menu.addItem(item("退出 BoxPaste", #selector(quit), key: "q"))
        return menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        return menuItem
    }

    @objc private func handleClick(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            // 每次右键都重建菜单：暂停/富文本两个开关的标题与勾选态必须实时，
            // 常驻的旧菜单会把上一次的状态一直挂着。
            // 临时挂上菜单再点一次，是状态栏项出右键菜单的标准做法：
            // 常驻 menu 会把左键也吃掉。
            menu = buildMenu()
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            model.onRequestShowPanel?()
        }
    }

    @objc private func openPanel() { model.onRequestShowPanel?() }
    @objc private func openSettings() { model.onRequestShowSettings?() }
    @objc private func togglePaused() { model.togglePaused() }
    @objc private func toggleCaptureRichText() {
        // 写偏好而不直改监听器：didChange → applyPreferences 会同步过去，
        // 状态只维护一处（重新启动后也自然恢复上次的选择）。
        model.prefs.value.captureRichText.toggle()
    }

    /// 把用户送到「系统设置 → 菜单栏」。这是 26 上唯一能改第三方图标可见性的地方。
    static func openMenuBarSettings() {
        guard let url = URL(string: menuBarSettingsURL) else { return }
        NSWorkspace.shared.open(url)
    }
    @objc private func showAbout() { NSApp.orderFrontStandardAboutPanel(nil) }

    /// 打开随包分发的帮助文档（系统默认浏览器渲染 HTML）。
    /// 裸二进制（.build 下跑自检/诊断）没有 bundle resources，这时退回
    /// 仓库里的源文件路径，方便开发时也点得开。
    @objc private func openHelp() {
        if let url = Bundle.main.url(forResource: "Help", withExtension: "html") {
            NSWorkspace.shared.open(url)
            return
        }
        let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/Help.html")
        if FileManager.default.fileExists(atPath: source.path) {
            NSWorkspace.shared.open(source)
        } else {
            model.showHint("找不到帮助文档（Help.html 未随包分发）", seconds: 4)
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

// ── 面板位置 ─────────────────────────────────────────────────

/// 面板位置单独存在 UserDefaults 里，**不放进 Preferences**。
/// 拖动窗口会连续产生几十次位置变化，混进 Preferences 就会走
/// "@Published → 编码整份配置 → 落盘 → 触发 didChange" 这条重路径，
/// 顺带还会把"重注册热键 / 切 Dock 策略"这些副作用检查全跑一遍。
enum PanelGeometry {
    private static let xKey = "com.pcxx.boxpaste.panelOriginX"
    private static let yKey = "com.pcxx.boxpaste.panelOriginY"

    static var savedOrigin: CGPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: xKey) != nil, defaults.object(forKey: yKey) != nil else { return nil }
        return CGPoint(x: defaults.double(forKey: xKey), y: defaults.double(forKey: yKey))
    }

    static func save(_ origin: CGPoint) {
        let defaults = UserDefaults.standard
        defaults.set(Double(origin.x), forKey: xKey)
        defaults.set(Double(origin.y), forKey: yKey)
    }

    static func clear() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: xKey)
        defaults.removeObject(forKey: yKey)
    }
}

// ── 面板窗口 ─────────────────────────────────────────────────

final class PanelWindow: NSPanel {
    /// 无边框面板默认不能成为 key window，那样里面的输入框就收不到键入。
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {

    private let model: AppModel
    private let window: PanelWindow
    /// 空格预览是独立窗口（800×500 屏幕居中），见 PreviewWindow.swift
    private let preview: PreviewWindowController
    private var keyMonitor: Any?
    /// 呼出面板之前最前面的那个"别人的"应用，粘贴时要还给它
    // 必须强引用：NSRunningApplication 实例跟进程不是绑死的，没强引用时
    // 对象随时可能被释放，weak 一变 nil 后 activate() 直接空转、粘贴目标
    // 也记不上——日志实锤过（目标=未记录、焦点只能干等系统 ~1s 自动归还）。
    private var previousApp: NSRunningApplication?

    /// 粘贴目标：AppModel 发 ⌘V 前轮询焦点是否真的切回了它。
    /// （AppModel 不持有 panel，经 AppDelegate 搭这条只读桥。）
    var pasteTarget: NSRunningApplication? { previousApp }

    init(model: AppModel) {
        self.model = model
        let size = NSSize(width: model.prefs.value.panelWidth,
                          height: model.prefs.value.panelHeight)
        self.window = PanelWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.borderless, .nonactivatingPanel, .resizable],
                                  backing: .buffered,
                                  defer: false)
        self.preview = PreviewWindowController(model: model)
        super.init()

        window.delegate = self
        window.isFloatingPanel = true
        window.level = .floating
        // canJoinAllSpaces：在哪个桌面按热键都能出；fullScreenAuxiliary：全屏应用上也能盖住
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.hidesOnDeactivate = false
        window.animationBehavior = .utilityWindow
        window.minSize = NSSize(width: 340, height: 380)

        installContent()

        // 预览显隐只有模型知道（空格 / Esc / × / 删除条目都会改它），
        // 窗口控制器被动跟随，避免两处各自维护一个"开着吗"的布尔值。
        model.onPreviewVisibilityChanged = { [weak self] visible in
            guard let self else { return }
            if visible { self.preview.show() } else { self.hidePreview() }
        }
    }

    var isVisible: Bool { window.isVisible }

    // ── 视图树装卸 ───────────────────────────────────────────

    /// 装上面板的视图树。init 时装一次；被 teardownContent 拆掉后，
    /// 下次 show 会重建（见 show 里的 hasContent 分支）。
    private func installContent() {
        let hosting = NSHostingView(rootView: PanelRootView().environmentObject(model))
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting
    }

    /// 拆掉面板的视图树，把这一整片内存交回系统。
    ///
    /// 为什么值得：实测跑四小时的实例 footprint 216MB，其中 SwiftUI 视图图占
    /// 78.8MB——402 行记录平均每行 190KB，而历史数据本身只有 212KB。
    /// 面板收起时这棵树没有任何用处；重建耗时见 `--measure-reopen`。
    ///
    /// 只拆 contentView，窗口本身（位置/尺寸/level/键盘行为）原样留着。
    func teardownContent() {
        window.contentView = nil
    }

    var hasContent: Bool { window.contentView != nil }

    /// 重建耗时回调（诊断用）：build = 纯构建，show = 含窗口上屏，frame = 到下一帧
    var onRebuildTiming: ((_ buildMS: Double, _ showMS: Double, _ frameMS: Double) -> Void)?

    func toggle() {
        // 🔴 判据不能用 window.isVisible：它只说明"窗口在窗口服务器上"，
        // 不说明"用户看得见"。面板是 .nonactivatingPanel，当抢激活被系统拒掉
        // （前台是全屏应用、别的应用开着模态、刚从锁屏回来）时，窗口会被摆上台
        // 却从没成为 key；而唯一的自动收起入口是 windowDidResignKey ——
        // 没成为 key 就永远收不起来。于是 isVisible 一直为真、眼前什么都没有，
        // toggle 一按就走 hide()，症状就是"按了完全没反应，再按几次才出来"
        // （用户实测原话）。occlusionState 只回答"这一帧里它有没有被画出来"，
        // 正好是这里要的判据。
        let onScreen = window.isVisible && window.occlusionState.contains(.visible)
        if onScreen {
            hide()
        } else if window.isVisible {
            // 在台上但看不见 / 没拿到键盘：顶到最前，而不是把它关掉
            bringOnScreen()
        } else {
            show()
        }
    }

    func show() {
        let started = CFAbsoluteTimeGetCurrent()

        // 台上已有窗口（上面那种"看得见状态、看不见窗口"）：重新顶上来就行，
        // 不能再走一遍完整 show —— 那会把分类/搜索重置掉，用户会觉得"我刚翻到一半的列表没了"
        if window.isVisible {
            bringOnScreen()
            return
        }

        // 视图树被拆过就先重建（正常路径下 contentView 一直在，这里不会触发）
        let needsRebuild = !hasContent
        if needsRebuild { installContent() }
        let buildMS = (CFAbsoluteTimeGetCurrent() - started) * 1000

        let front = NSWorkspace.shared.frontmostApplication
        // 记下"上一个外部应用"，粘贴完把焦点还回去。
        // 如果最前面的是我们自己（比如从设置窗口按热键），就别覆盖掉原来记的那个。
        if let front, front.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = front
        }

        // 面板打开这件事要最先告诉模型：收起期间的复制只记了脏标记，
        // 列表得在选中/分类这些后续动作之前先补齐，否则 ensureValidSelection
        // 会在空列表上把选中项清掉。
        model.panelDidShow()
        let dataMS = (CFAbsoluteTimeGetCurrent() - started) * 1000 - buildMS

        positionWindow()
        // 每次呼出都落在「全部」上（用户指定：默认分类是全部，不是收藏）。
        model.selectedCategoryID = nil
        model.ensureValidSelection()
        model.searchFocused = false
        model.isPreviewing = false
        model.showsShortcutHelp = false

        installMonitor()
        NSApp.bringForward()
        window.makeKeyAndOrderFront(nil)
        let orderMS = (CFAbsoluteTimeGetCurrent() - started) * 1000

        // 下一轮 runloop 才轮到 Core Animation 提交这一帧 —— 那才是用户"看到"面板的时刻。
        // 这一段不 return：非重建路径也要走，否则"呼出偏慢"永远没有留痕。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let frameMS = (CFAbsoluteTimeGetCurrent() - started) * 1000
            if needsRebuild { self.onRebuildTiming?(buildMS, orderMS, frameMS) }
            // 只在真的慢时写一行：正常呼出 46ms 级，每次都写等于给热路径加一次磁盘 IO
            if frameMS > 120 {
                DiagLog.append(String(format: "呼出偏慢：数据 %.1f · 上屏 %.1f · 到帧 %.1f ms（重建 %@，%d 条）",
                                      dataMS, orderMS - buildMS - dataMS, frameMS,
                                      needsRebuild ? "是" : "否", self.model.items.count))
            }
        }
    }

    /// 把"已经在台上、但看不见 / 没拿到键盘"的面板重新顶到最前。
    ///
    /// 为什么不重跑 panelDidShow 的重活：这条分支是用户连按热键时走的，
    /// 列表状态本来就是好的，再扫一遍剪贴板、重建一遍索引只会让"没反应"更久。
    /// 数据补扫放在窗口之后（见末尾），保证先出画面。
    private func bringOnScreen() {
        let started = CFAbsoluteTimeGetCurrent()
        // 诊断路径可能先拆了视图树又留着窗口：这时顶上来的是个空窗口
        if !hasContent { installContent() }
        let front = NSWorkspace.shared.frontmostApplication
        if let front, front.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = front
        }
        positionWindow()
        installMonitor()
        NSApp.bringForward()
        // orderFrontRegardless：激活被系统拒掉时普通 orderFront 会一直排队等激活，
        // 这个"不管前台是谁、先摆上来"的变体才能保证窗口真的出现在当前屏幕上。
        window.orderFrontRegardless()
        // 面板收不到键入 = 没成为 key。makeKey 是这里的关键动作：
        // 不补这一句，窗口出来了但搜索框打不进字、上下键也没反应。
        window.makeKey()
        let orderMS = (CFAbsoluteTimeGetCurrent() - started) * 1000
        DiagLog.append(String(format: "面板重新上屏：%.1f ms（此前 isVisible=true 但不可见 / 非 key）", orderMS))
        // 藏着的这段时间可能的复制只记了脏标记，这里补一次（排在窗口之后，不挡上屏）
        model.panelDidShow()
    }

    func hide() {
        removeMonitor()
        hidePreview()
        window.orderOut(nil)
        model.isPreviewing = false
        model.showsShortcutHelp = false
        model.searchFocused = false
        model.query = ""
        model.hint = nil
        // 多选是"当下要批量操作"的临时状态，面板一收就该作废，
        // 不然下次呼出还挂着一堆勾选，让人摸不着头脑。
        model.clearMultiSelection()
        // 收起后列表不再刷新（refresh 只记脏）、轮询放慢，见 AppModel.panelDidHide
        model.panelDidHide()
        rememberGeometry()
    }

    /// 收起预览窗。用户点进预览窗选过文字的话它会是 key window，
    /// 这时必须把键盘还给面板，否则之后按空格/Esc 都落在一个隐藏窗口上，
    /// 表现就是"面板还在、按键没反应"。
    private func hidePreview() {
        let wasKey = preview.isKeyWindow
        preview.hide()
        if wasKey, window.isVisible {
            window.makeKey()
        }
    }

    /// 记下尺寸和位置：下次呼出还是这个样子、这个位置。
    /// 位置不记的话，每次呼出都会按鼠标重新居中，用户挪好的位置等于白挪。
    private func rememberGeometry() {
        model.prefs.value.panelWidth = Double(window.frame.width)
        model.prefs.value.panelHeight = Double(window.frame.height)
        PanelGeometry.save(window.frame.origin)
    }

    /// 把焦点还给上一个外部应用（自动粘贴前的必要动作）
    func reactivatePreviousApp() {
        guard let app = previousApp, !app.isTerminated else { return }
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [])
        }
    }

    // ── 定位 ─────────────────────────────────────────────────

    private func positionWindow() {
        let size = window.frame.size

        // 先试"上次的位置"：用户挪到哪儿就待在哪儿。
        if let saved = PanelGeometry.savedOrigin {
            let frame = NSRect(origin: saved, size: size)
            // 只有这块区域还实实在在落在某块屏幕上时才用它。
            // 否则（拔过外接屏、改过分辨率）会得到一个在任何屏幕外都看不见的窗口 ——
            // 那种情况下用户看到的现象是"热键按了但面板不出来"，比位置跑偏严重得多。
            if let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) {
                // 位置原样还原，只有真探出屏幕才夹回边界。
                // 之前各留 8pt "安全边距"，用户把面板顶到菜单栏底下时，
                // 每次呼出都被往下压 8pt+ —— "下次打开总是有点向下偏移"（用户实测）。
                let area = screen.visibleFrame
                var origin = saved
                origin.x = min(max(origin.x, area.minX), area.maxX - size.width)
                origin.y = min(max(origin.y, area.minY), area.maxY - size.height)
                window.setFrame(NSRect(origin: origin, size: size), display: false)
                return
            }
            PanelGeometry.clear()
        }

        // 没有历史位置：落在鼠标所在屏幕的中间偏上。
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        var origin = CGPoint(x: visible.midX - size.width / 2,
                             // 居中偏上：中下方留给列表，视线不用来回跑
                             y: visible.midY - size.height / 2 + visible.height * 0.08)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        window.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    /// 挪窗口就记下来。拖动过程中会连着回调，写 UserDefaults 很便宜，扛得住。
    func windowDidMove(_ notification: Notification) {
        guard window.isVisible else { return }
        PanelGeometry.save(window.frame.origin)
    }

    // ── 失焦收起 ─────────────────────────────────────────────

    func windowDidResignKey(_ notification: Notification) {
        // 置顶态就是"别自己消失"：用户开着面板去别的窗口翻资料、选内容，
        // 这时候收起来等于让这个开关没有意义。
        if model.prefs.value.alwaysOnTop { return }

        // 拖拽输出时鼠标键还按着，这时候窗口失焦**不能**收：
        // 一收源窗口就没了，拖到一半的东西直接作废。
        if NSEvent.pressedMouseButtons != 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, self.window.isVisible, !self.window.isKeyWindow,
                      NSEvent.pressedMouseButtons == 0 else { return }
                self.hide()
            }
            return
        }
        hide()
    }

    // ── 键盘路由 ─────────────────────────────────────────────

    private func installMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    private func removeMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        // 本地监听是应用级的：设置窗口、保存面板的按键也会经过这里，
        // 只处理属于本面板（和它的预览窗）的那些。
        // 预览窗也要收：用户点进去选文字后它就是 key window，
        // 这时空格/Esc/方向键必须照常生效，否则"一点文字就失去键盘控制"。
        guard event.window === window || event.window === preview.nsWindow else { return event }
        let prefs = model.prefs.value

        // 1) 搜索框聚焦时，先把键让给输入框。
        //    只留「粘贴」和上下移动：这时候 ⌘C 应该是"复制选中的搜索词"、
        //    ⌘⌫ 应该是"删到行首"、空格应该是"打一个空格"，不能被面板动作抢走。
        if model.searchFocused {
            if prefs.spec(for: .paste).matches(event) {
                perform(.paste)
                return nil
            }
            switch Int(event.keyCode) {
            case kVK_Escape:     model.searchFocused = false; return nil
            case kVK_DownArrow:  model.moveSelection(by: 1); return nil
            case kVK_UpArrow:    model.moveSelection(by: -1); return nil
            default:             return event
            }
        }

        // 2) 可配置动作。能走到这里说明搜索框没聚焦（上面那段已经 return 走了）。
        for action in [ShortcutAction.paste, .preview, .pin, .delete, .copy]
        where prefs.spec(for: action).matches(event) {
            perform(action)
            return nil
        }

        // 3) 固定键
        switch Int(event.keyCode) {
        case kVK_Escape:
            // 逐层退出：多选 → 预览 → 快捷键帮助 → 搜索词 → 面板
            if !model.multiSelection.isEmpty { model.clearMultiSelection() }
            else if model.isPreviewing { model.isPreviewing = false }
            else if model.showsShortcutHelp { model.showsShortcutHelp = false }
            else if !model.query.isEmpty { model.query = "" }
            else { hide() }
            return nil
        case kVK_UpArrow:   model.moveSelection(by: -1); return nil
        case kVK_DownArrow: model.moveSelection(by: 1); return nil
        case kVK_LeftArrow:
            if model.viewMode == .grid { model.moveSelectionHorizontally(by: -1, columns: model.gridColumns) }
            return nil
        case kVK_RightArrow:
            if model.viewMode == .grid { model.moveSelectionHorizontally(by: 1, columns: model.gridColumns) }
            return nil
        case kVK_Home:      model.selectFirst(); return nil
        case kVK_End:       model.selectLast(); return nil
        case kVK_PageUp:    model.moveSelection(by: -5); return nil
        case kVK_PageDown:  model.moveSelection(by: 5); return nil
        case kVK_Tab:
            model.cycleCategory(forward: !event.modifierFlags.contains(.shift))
            return nil
        default: break
        }

        // 3.5) ⌥组合：视图切换（原来在 ⌘1/2/3 上，⌘1-9 让位给快捷粘贴后挪到这里）
        if event.modifierFlags.contains(.option), !event.modifierFlags.contains(.command) {
            switch Int(event.keyCode) {
            case kVK_ANSI_1: model.setViewMode(.rich); return nil
            case kVK_ANSI_2: model.setViewMode(.compact); return nil
            case kVK_ANSI_3: model.setViewMode(.grid); return nil
            default: break
            }
        }

        // 4) ⌘ 组合
        if event.modifierFlags.contains(.command) {
            // ⌘1-9 = 直接粘贴列表第 N 条（Maccy 的习惯键位）
            let digitKeys: [Int: Int] = [
                kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3, kVK_ANSI_4: 4,
                kVK_ANSI_5: 5, kVK_ANSI_6: 6, kVK_ANSI_7: 7, kVK_ANSI_8: 8, kVK_ANSI_9: 9,
            ]
            switch Int(event.keyCode) {
            case kVK_ANSI_F:     model.searchFocused = true; return nil
            case kVK_ANSI_L:     model.query = ""; return nil
            case kVK_ANSI_Z:     model.undoLastDelete(); return nil
            case kVK_ANSI_A:     model.selectAllForMultiSelection(); return nil
            case kVK_ANSI_Comma: model.onRequestShowSettings?(); return nil
            default:
                if let position = digitKeys[Int(event.keyCode)] {
                    model.quickPaste(at: position)
                    return nil
                }
                return event
            }
        }

        // 5) 其余可打印字符直接进搜索框 —— 这是"全键盘操作"的关键：
        //    不用先点一下搜索框就能开始打字。
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let characters = event.characters, !characters.isEmpty {
            let scalars = characters.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            guard !scalars.isEmpty else { return nil }
            model.query += String(scalars.map { Character($0) })
            return nil
        }
        return nil
    }

    private func perform(_ action: ShortcutAction) {
        switch action {
        case .paste:   model.pasteSelected()
        case .preview: model.isPreviewing.toggle()
        case .pin:     model.togglePinSelected()
        case .delete:  model.deleteSelected()
        case .copy:    model.copySelectedToList()
        case .recallPanel, .openSettings: break   // 全局键，面板内不重复触发
        }
    }
}

// ── 设置窗口 ─────────────────────────────────────────────────

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    private let model: AppModel
    private let window: NSWindow
    /// 用户关掉设置窗时通知外部把控制器也放掉（下次打开重建）
    var onClose: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered,
                              defer: false)
        window.title = "BoxPaste 设置"
        // 关窗后会被拆掉、下次打开重建（见 windowWillClose），所以这里
        // 别设 isReleasedWhenClosed = true：窗口的生死由我们自己管。
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        super.init()
        window.delegate = self
        installContent()
    }

    func show() {
        // 正常路径下关窗后控制器已被放掉、会重建一个新实例；
        // 但关闭通知是异步发的，这个空隙里再点"设置"就可能拿到
        // contentView 已置空的窗口 —— 那会露出一片空白，所以补一次。
        if window.contentView == nil { installContent() }
        window.makeKeyAndOrderFront(nil)
        NSApp.bringForward()
    }

    private func installContent() {
        let hosting = NSHostingView(rootView: SettingsRootView().environmentObject(model))
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting
    }

    /// 程序化关闭：走的是和点红点完全相同的路径（performClose → windowWillClose），
    /// 所以诊断量到的就是用户关窗时的真实行为。
    func close() {
        window.performClose(nil)
    }

    /// 自动重启不能把用户正在调设置的窗口抽走
    var isVisible: Bool { window.isVisible }

    /// 诊断用：把窗口挪到屏幕左上角。截图核对面板排版时，
    /// 屏幕中部的窗口经常被别的窗口盖住右半边（开关那列就看不见了）。
    func moveForDiagnostics() {
        guard let visible = NSScreen.main?.visibleFrame else { return }
        window.setFrameOrigin(NSPoint(x: visible.minX + 20,
                                      y: visible.maxY - window.frame.height - 20))
    }

    /// 关窗即拆：设置页 700 多行、几十个控件，整棵 SwiftUI 视图树常驻要 17MB
    /// （实测 32MB → 49MB，且关窗 25 秒后仍不回落）。用户关了就不再需要它，
    /// 下次打开重建不过几十毫秒，比常驻 17MB 划算得多。
    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            // 先拆 contentView：这一步才会释放 NSHostingView 和整棵视图树
            window.contentView = nil
            // 再让外部放掉控制器本身。必须挪到下一轮 runloop：
            // 在关闭回调里同步释放自己，等于在自己的栈上 dealloc。
            let notify = onClose
            DispatchQueue.main.async { notify?() }
        }
    }
}
