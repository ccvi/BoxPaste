import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// ============================================================
// AppIcon 生成器：从 Resources/icon-source.png 生成 macOS 应用图标
//
//   swift Tools/make-icon.swift <输出目录>
//   产出 <输出目录>/AppIcon.iconset/ 全部规格 PNG + AppIcon-1024.png 母版
//   （build-app.sh 拿它跑 iconutil -c icns）
//
// macOS（Big Sur 起）的图标网格：1024 画布、内容是居中的 824×824
// 圆角矩形（圆角半径 ≈185.4，即边长的 22.5%），四周留透明边距——
// 系统在 Dock 和访达里展示时会自带光影，图标本身不该顶满画布。
//
// 源图（Tools/make-icon-source.swift 产出的那张）是满幅的，
// 所以这里把它裁进圆角矩形，尺寸不是正方形的部分按 aspectFill 居中。
//
// 这个脚本与具体应用无关：换应用只换 Resources/icon-source.png，
// 这里的圆角、留白、规格表都不用动。
// ============================================================

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("用法：swift make-icon.swift <输出目录>\n".utf8))
    exit(2)
}
let outputRoot = arguments[1]

// 源图：相对脚本自身定位（Tools/ 的上一级是项目根）
let scriptURL = URL(fileURLWithPath: arguments[0]).standardizedFileURL
let projectRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let sourceURL = projectRoot.appendingPathComponent("Resources/icon-source.png")

guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write(Data("读不到源图：\(sourceURL.path)\n".utf8))
    exit(1)
}

let canvasSide: CGFloat = 1024
let contentSide: CGFloat = 824
let cornerRadius: CGFloat = 185.4
let contentOrigin = (canvasSide - contentSide) / 2   // 100

func renderMaster() -> CGImage? {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil,
                              width: Int(canvasSide), height: Int(canvasSide),
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

    // 透明底，只画中间的圆角矩形
    ctx.clear(CGRect(x: 0, y: 0, width: canvasSide, height: canvasSide))
    let rect = CGRect(x: contentOrigin, y: contentOrigin, width: contentSide, height: contentSide)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
    ctx.clip()

    // aspectFill：源图是正方形时就是等比铺满；若日后换成非正方形，
    // 也是裁掉溢出的部分而不是把它压扁。
    let sourceAspect = CGFloat(image.width) / CGFloat(image.height)
    var drawRect = rect
    if sourceAspect > 1 {
        drawRect.size.width = contentSide * sourceAspect
        drawRect.origin.x = rect.midX - drawRect.width / 2
    } else if sourceAspect < 1 {
        drawRect.size.height = contentSide / sourceAspect
        drawRect.origin.y = rect.midY - drawRect.height / 2
    }
    ctx.draw(image, in: drawRect)
    return ctx.makeImage()
}

func pngData(of image: CGImage) -> Data {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return Data() }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    return data as Data
}

// ── 输出 ────────────────────────────────────────────────────

let iconsetURL = URL(fileURLWithPath: outputRoot).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

guard let master = renderMaster() else {
    FileHandle.standardError.write(Data("无法创建绘图上下文\n".utf8))
    exit(1)
}

let masterURL = iconsetURL.deletingLastPathComponent().appendingPathComponent("AppIcon-1024.png")
if let dest = CGImageDestinationCreateWithURL(masterURL as CFURL, UTType.png.identifier as CFString, 1, nil) {
    CGImageDestinationAddImage(dest, master, nil)
    CGImageDestinationFinalize(dest)
}

// iconset 命名规则由 iconutil 规定，写错一个名字它只会静默少一个尺寸。
let specs: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2)
]
for spec in specs {
    let pixels = spec.points * spec.scale
    let name = spec.scale == 1 ? "icon_\(spec.points)x\(spec.points).png"
                                : "icon_\(spec.points)x\(spec.points)@2x.png"
    let url = iconsetURL.appendingPathComponent(name)
    // 用 CGImageSource 的缩略图接口做带插值的高质量缩放，
    // 小尺寸下比让 CGContext 直接重绘更干净。
    guard let source = CGImageSourceCreateWithData(
        pngData(of: master) as CFData, nil),
        let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    else { continue }
    if let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
        CGImageDestinationAddImage(dest, scaled, nil)
        CGImageDestinationFinalize(dest)
    }
}

print("已生成 \(specs.count) 个规格 → \(iconsetURL.path)")
