import AppKit
import ImageIO
import UniformTypeIdentifiers
import Vision

// ============================================================
// 图片工具：降采样加载 + OCR
//
// 历史教训：预览曾用 NSImage(contentsOf:) 在主线程同步解码整张大图
// （用户的全屏截图动辄几 MB），预览开着时每次重绘都重解一遍，
// 退出时叠加列表重排直接把面板卡死。原则：**大图永不上主线程解码**。
// ============================================================

enum ImageTools {

    struct LoadedImage {
        let image: NSImage
        let pixelWidth: Int
        let pixelHeight: Int
    }

    /// 后台线程用 ImageIO 降采样解码：内存里只有 maxPixel 以内的位图，
    /// 一张 2880×1864 的截图从 ~21MB 压到 1600px 档的 ~10MB 以内，
    /// 且跳过了原始尺寸的完整解码。
    static func downsampledImage(at url: URL, maxPixel: Int) -> LoadedImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        // 原始像素尺寸：读元数据，不解码位图
        // （kCGImageSourcePixelWidth 常量没导出进 Swift，用它的字符串值）
        var pixelWidth = 0, pixelHeight = 0
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            pixelWidth = props["PixelWidth" as CFString] as? Int ?? 0
            pixelHeight = props["PixelHeight" as CFString] as? Int ?? 0
        }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // 尊重 EXIF 方向
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return nil
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        return LoadedImage(image: image,
                           pixelWidth: pixelWidth > 0 ? pixelWidth : cgImage.width,
                           pixelHeight: pixelHeight > 0 ? pixelHeight : cgImage.height)
    }

    /// 全分辨率解码（离屏用：OCR 需要原始细节，别拿降采样图识别小字）。
    /// 只在后台线程调用。
    static func fullCGImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    struct ImageProbe {
        let pixelWidth: Int
        let pixelHeight: Int
        /// 最长边不超过 maxPixel 的缩略图（PNG 编码后）
        let thumbnailPNG: Data?
    }

    /// 从内存里的 PNG 数据取「原始像素尺寸 + 缩略图」，**不做整图解码**。
    /// 捕获路径专用：老的 NSBitmapImageRep(data:) 会把整张图解成位图
    /// （一张 5K 截图就是几十 MB），复制瞬间主线程要卡一下、峰值内存也白涨；
    /// ImageIO 只解缩略图那一档，尺寸从元数据里读。
    static func probe(png: Data, maxPixel: Int) -> ImageProbe? {
        guard let source = CGImageSourceCreateWithData(png as CFData,
                                                       [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        var pixelWidth = 0, pixelHeight = 0
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            pixelWidth = props["PixelWidth" as CFString] as? Int ?? 0
            pixelHeight = props["PixelHeight" as CFString] as? Int ?? 0
        }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
        ]
        var thumbnail: Data?
        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) {
            let rep = NSBitmapImageRep(cgImage: cgImage)
            thumbnail = rep.representation(using: .png, properties: [:])
        }
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        return ImageProbe(pixelWidth: pixelWidth, pixelHeight: pixelHeight, thumbnailPNG: thumbnail)
    }
}

// ============================================================
// OCR：Vision 框架文字识别（系统自带，支持中英文混排）
// ============================================================

enum OCRService {

    /// 识别图里的文字，按行拼接。抛错说明识别本身失败；
    /// 空串说明图里确实没有可识别的文字。
    static func recognizeText(in image: CGImage) async throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // 中英混排：截图里最常见的就是这两种
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try await handler.perform([request])
        let lines = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
        return lines.joined(separator: "\n")
    }
}
