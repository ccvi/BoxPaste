import AppKit
import ApplicationServices
import CoreGraphics

// ============================================================
// 粘贴
//
// 两件事分开：
//   ① 把内容**写回系统剪贴板** —— 永远成功，不需要任何权限；
//   ② 模拟 ⌘V 替用户按下去 —— 需要"辅助功能"授权。
//
// ②失败时不做任何弹窗骚扰，只降级成 ①，并在面板上留一行提示
// （"已复制，按 ⌘V 粘贴"）。自检里也覆盖了"未授权时 write 仍然成功"。
// ============================================================

enum Paster {

    // ── 权限 ─────────────────────────────────────────────────

    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// TCC 在辅助功能清单变化时发的系统分布式通知。
    /// 设置页的授权状态行靠它实时刷新（只靠 AXIsProcessTrusted 的话，
    /// SwiftUI 不知道该什么时候重算，用户勾完回来看到的还是"未授权"）。
    static let accessibilityChangedNotice =
        Notification.Name("com.apple.accessibility.api")

    /// 触发系统授权弹窗（只会弹一次，之后要去系统设置里手动勾）
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // ── 写回剪贴板 ───────────────────────────────────────────

    /// 把条目写回系统剪贴板，并让监听器忽略这次变化。
    /// 返回 true 表示写成功（内容类型受支持）。
    @discardableResult
    static func write(_ item: ClipItem, store: ClipStore, watcher: ClipboardWatcher) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        var ok = true
        switch item.kind {
        case .text, .link, .color:
            ok = pasteboard.setString(item.text, forType: .string)

        case .image:
            guard let url = store.imageURL(for: item), let data = try? Data(contentsOf: url) else { return false }
            // 同时给 PNG 与 TIFF：不同目标应用挑不同类型，只给一种会出现
            // "在预览里粘得进去、在 Word 里粘不进去"这种看运气的问题。
            pasteboard.setData(data, forType: .png)
            if let image = NSImage(data: data),
               let rep = NSBitmapImageRep(data: image.tiffRepresentation ?? Data()),
               let tiff = rep.representation(using: .tiff, properties: [:]) {
                pasteboard.setData(tiff, forType: .tiff)
            }

        case .file:
            let urls = item.fileURLs as [NSURL]
            // 文件不存在时（外部删了）也给路径文本，至少能粘到地址栏/终端里
            let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path ?? "") }
            if existing.isEmpty {
                ok = pasteboard.setString(item.text, forType: .string)
            } else {
                ok = pasteboard.writeObjects(existing)
                // 同时挂一份纯文本路径：拖进终端、粘进配置文件时没有它就得手打
                pasteboard.setString(item.text, forType: .string)
            }
        }

        watcher.ignore(changeCount: pasteboard.changeCount)
        return ok
    }

    // ── 模拟 ⌘V ──────────────────────────────────────────────

    @discardableResult
    static func sendPasteKeystroke() -> Bool {
        guard isAccessibilityTrusted else { return false }
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        let keyV: CGKeyCode = 9   // kVK_ANSI_V
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
