import AppKit
import Foundation

// ============================================================
// BoxPaste 图标母版（2026-10-16 起改为用户提供的设计稿）
//
//   swift Tools/make-icon-source.swift
//   产出：Resources/icon-source.png（满幅方图，圆角与留白由
//   make-icon.swift 统一裁成 Apple 图标网格的 824/1024 圆角矩形）
//
// 历史说明：这份脚本以前用代码确定性绘制三版几何图标（A 剪贴板 /
// B 双层卡片 / C 开口盒），2026-10-16 用户提供了 "b" 字母设计稿后
// 改为固定输出 custom-icon-master.png。保留导入器
// Tools/import-custom-icon.swift（白底抠图 + 裁边 + 放大），
// 以后换设计稿：替换 Tools/custom-icon-raw.jpg 后重跑导入器即可。
//
// ⚠️ 不能"缺了才生成"——家族踩过：改了母版但旧 PNG 还在盘上，
// 新图标从没进过包。每次打包都从这里重写 icon-source.png。
// ============================================================

let projectRoot = URL(fileURLWithPath: CommandLine.arguments[0])
    .standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
let masterURL = projectRoot.appendingPathComponent("Resources/custom-icon-master.png")
let outURL = projectRoot.appendingPathComponent("Resources/icon-source.png")

guard let data = try? Data(contentsOf: masterURL) else {
    FileHandle.standardError.write(Data("缺少 Resources/custom-icon-master.png（图标母版）\n".utf8))
    exit(1)
}
try? FileManager.default.removeItem(at: outURL)
try! data.write(to: outURL)
