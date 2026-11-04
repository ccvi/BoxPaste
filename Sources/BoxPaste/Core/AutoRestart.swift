import Darwin
import Foundation

// ============================================================
// 自动重启（内存回收）
//
// 为什么需要它：实测跑久了的实例 footprint 会到 200MB+，其中 SwiftUI 视图图
// 占大头（滚过 402 行 = 73MB）。而**拆视图树只能回收 11MB**（实测 106.0 → 94.7），
// 因为分配器只在整片 region 空出来时才把页交还内核，滚动产生的内存是碎片化的。
// 只有退出进程重来（重新映射）能真正还给系统。
//
// 触发规则（用户 2026-11-04 指定）：
//   · footprint ≥ 250MB 且空闲 ≥ 30 秒
//   · 距上次自动重启 ≥ 30 分钟
//   · 24 小时内连续 3 次重启后仍超阈值 → 停用
//   · 用户手动关闭再打开 = 规则重置
//
// 「连续 3 次」必须跨进程计数（重启就是换进程），所以状态写文件；
// 用 pending 标记区分「自己拉起的」和「用户手动开的」——后者一律重置。
// ============================================================

/// 重启状态快照。落盘到数据目录，所以诊断实例（--store-root）各算各的。
struct AutoRestartState: Codable, Equatable {
    /// 当前 24 小时窗口内已经自动重启了几次
    var count: Int = 0
    /// 当前窗口的起点（第一次自动重启的时间）
    var windowStart: Date?
    /// 上一次自动重启的时间（冷却用）
    var lastRestartAt: Date?
    /// 标记「下一次启动是自动重启拉起的」。启动时消费掉并清零，
    /// 所以用户手动关掉再打开不会继承计数（= 规则重置）。
    var pending: Bool = false
}

enum AutoRestartPolicy {

    static let thresholdMB: Double = 250
    static let idleSeconds: TimeInterval = 30
    static let cooldownSeconds: TimeInterval = 30 * 60
    static let maxRestarts: Int = 3
    static let windowSeconds: TimeInterval = 24 * 60 * 60

    enum Decision: Equatable {
        case restart
        /// 不重启的原因，写诊断日志用（排查「为什么没触发」）
        case skip(String)
    }

    /// 纯判定：把「该不该重启」从定时器与 IO 里剥出来，自检可以直接喂参数。
    ///
    /// 三个阈值做成参数是为了端到端验证：正式值在 250MB/30 秒，要等几小时才可能满足，
    /// 验证时用 /tmp 标记文件把门槛调小，才能真的把「触发 → 退出 → 拉起 → 继承计数」
    /// 这条链路跑一遍（见 AppDelegate.autoRestartTuning）。
    static func decide(footprintMB: Double,
                       idleFor: TimeInterval,
                       state: AutoRestartState,
                       now: Date,
                       thresholdMB: Double = AutoRestartPolicy.thresholdMB,
                       idleSeconds: TimeInterval = AutoRestartPolicy.idleSeconds,
                       cooldownSeconds: TimeInterval = AutoRestartPolicy.cooldownSeconds) -> Decision {
        guard footprintMB >= thresholdMB else {
            return .skip(String(format: "内存 %.0fMB < %.0fMB", footprintMB, thresholdMB))
        }
        guard idleFor >= idleSeconds else {
            return .skip(String(format: "才空闲 %.0f 秒", idleFor))
        }
        if let last = state.lastRestartAt, now.timeIntervalSince(last) < cooldownSeconds {
            return .skip("距上次自动重启不足冷却时间")
        }
        // 窗口内的第 3 次之后停用；窗口（24h）过期则重新获得 3 次机会
        if let start = state.windowStart,
           now.timeIntervalSince(start) < windowSeconds,
           state.count >= maxRestarts {
            return .skip("24 小时内已自动重启 \(state.count) 次，停用")
        }
        return .restart
    }

    /// 执行重启前算出新的计数与窗口起点：
    /// 窗口内累加；窗口过期（或首次）从 1 重新开始。
    static func advanced(_ state: AutoRestartState, now: Date) -> AutoRestartState {
        var next = state
        if let start = state.windowStart, now.timeIntervalSince(start) < windowSeconds {
            next.count = state.count + 1
            next.windowStart = start
        } else {
            next.count = 1
            next.windowStart = now
        }
        next.lastRestartAt = now
        return next
    }
}

// ── 状态落盘 ─────────────────────────────────────────────────

enum AutoRestartStore {

    static let fileName = ".auto-restart.json"

    static func url(in root: URL) -> URL {
        root.appendingPathComponent(fileName)
    }

    static func read(in root: URL) -> AutoRestartState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url(in: root)),
              let decoded = try? decoder.decode(AutoRestartState.self, from: data) else {
            return AutoRestartState()
        }
        return decoded
    }

    @discardableResult
    static func write(_ state: AutoRestartState, in root: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let data = try encoder.encode(state)
            try data.write(to: url(in: root), options: .atomic)
            return true
        } catch {
            DiagLog.append("自动重启状态写入失败：\(error)")
            return false
        }
    }

    /// 启动时结算：
    ///   · 上次是自动重启拉起的 → 消费掉 pending，**继承**计数继续累计
    ///   · 用户自己打开的         → 删状态文件，一切归零（用户指定的「重置」）
    static func settleOnLaunch(in root: URL) -> AutoRestartState {
        var state = read(in: root)
        guard state.pending else {
            try? FileManager.default.removeItem(at: url(in: root))
            return AutoRestartState()
        }
        state.pending = false
        write(state, in: root)
        return state
    }
}

// ── 单实例锁 ─────────────────────────────────────────────────

enum SingleInstanceLock {

    /// 持有中的描述符（进程活多久就持有多久；不需要显式释放）
    private static var descriptor: Int32 = -1

    /// 拿数据目录的排他锁。false = 已经有一个实例在用同一个目录。
    ///
    /// 为什么必需：自动重启靠「旧进程退出 → helper 延迟拉起新进程」，
    /// 中间有几百毫秒的重叠窗口。没有锁的话两个实例会同时轮询剪贴板、
    /// 同时写 history.json（同一份文件互相覆盖，整段历史可能凭空少一批）。
    ///
    /// 重试是给自动重启让路的：新进程可能比旧进程退得早一步。
    static func acquire(in root: URL, retries: Int = 20, interval: TimeInterval = 0.15) -> Bool {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent(".instance.lock").path
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        // 连锁文件都打不开（权限/磁盘满）就别拦着应用启动，宁可冒双开的风险
        guard fd >= 0 else { return true }

        for attempt in 0..<retries {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                descriptor = fd
                return true
            }
            if attempt == 0 {
                DiagLog.append("已有实例持有数据目录锁，等待其退出…")
            }
            Thread.sleep(forTimeInterval: interval)
        }
        close(fd)
        return false
    }
}

// ── 拉起新实例 ───────────────────────────────────────────────

enum Relauncher {

    /// 起一个延迟 helper 来打开自己。
    ///
    /// 两个坑都要绕开：
    ///   · 不能直接 `open -a`——应用还在跑时它只会「激活」已有实例（实测 PID 不变），
    ///     根本不会起新的；
    ///   · 不能 exec `.app/Contents/MacOS/…`——绕过 LaunchServices 会让这个 bundle id
    ///     的菜单栏登记永久失效（家族里踩过）。
    ///
    /// helper 是 `sh -c "sleep; open"`：旧进程退出后它被 launchd 收养继续跑，
    /// 所以延迟这段时间足够旧进程走完落盘与状态项注销。
    @discardableResult
    static func schedule(after delay: TimeInterval = 1.2) -> Bool {
        let path = Bundle.main.bundlePath
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep \(delay); /usr/bin/open -a \(quoted)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return true
        } catch {
            DiagLog.append("自动重启：拉起 helper 失败 \(error)")
            return false
        }
    }
}
