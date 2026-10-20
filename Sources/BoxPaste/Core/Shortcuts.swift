import AppKit
import Carbon.HIToolbox

// ============================================================
// 快捷键：键位描述 + 动作表
//
// 两套机制，别混：
//   · 全局键（呼出面板 / 打开设置）走 Carbon RegisterEventHotKey —— 系统级注册，
//     不需要辅助功能授权，也不需要应用在前台。
//   · 面板内键（粘贴 / 预览 / 置顶 / 删除 / 复制）走面板自己的事件监听，
//     只在面板处于 key 状态时生效。
// 两者共用 KeySpec，设置页里录一次键位即可。
// ============================================================

/// 一个键位。`label` 在录制时抓下来存着——不然显示键位就得自己维护一张
/// keyCode → 名字的映射表，而键盘布局和第三方键盘远不止一张表能覆盖。
struct KeySpec: Codable, Equatable, Hashable {
    var keyCode: UInt16
    var command: Bool = false
    var shift: Bool = false
    var option: Bool = false
    var control: Bool = false
    var label: String = ""

    var display: String {
        var text = ""
        if control { text += "⌃" }
        if option { text += "⌥" }
        if shift { text += "⇧" }
        if command { text += "⌘" }
        return text + (label.isEmpty ? "键码 \(keyCode)" : label)
    }

    /// 只比较四个主修饰键：系统会给 Return / 方向键带上 .function，
    /// 把整个 modifierFlags 拿来比会让这些键永远匹配不上。
    func matches(_ event: NSEvent) -> Bool {
        guard event.keyCode == keyCode else { return false }
        let flags = event.modifierFlags
        return flags.contains(.command) == command
            && flags.contains(.shift) == shift
            && flags.contains(.option) == option
            && flags.contains(.control) == control
    }

    /// Carbon 用的修饰键掩码
    var carbonModifiers: UInt32 {
        var mask: UInt32 = 0
        if command { mask |= UInt32(cmdKey) }
        if shift { mask |= UInt32(shiftKey) }
        if option { mask |= UInt32(optionKey) }
        if control { mask |= UInt32(controlKey) }
        return mask
    }

    /// 全局热键至少得带一个修饰键，且不能只有 shift —— 只有 shift 的组合
    /// 会跟正常打字抢键（比如 ⇧A），注册上去是把键盘变成砖。
    var isUsableAsGlobal: Bool {
        command || option || control
    }

    static func from(_ event: NSEvent) -> KeySpec {
        KeySpec(keyCode: event.keyCode,
                command: event.modifierFlags.contains(.command),
                shift: event.modifierFlags.contains(.shift),
                option: event.modifierFlags.contains(.option),
                control: event.modifierFlags.contains(.control),
                label: label(for: event))
    }

    static func label(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: return "↩"
        case kVK_Space:                        return "空格"
        case kVK_Delete:                       return "⌫"
        case kVK_ForwardDelete:                return "⌦"
        case kVK_Escape:                       return "⎋"
        case kVK_Tab:                          return "⇥"
        case kVK_LeftArrow:                    return "←"
        case kVK_RightArrow:                   return "→"
        case kVK_UpArrow:                      return "↑"
        case kVK_DownArrow:                    return "↓"
        case kVK_Home:                         return "↖"
        case kVK_End:                          return "↘"
        case kVK_PageUp:                       return "⇞"
        case kVK_PageDown:                     return "⇟"
        default:
            if let characters = event.charactersIgnoringModifiers, !characters.isEmpty {
                return characters.uppercased()
            }
            return "键码 \(event.keyCode)"
        }
    }
}

/// 可配置的动作。rawValue 会写进设置文件，改名等于让用户的旧配置失效，
/// 所以这些字符串当成接口看待，不要随便动。
enum ShortcutAction: String, Codable, CaseIterable, Identifiable {
    case recallPanel
    case openSettings
    case paste
    case preview
    case pin
    case delete
    case copy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recallPanel:  return "呼出面板"
        case .openSettings: return "打开设置"
        case .paste:        return "粘贴选中项"
        case .preview:      return "预览选中项"
        case .pin:          return "置顶 / 取消置顶"
        case .delete:       return "删除选中项"
        case .copy:         return "复制到剪贴板（不粘贴）"
        }
    }

    var note: String {
        switch self {
        case .recallPanel:  return "全局生效，任何应用里都能按"
        case .openSettings: return "全局生效"
        case .paste:        return "面板内：写回剪贴板并按需自动粘贴"
        case .preview:      return "面板内：空格键预览，可看 HEX 色块与全文"
        case .pin:          return "面板内：置顶的条目不会被条数上限淘汰"
        case .delete:       return "面板内"
        case .copy:         return "面板内：只回写剪贴板，面板不关闭"
        }
    }

    var isGlobal: Bool {
        self == .recallPanel || self == .openSettings
    }

    var symbol: String {
        switch self {
        case .recallPanel:  return "command"
        case .openSettings: return "gearshape"
        case .paste:        return "arrow.down.doc"
        case .preview:      return "eye"
        case .pin:          return "pin"
        case .delete:       return "trash"
        case .copy:         return "doc.on.doc"
        }
    }

    var defaultSpec: KeySpec {
        switch self {
        case .recallPanel:  return KeySpec(keyCode: UInt16(kVK_ANSI_V), command: true, shift: true, label: "V")
        case .openSettings: return KeySpec(keyCode: UInt16(kVK_ANSI_Comma), command: true, label: ",")
        case .paste:        return KeySpec(keyCode: UInt16(kVK_Return), label: "↩")
        case .preview:      return KeySpec(keyCode: UInt16(kVK_Space), label: "空格")
        case .pin:          return KeySpec(keyCode: UInt16(kVK_ANSI_P), command: true, label: "P")
        case .delete:       return KeySpec(keyCode: UInt16(kVK_Delete), command: true, label: "⌫")
        case .copy:         return KeySpec(keyCode: UInt16(kVK_ANSI_C), command: true, label: "C")
        }
    }

    /// 视图切换、选择移动这类是"肌肉记忆型"按键，不做成可配置项，
    /// 但要在快捷键帮助里列出来，否则用户不知道全键盘怎么操作。
    static let fixedShortcuts: [(keys: String, action: String)] = [
        ("↑ ↓", "上下选择（← → 在网格视图里左右移动）"),
        ("Home / End", "跳到第一项 / 最后一项"),
        ("⌘1 / ⌘2 / ⌘3", "网格 / 简洁列表 / 丰富列表"),
        ("⌘F", "聚焦搜索框（只有聚焦后空格才算搜索词里的字符）"),
        ("⌘L", "清空搜索"),
        ("Tab", "切换分类"),
        ("Esc", "关预览 → 清搜索 → 关面板"),
        ("⌘Z", "撤销上一次删除"),
    ]
}
