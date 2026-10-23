import AppKit

// ============================================================
// 反馈：提示音
//
// 用系统音效而不是打包一个音频文件：应用图标那套"代码绘制、可复现"
// 的原则同样适用于声音——系统音效在每台 Mac 上都在，
// 打包进去只会让包变大、还得处理版权。
// ============================================================

enum SoundFeedback {

    /// 可选的提示音（2026-10-22 用户试听后圈定这 8 个；
    /// 上一版的 Sosumi / Submarine 已下线）。
    /// name 是系统音效文件名（/System/Library/Sounds/*.aiff 去扩展名）。
    /// 顺序按字母排：设置页的选择器照这个顺序展示，排序本身就是一种"好找"。
    static let options: [(name: String, title: String)] = [
        ("Blow", "气声轻吹"),
        ("Bottle", "空瓶脆响"),
        ("Funk", "节奏拨弦"),
        ("Glass", "玻璃轻响"),
        ("Hero", "英雄上扬"),
        ("Morse", "电报脉冲"),
        ("Ping", "清脆叮声"),
        ("Purr", "轻柔低鸣"),
    ]

    /// 当前可用的音效名集合。设置页读到不在这个集合里的旧值时要落回默认，
    /// 否则 Picker 会显示空白（旧版本的 Sosumi/Submarine 就是这种存量）。
    static var availableNames: Set<String> { Set(options.map(\.name)) }

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
