import AppKit

// ============================================================
// 反馈：提示音
//
// 用系统音效而不是打包一个音频文件：应用图标那套"代码绘制、可复现"
// 的原则同样适用于声音——系统音效在每台 Mac 上都在，
// 打包进去只会让包变大、还得处理版权。
// ============================================================

enum SoundFeedback {

    /// 可选的提示音（用户指定这五个，2026-10-16 逐个试听后圈定）。
    /// name 是系统音效文件名（/System/Library/Sounds/*.aiff 去扩展名）。
    static let options: [(name: String, title: String)] = [
        ("Glass", "玻璃轻响"),
        ("Purr", "轻柔低鸣"),
        ("Ping", "清脆叮声"),
        ("Sosumi", "轻快弹跳"),
        ("Submarine", "声呐低鸣"),
    ]

    /// 每个音效各自缓存：切换音效后来回试听不重复加载，
    /// 每次 NSSound(named:) 有几十毫秒延迟，反馈讲究即时。
    private static var cache: [String: NSSound] = [:]

    private static func sound(named name: String) -> NSSound? {
        if let cached = cache[name] { return cached }
        // 找不到（系统音效被裁剪之类）就退回 Glass，再不行就 nil 静默
        let created = NSSound(named: NSSound.Name(name))
            ?? NSSound(named: NSSound.Name("Glass"))
        cache[name] = created
        return created
    }

    static func playCopyFeedback(enabled: Bool, soundName: String) {
        guard enabled else { return }
        play(sound(named: soundName))
    }

    /// 设置页的"试听"：播用户当前选中的那个
    static func preview(soundName: String) {
        play(sound(named: soundName))
    }

    private static func play(_ sound: NSSound?) {
        guard let sound else { return }
        // 连着复制时上一声还没播完，先停再播，避免叠成一团噪音
        if sound.isPlaying { sound.stop() }
        sound.play()
    }
}
