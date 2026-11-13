import AppKit
import SwiftUI

// ============================================================
// 空格预览的独立窗口
//
// 为什么从"面板里的一层覆盖"改成独立窗口：面板本身只有 400~600pt 宽，
// 预览挤在里面看大图、看长文、看 HEX 色块都只是"勉强能看"。独立出来后
// 给足 800×500，还能屏幕居中，不动面板的选中行和滚动位置。
//
// 关键取舍：
//   - level 比面板（.floating）高一层，否则会被面板压住；
//   - 不主动 makeKey，键盘仍然落在面板上（空格 / Esc / 方向键照旧）；
//     但允许用户点进来选文字——那时它接过键盘，PanelController 的监听
//     同样处理这个窗口的事件（见 handle(_:) 的 guard）。
//   - 位置不记忆：预览是"临时看一眼"，固定居中反而好找。
// ============================================================

/// 无边框面板默认不能成为 key window，那样里面的文字就没法选中。
private final class PreviewWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 事件派发**之前**先把 key 拿回来。
    ///
    /// AppKit 对非 key 窗口的处理是"这一下鼠标只用来抢焦点"，随即把控件动作丢掉。
    /// 这里先 makeKey，随后的 super 派发就照常规走，第一下点击就落在按钮上。
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !isKeyWindow { makeKey() }
        super.sendEvent(event)
    }
}

/// 预览窗的宿主视图：**允许第一下点击直接落到控件上**。
///
/// AppKit 的默认规矩是"点一下只用来把窗口变成 key，控件动作丢掉"。预览窗
/// 开着的时候，几种情况都会让它不再是 key：翻译弹出的系统语言包面板拿走焦点、
/// 切到别的应用看一眼再回来、点了语言下拉。回来第一下点右上角 × 就被吞掉，
/// 表现出来正是"关闭按钮失效，再点一下才好"。这里让它直接接受第一下点击。
private final class PreviewHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class PreviewWindowController {

    /// 内容尺寸（用户指定 800×500）。无标题栏，所以这就是窗口总大小。
    static let contentSize = NSSize(width: 800, height: 500)

    private let model: AppModel
    private let window: PreviewWindow

    init(model: AppModel) {
        self.model = model
        window = PreviewWindow(contentRect: NSRect(origin: .zero, size: Self.contentSize),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered,
                               defer: false)
        window.isFloatingPanel = true
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        // canJoinAllSpaces：在哪个桌面按空格都能看；fullScreenAuxiliary：全屏应用上也能盖住
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.animationBehavior = .utilityWindow
        window.isMovableByWindowBackground = false

        let hosting = PreviewHostingView(rootView: PreviewWindowRoot().environmentObject(model))
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting
    }

    var isVisible: Bool { window.isVisible }
    /// 键盘事件归属判断用：PanelController 也要处理这个窗口里的按键
    var nsWindow: NSWindow { window }
    /// 用户点进预览窗选文字后它就成了 key window，收起时要靠这个把键盘还给面板
    var isKeyWindow: Bool { window.isKeyWindow }

    /// 显示在屏幕中央（跟随面板所在的那块屏；面板没开时用鼠标所在的屏）。
    func show() {
        // 没有选中项就没有可看的东西，直接不出现
        guard model.selectedItem != nil else { return }
        window.setFrame(centeredFrame(), display: false)
        // 🔴 makeKey 而不是 orderFront：非 key 窗口的**第一下点击只用来抢焦点**，
        // 控件动作会被吞掉 —— 用户点「翻译」看起来毫无反应，必须再点一次（实测）。
        // 键盘交给预览后不会失能：空格 / Esc / 方向键仍由 PanelController 的按键路由处理
        // （handle 的 guard 同时认预览窗），面板也不会因为失焦而收起
        // （见 PanelController.windowDidResignKey 里"键盘在自己窗口上就不收"的分支）。
        window.makeKeyAndOrderFront(nil)
    }

    func hide() {
        window.orderOut(nil)
    }

    private func centeredFrame() -> NSRect {
        let size = Self.contentSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            return NSRect(origin: .zero, size: size)
        }
        return NSRect(x: visible.midX - size.width / 2,
                      y: visible.midY - size.height / 2,
                      width: size.width,
                      height: size.height)
    }
}

/// 窗口内容：跟着 model 的选中项走，选中项变了/被删了都自动重画。
private struct PreviewWindowRoot: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let item = model.selectedItem {
            PreviewCard(item: item)
        } else {
            // 在预览里点了「删除」：条目没了，窗口已被收起，这里给个空占位
            Color.clear
        }
    }
}
