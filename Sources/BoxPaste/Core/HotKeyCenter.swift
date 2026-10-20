import AppKit
import Carbon.HIToolbox

// ============================================================
// 全局热键（Carbon RegisterEventHotKey）
//
// 为什么不用 NSEvent.addGlobalMonitorForEvents：
//   那个 API 要求"辅助功能/输入监控"授权，未授权时静默不触发；
//   而 Carbon 的热键注册是系统级 API，不需要任何授权、不影响键盘输入，
//   是菜单栏工具注册全局键的常规做法。代价是得跟 C 回调打交道（下面这一坨）。
//
// 注意：这是**全局唯一**的注册中心。重复注册同一个键位会失败（返回
// eventHotKeyExistsErr），所以设置页改键位时必须先全部注销再重注册。
// ============================================================

final class HotKeyCenter {

    /// 四个字符的签名，Carbon 用它区分"这个热键是我的"。
    /// 'BPST' —— 换应用时记得换（同签名 + 同 id 会撞车）。
    private static let signature: OSType = 0x4250_5354

    static let shared = HotKeyCenter()

    private var eventHandler: EventHandlerRef?
    private var registrations: [UInt32: (ref: EventHotKeyRef?, action: @MainActor () -> Void)] = [:]
    private var nextID: UInt32 = 1

    private init() {
        installHandler()
    }

    private func installHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        // Swift 的闭包在这里被当成 C 函数指针，所以**不能捕获任何上下文**：
        // self 通过 userData 指针传进去。
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hotKeyID)
            guard status == noErr else { return status }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            center.fire(id: hotKeyID.id)
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(),
                            callback,
                            1,
                            &eventType,
                            Unmanaged.passUnretained(self).toOpaque(),
                            &eventHandler)
    }

    private func fire(id: UInt32) {
        guard let action = registrations[id]?.action else { return }
        // Carbon 的回调就是在主线程上发的（热键事件进主 run loop），
        // 这里只是把这个事实显式告诉编译器，不做线程切换——
        // 换成 DispatchQueue.main.async 会让"按下热键"和"面板出现"之间多一帧延迟。
        MainActor.assumeIsolated { action() }
    }

    /// 整批替换全部全局键，返回注册失败的键位。
    ///
    /// ★ 这个 API 形状是刻意的：早先的写法是 register() 内部先 unregisterAll()，
    /// 于是"注册两个键"时第二次调用会把第一次的注册一起清掉 —— 表现是呼出热键
    /// 静默失效（按 ⇧⌘V 完全没反应，还没有任何报错）。改成"给一份完整清单、
    /// 整批替换"之后，这种互相清空的写法在接口层面就不成立了：
    /// 一次调用只可能注册一份清单，没有"半途被清空"的中间态。
    @discardableResult
    func replaceAll(with entries: [(spec: KeySpec, action: @MainActor () -> Void)]) -> [KeySpec] {
        unregisterAll()
        var failed: [KeySpec] = []
        for entry in entries {
            guard entry.spec.isUsableAsGlobal else {
                failed.append(entry.spec)
                continue
            }
            let id = nextID
            nextID += 1
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
            let status = RegisterEventHotKey(UInt32(entry.spec.keyCode),
                                             entry.spec.carbonModifiers,
                                             hotKeyID,
                                             GetApplicationEventTarget(),
                                             0,
                                             &ref)
            if status == noErr, let ref {
                registrations[id] = (ref, entry.action)
            } else {
                // 最常见的原因是两个动作被配成了同一个键位（Carbon 报
                // eventHotKeyExistsErr），或者键位被别的应用占了。
                failed.append(entry.spec)
            }
        }
        return failed
    }

    func unregisterAll() {
        for (_, entry) in registrations {
            if let ref = entry.ref { UnregisterEventHotKey(ref) }
        }
        registrations.removeAll()
        nextID = 1
    }
}
