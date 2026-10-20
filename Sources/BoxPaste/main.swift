import AppKit
import Foundation

// ============================================================
// 入口
//
// 自检必须在 SwiftUI / AppKit 起来之前拦掉：NSApplication.run() 之后
// 进程就挂在事件循环上了，--selftest 会变成一个"看不到结果、也退不出来"的
// 后台 GUI 进程。所以这几行一定要放在最前面。
// ============================================================

if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest.run())
}

if CommandLine.arguments.contains("--version") {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    print(version)
    exit(0)
}

let application = NSApplication.shared
// 顶层代码本身不是 main-actor 隔离的；AppDelegate 是 @MainActor 的，
// 这里显式声明"我就在主线程上"，避免为了绕开隔离检查把它降级成非隔离类
// （那样它就没法直接指挥 @MainActor 的 AppModel 了）。
let delegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = delegate
// 兜底身份：从裸可执行文件启动（swift run / 直接跑 .build 里的产物）时没有
// bundle 里的 LSUIElement，这里显式设成 accessory，行为才和 .app 里一致。
application.setActivationPolicy(.accessory)
application.run()
