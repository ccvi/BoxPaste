// swift-tools-version: 5.10
import PackageDescription

// BoxPaste —— 剪贴板历史管理器（菜单栏常驻 + 全局热键呼出面板）。
//
// 关于 platform 写 .v14 而不是 .v26：
//   用户机器是 M5 + macOS 26，但本项目用到的能力（NSPasteboard / Carbon 热键 /
//   SwiftUI / SMAppService 替代方案）在 14 上就齐了。抬到 26 换不到任何东西，
//   却会让它在 14/15 上一行都跑不起来；真正依赖新系统的只是外观细节，
//   走 if #available 分支即可。
//
// 不声明任何第三方依赖：
//   全局热键走系统 Carbon（RegisterEventHotKey），不需要辅助功能授权；
//   自动粘贴走 CGEvent（这一项**需要**辅助功能授权，未授权时自动降级为"只回写剪贴板"）。
let package = Package(
    name: "BoxPaste",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "BoxPaste", targets: ["BoxPaste"])
    ],
    targets: [
        .executableTarget(
            name: "BoxPaste",
            path: "Sources/BoxPaste"
        )
    ]
)

// 说明：本项目不提供 SwiftPM 的 test target。
// 原因与家族其他项目一致：XCTest.framework 随 Xcode 分发，本机只装了 Command Line
// Tools，一旦声明 testTarget，`swift build` 会因 "no such module 'XCTest'" 直接失败，
// 连主程序都编不出来。因此改为内置自检（App/SelfTest.swift），用 `BoxPaste --selftest`
// 运行，覆盖同样的断言且不依赖 Xcode，build-app.sh 也会拿它做发布门禁。
