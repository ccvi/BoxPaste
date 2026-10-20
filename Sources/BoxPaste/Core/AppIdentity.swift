import Foundation

// ============================================================
// 应用身份
//
// **为什么 bundle id 是「com.pcxx.boxpastemac」而不是「com.pcxx.boxpaste」**
//
// macOS 26 上有一个实测确认、且不可逆的机制（FastFind 在 1.0.9→1.0.10 期间
// 用单变量对照钉死的，本项目又踩了一遍）：
//
//     **直接执行 .app 内的二进制**（/path/App.app/Contents/MacOS/App，
//     绕开 LaunchServices）会让**这个 bundle id 的状态栏登记永久失效**
//     —— 之后无论经 LaunchServices 启动多少次，状态项都停在 (0, -h, 20, 22)，
//     `isVisible` 照样是 true，但屏幕上什么都没有。
//
// 对照数据（同一份二进制、同一台机器）：
//     · 直接 exec .app 内二进制   → 落位失败，且这个 id 此后永久失效
//     · 同一个 .app 经 LaunchServices 启动 → 正常落位
//     · 裸可执行文件（不在 .app 里）→ 不受影响，始终能落位
//     · lsregister -u/-f、删偏好、重启 ControlCenter、killall lsd → 全部无效
//
// BoxPaste 的旧 id 在诊断期间被直接 exec 过若干次，已确认烧坏
// （诊断特征完全吻合：frame (0, -17, 20, 22)、windowNumber == 4294967296）。
// 唯一可行的修复就是换一个 id —— 跟 FastFind 换成 com.pcxx.fastfindmac 同一个办法。
//
// ⚠️ 铁律：**永远不要直接执行 .app 里的二进制**。
//    自检请用 .build 下的裸产物（build-app.sh 第 2 步就是这么做，安全的）；
//    要看界面/诊断，用 `open --args` 或 `open` 经 LaunchServices 启动。
// ============================================================

enum AppIdentity {

    /// 当前 bundle id。**换这个值等于给应用换一个系统身份**，
    /// 偏好域、登录项、菜单栏登记都跟着它走。
    static let bundleIdentifier = "com.pcxx.boxpastemac"

    /// 历史上的 bundle id。偏好要搬到当前 id 名下（见 migrateLegacyDefaultsIfNeeded）。
    static let legacyBundleIdentifier = "com.pcxx.boxpaste"

    /// 把旧 bundle id 偏好域里的东西搬到当前 id 名下。
    ///
    /// 只搬一次：新域里已经有 `com.pcxx.boxpaste.preferences`（应用真正的设置键）
    /// 就说明迁过了或本来就是新版，什么都不做 —— 否则每次启动都会用旧值
    /// 覆盖用户在新版里刚改过的设置。
    ///
    /// 登录项的 LaunchAgent 与菜单栏的 NSStatusItem 键都跳过：
    /// 前者有单独的清理函数，后者是诊断期间写入的垃圾，搬过去只会误导。
    @MainActor
    static func migrateLegacyDefaultsIfNeeded() {
        let standard = UserDefaults.standard
        guard standard.object(forKey: "com.pcxx.boxpaste.preferences") == nil else { return }

        guard let legacy = standard.persistentDomain(forName: legacyBundleIdentifier),
              !legacy.isEmpty else { return }

        copyLegacyKeys(legacy, into: standard)
        relocateLegacyLoginItem()
    }

    /// 从旧域往新域搬键。单独抽出来（而不是塞在上面的流程里）是为了让自检
    /// 能用两个互不干扰的测试域验证搬移规则，不用碰这台机器的真实偏好。
    ///
    /// 规则两条：
    ///   · `NSStatusItem` 开头的键不搬 —— 那是诊断期间写进去的垃圾，
    ///     搬过去只会让「系统设置 → 菜单栏」多出莫名其妙的记录。
    ///   · 其余全搬。搬移整体只发生一次（上面的哨兵键保证），所以这里
    ///     不需要逐键判断"新域是否已有"，简单覆盖即可。
    static func copyLegacyKeys(_ legacy: [String: Any], into target: UserDefaults) {
        for (key, value) in legacy where !key.hasPrefix("NSStatusItem") {
            target.set(value, forKey: key)
        }
    }

    /// 换 id 之前登记过的开机启动项要跟着搬到新 Label 名下。
    ///
    /// 只删不搬的后果：旧 agent 成了没人管的孤儿，用户在设置里看到的开关
    /// 状态和系统实际状态对不上。搬过去等于把同一条注册换个名字，用户无感。
    ///
    /// 这里**必须复用 LoginItem.setEnabled**，不要自己再写一遍 plist：
    /// 同一件事有两份实现，早晚会有一份悄悄过期。
    /// `launchctl remove` 失败无所谓（多半本来就没加载），旧文件删掉即可。
    static func relocateLegacyLoginItem() {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        let old = base.appendingPathComponent("LaunchAgents/\(legacyBundleIdentifier).plist")
        guard FileManager.default.fileExists(atPath: old.path) else { return }

        try? FileManager.default.removeItem(at: old)
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = ["remove", legacyBundleIdentifier]
        try? task.run()

        // 旧 agent 在 = 用户开过开机启动；原样搬到新 Label 名下。
        // 即使写失败，PreferencesStore 初始化的对齐逻辑也会把开关拨回真实状态，
        // 不会留下「界面说开了、系统里没有」的假状态。
        try? LoginItem.setEnabled(true)
    }
}
