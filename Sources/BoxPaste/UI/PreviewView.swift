import AppKit
import SwiftUI

// ============================================================
// 空格预览（独立窗口里的那层卡片）
//
// 按内容类型给最合适的"看"法：
//   图像 → 大图；文本 → 全文可选中；链接 → 域名 + 完整地址；
//   颜色 → 大色块 + HEX/RGB/HSL 三种写法（都能一键复制）；
//   文件 → 逐个文件的大小与路径。
// 窗口本身由 PreviewWindowController 管（800×500、屏幕居中、置顶）；
// 关闭方式：再按空格 / Esc / 右上角 ×。
// ============================================================

struct PreviewCard: View {
    @EnvironmentObject var model: AppModel
    let item: ClipItem

    // 图片异步加载：NSImage(contentsOf:) 主线程同步解码大图，
    // 预览开着时每次重绘都重解一遍，退出时叠加列表重排直接卡死（用户实测）。
    // 降采样到 1200px：预览区宽不到 500pt，retina 2x 只要 1000px，
    // 1200 足够清晰又比 1600 少占一半位图内存（1600×1000×4 约 6.4MB）。
    @State private var previewImage: NSImage?
    @State private var previewPixelSize: (Int, Int)?
    @State private var previewLoadFailed = false
    // 富文本条目的 RTF 渲染结果（后台解析，主线程只收成品）
    @State private var richPreview: NSAttributedString?
    // 译文（nil = 正在看原文）。和原文分开存：翻译是"看一眼"的动作，
    // 覆盖掉原文就没法对照，切回原文也只能重开预览。
    @State private var translatedText: String?
    // 勾了「保留原文」时才有：逐句对照用的"一行原文 + 一行译文"。
    // 和 translatedText 并存而不是二选一 —— 字数统计、整段模式复制还是用整段那份。
    @State private var translatedPairs: [BilingualPair]?
    // 对照开关：记住上次的选择（使用习惯，每次重开预览都要重勾很烦）
    @State private var keepOriginal = TranslateTarget.rememberedKeepOriginal()
    // 目标语言：没记住过就按内容猜（中文内容 → 英文），避免同语种翻译被框架拒掉
    @State private var translateTarget: TranslateTarget = .chinese

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollView {
                content
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().opacity(0.5)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 窗口是透明无边框的，圆角与背景全靠这层卡片自己画。
        // 底色必须是**不透明**的：预览窗居中后会正好压在面板上，用毛玻璃的话
        // 面板的选中色、行文字会透过来看得一清二楚（实测过，像没擦干净的玻璃）。
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        }
    }

    // ── 头部 ─────────────────────────────────────────────────

    private var header: some View {
        HStack(spacing: 8) {
            SourceIcon(item: item).frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.kind.title).font(.system(size: 12, weight: .medium))
                HStack(spacing: 6) {
                    if let app = item.sourceAppName {
                        Text(app).font(.system(size: 10))
                    }
                    Text(Support.timeLabel(item.createdAt)).font(.system(size: 10))
                }
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Button {
                // closePreview() 而不是 `isPreviewing = false`：值已经是 false 时
                // 赋值不会触发 didSet，窗口就永远收不掉（见 AppModel.closePreview）
                model.closePreview()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
                    // 图标本身只有 14pt，点击热区太小 —— 稍微偏一点就"点了没反应"。
                    // 撑到 24×24 并显式给命中形状，手指/触控板都不用瞄。
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("关闭预览（空格 / Esc）")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // ── 内容 ─────────────────────────────────────────────────

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .image: imageContent
        case .link:  linkContent
        case .color: colorContent
        case .file:  fileContent
        case .text:  textContent
        }
    }

    @ViewBuilder
    private var imageContent: some View {
        Group {
            if let image = previewImage {
                VStack(alignment: .leading, spacing: 8) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    if let size = previewPixelSize {
                        Text("\(size.0) × \(size.1) · \(Support.humanByteCount(item.byteCount))")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            } else if previewLoadFailed {
                Text("图片文件已不存在").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("载入中…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 30)
                .frame(maxWidth: .infinity)
            }
        }
        .task(id: item.id) {
            // 换了条目（预览里按上下键）或重新打开预览都会重新走一遍
            previewImage = nil
            previewPixelSize = nil
            previewLoadFailed = false
            guard let url = model.store.imageURL(for: item) else {
                previewLoadFailed = true
                return
            }
            let loaded = await Task.detached(priority: .userInitiated) {
                ImageTools.downsampledImage(at: url, maxPixel: 1200)
            }.value
            guard !Task.isCancelled else { return }
            if let loaded {
                previewImage = loaded.image
                previewPixelSize = (loaded.pixelWidth, loaded.pixelHeight)
            } else {
                previewLoadFailed = true
            }
        }
    }

    @ViewBuilder
    private var textContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if item.rtfBlobName != nil {
                richTextContent
            } else {
                plainTextContent
            }
            Text("\(item.text.count) 字符 · \(item.text.split(separator: "\n", omittingEmptySubsequences: false).count) 行 · \(Support.humanByteCount(item.byteCount))")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .task(id: item.id) {
            // 换了条目或重开预览都重新解析一遍 RTF
            richPreview = nil
            // 译文只对当前这一条有效：换了条目还挂着上一条的译文是最典型的错位
            translatedText = nil
            translatedPairs = nil
            translateTarget = TranslateTarget.initial(for: item.text)
            guard let name = item.rtfBlobName,
                  let data = try? Data(contentsOf: model.store.blobURL(named: name)) else { return }
            let loaded = await Task.detached(priority: .userInitiated) { () -> NSAttributedString? in
                NSAttributedString(rtf: data, documentAttributes: nil)
            }.value
            guard !Task.isCancelled else { return }
            richPreview = loaded
        }
    }

    /// RTF 渲染失败/没有存档时的兜底：退回纯文本，预览不该开天窗。
    /// 超长富文本也走这条：排版成本随字符数线性增长，宁可显示截断的纯文本，
    /// 也不让主线程去排 40 万字符。
    @ViewBuilder
    private var richTextContent: some View {
        if let rich = richPreview,
           rich.length <= Self.previewCharLimit,
           let converted = try? AttributedString(Self.resizedRichText(rich), including: \.appKit) {
            Text(converted)
                .lineSpacing(Self.bodyLineSpacing)   // 富文本也走视图行距，段落样式那条路无效（见 resizedRichText）
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            plainTextContent
        }
    }

    /// 富文本正文统一到 `bodyFontSize`。
    ///
    /// RTF 里带的是复制时那一刻的字号（12/13pt 混着），不覆盖就会出现
    /// "纯文本 14pt、富文本 12pt"的割裂 —— 用户看到的预览忽大忽小。
    /// 只换字号，粗体/斜体/颜色/链接/对齐/缩进等属性原样保留
    /// （用 NSFontManager.convert 保住字族与 traits）。
    ///
    /// 🔴 行距**不在这里**做。实测（2026-11-11）：把 `NSParagraphStyle.lineSpacing = 4`
    /// 写进 attributed string，SwiftUI 的 `Text` 完全不采纳 —— 三行文本量高度，
    /// 段落样式填 4 和填 0 都是 51.0pt；改用视图上的 `.lineSpacing(4)` 才是 59.0pt。
    /// 所以富文本和纯文本一样走 `.lineSpacing`（见 richTextContent），
    /// 别在这里改段落样式：既没用，还会把源文档的段落样式弄脏。
    static func resizedRichText(_ rich: NSAttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: rich)
        let full = NSRange(location: 0, length: mutable.length)
        var missing: [NSRange] = []
        mutable.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
            if let font = value as? NSFont {
                mutable.addAttribute(.font,
                                     value: NSFontManager.shared.convert(font, toSize: bodyFontSize),
                                     range: range)
            } else {
                missing.append(range)   // 没带字体的段落：补一个系统正文字体
            }
        }
        for range in missing {
            mutable.addAttribute(.font, value: NSFont.systemFont(ofSize: bodyFontSize), range: range)
        }
        return mutable
    }

    private var plainTextContent: some View {
        let capped = Self.cappedPreviewText(item.text)
        // 有译文就显示译文，否则原文。正文尺寸/截断提示都沿用原来那套。
        let body = translatedText ?? capped.body
        // 对照模式：只有勾了「保留原文」**且**手上真有逐句数据时才走双行排版。
        // 缺一半（刚勾上还没重译）就老老实实显示整段译文，不留一个空的对照框。
        let pairs = shownPairs
        return VStack(alignment: .leading, spacing: 6) {
            // 提示放最前面：正文有 200 行高，写在末尾等于让人滚到底才看见
            if let note = capped.note {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 标注当前是译文/对照：不标的话用户分不清"翻失败了没变"和"这就是译文"
            if translatedText != nil {
                HStack(spacing: 4) {
                    Image(systemName: "character.bubble").font(.system(size: 9))
                    Text(pairs == nil ? "译文 · \(translateTarget.title)"
                                      : "对照 · 原文 + \(translateTarget.title)")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(.secondary)
            }

            if let pairs {
                bilingualBody(pairs)
            } else {
                // 文本预览开选择：用户经常需要在预览里挑一段再复制
                Text(body)
                    .font(.system(size: Self.bodyFontSize))
                    .lineSpacing(Self.bodyLineSpacing)
                    .textSelection(.enabled)
                    // fixedSize 让文本按内容撑高（不然会被 ScrollView 的提案压扁），
                    // 也正因如此，内容长度必须在上游截断，否则就是整篇一次排版。
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// 当前真正在渲染的逐句对照数据（nil = 没走对照排版）。
    /// 视图和「复制」共用这一个判据：两处各写一份条件，早晚会出现
    /// "屏幕上是双语的、复制出来只有译文"这种错位。
    private var shownPairs: [BilingualPair]? {
        (translatedText != nil && keepOriginal) ? translatedPairs : nil
    }

    /// 「复制」到底复制什么，写在 help 里（按钮文案固定叫「复制」，不随状态变）
    private var copyHelp: String {
        if shownPairs != nil { return "复制屏幕上看到的全部内容（原文 + 译文）" }
        if translatedText != nil { return "复制译文" }
        return "复制这条记录"
    }

    /// 逐句对照：一句原文（弱化成次要色）在上，紧跟它自己的译文（正文色）在下。
    ///
    /// 用 `pair.id`（行号）当 ForEach 的 id：空行和重复行都会撞原文，撞了会画错或直接崩。
    /// 行距沿用一个常量，但句与句之间再留 9pt —— 只有 4pt 的话，上下两行的间距
    /// 和句内行距一样，"哪句是新的"就看不出来了。
    private func bilingualBody(_ pairs: [BilingualPair]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(pairs) { pair in
                VStack(alignment: .leading, spacing: 1) {
                    if !pair.original.isEmpty {
                        Text(pair.original)
                            .font(.system(size: Self.bodyFontSize))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let translation = pair.translation, !translation.isEmpty {
                        Text(translation)
                            .font(.system(size: Self.bodyFontSize))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .lineSpacing(Self.bodyLineSpacing)
    }

    /// 预览正文的字号（用户 2026-11-11 定：12 → 13 → 14，纯文本 / 译文 / 富文本 / 链接地址统一）
    static let bodyFontSize: CGFloat = 14

    /// 预览正文额外加的行距（px）。
    ///
    /// 14pt 系统字体自带的单倍行高约 17pt，长段落读起来挤成一坨（用户要求"行高加大一点"）。
    /// 4pt 后行距约 21pt，是"看着舒展但没散架"的量；纯文本 / 译文 / 富文本 / 链接地址
    /// 必须用同一个值，否则切换"原文 ↔ 译文"或换条目时行距会跳一下。
    static let bodyLineSpacing: CGFloat = 4

    // ── 长文本保护 ───────────────────────────────────────────

    // SwiftUI 的 Text 是整体排版：`.fixedSize(vertical: true)` 会一次量出全部行的
    // 高度。实测 10000 行 / 40 万字符的纯文本，主线程卡在
    // ViewLayoutEngine.sizeThatFits 里 60 秒以上、footprint 冲到 101MB，
    // 最终被系统按内存杀掉（exit 137）。预览只是"看一眼"，所以超过阈值就截断：
    // 排版高度恒定，再长的内容也是秒开，完整内容照样能粘贴/复制。
    private static let previewLineLimit = 200
    private static let previewCharLimit = 20_000

    struct CappedText {
        let body: String
        let note: String?
    }

    static func cappedPreviewText(_ text: String) -> CappedText {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > previewLineLimit || text.count > previewCharLimit else {
            return CappedText(body: text, note: nil)
        }
        var kept: [String] = []
        var used = 0
        for line in lines.prefix(previewLineLimit) {
            let room = previewCharLimit - used
            if room <= 0 { break }
            // 单行超长（压缩包 base64、整篇没换行的 JSON）也要按字符数切
            if line.count > room {
                kept.append(String(line.prefix(room)))
                break
            }
            kept.append(String(line))
            used += line.count + 1        // +1：换行符自己也要占位
        }
        let note = "内容过长，预览只显示前 \(kept.count) 行（共 \(lines.count) 行 · \(text.count) 字符）。"
            + "完整内容请直接粘贴，或点下方「复制」。"
        return CappedText(body: kept.joined(separator: "\n"), note: note)
    }

    @ViewBuilder
    private var linkContent: some View {
        if let url = URL(string: item.text) {
            VStack(alignment: .leading, spacing: 10) {
                if let host = url.host {
                    HStack(spacing: 6) {
                        Image(systemName: "globe").font(.system(size: 13))
                        Text(host).font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(Color(nsColor: .systemBlue))
                }
                Text(item.text)
                    .font(.system(size: Self.bodyFontSize, design: .monospaced))
                    .lineSpacing(Self.bodyLineSpacing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("在浏览器中打开", systemImage: "arrow.up.right.square")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        } else {
            textContent
        }
    }

    @ViewBuilder
    private var colorContent: some View {
        if let color = ContentClassifier.parseColor(item.text) {
            VStack(alignment: .leading, spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: color.platformColor))
                    .frame(height: 130)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    }

                VStack(alignment: .leading, spacing: 6) {
                    ColorValueRow(label: "HEX", value: color.hex) { copy(color.hex) }
                    ColorValueRow(label: "RGB", value: color.rgbString) { copy(color.rgbString) }
                    ColorValueRow(label: "HSL", value: color.hslString) { copy(color.hslString) }
                    ColorValueRow(label: "原始", value: item.text) { copy(item.text) }
                }
            }
        } else {
            textContent
        }
    }

    @ViewBuilder
    private var fileContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(item.fileURLs, id: \.self) { url in
                HStack(spacing: 8) {
                    Image(nsImage: AppIcons.icon(forFile: url.path))
                        .resizable()
                        .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(url.lastPathComponent).font(.system(size: 12))
                        Text(Support.prettyPath(url))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    Text(fileSize(of: url))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // ── 底部操作 ─────────────────────────────────────────────

    private var footer: some View {
        HStack(spacing: 8) {
            Button("粘贴") { model.pasteSelected() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            // 一律叫「复制」：按钮文案跟着状态改，用户反而要猜"这一下复制的是什么"。
            // 复制的语义固定成**屏幕上看到的那份内容**：
            //   · 看过翻译了 → 对照模式复制"原文 + 译文"，整段模式复制译文；
            //   · 没翻译 → 复制这条记录本身。
            // 具体复制什么写进 help，不靠按钮文案去区分。
            Button("复制") {
                if let pairs = shownPairs {
                    // 对照模式：原文 + 译文都带上（用户明确要求"复制所有的文本内容"）
                    copy(TranslateTarget.joinedBilingual(pairs))
                } else if let translated = translatedText {
                    copy(translated)
                } else {
                    model.copySelectedToList()
                }
            }
            .controlSize(.small)
            .help(copyHelp)
            Button(item.pinned ? "取消置顶" : "置顶") { model.togglePinSelected() }
                .controlSize(.small)
            // 翻译只对纯文本条目出现：图片/文件/颜色没有可翻的句子，
            // 留个翻不动的按钮比没有更糟。macOS 14 没有 Translation 框架，同样不显示。
            if item.kind == .text {
                translateBar
            }
            Spacer(minLength: 0)
            Button("删除") { model.closePreview(); model.deleteSelected() }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var translateBar: some View {
        if #available(macOS 15.0, *) {
            // 翻的是"预览里看到的这段"（已截断），不是全文：
            // 显示与翻译必须同一份内容，否则译文比原文长一截，用户会以为串了。
            TranslateBar(sourceText: Self.cappedPreviewText(item.text).body,
                         translated: $translatedText,
                         target: $translateTarget,
                         keepOriginal: $keepOriginal,
                         pairs: $translatedPairs)
        }
    }

    // ── 小工具 ───────────────────────────────────────────────

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        model.watcher.ignore(changeCount: pasteboard.changeCount)
        model.showHint("已复制 \(text)")
    }

    private func fileSize(of url: URL) -> String {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int else {
            return "—"
        }
        return Support.humanByteCount(size)
    }
}

struct ColorValueRow: View {
    let label: String
    let value: String
    let copy: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 30, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button {
                copy()
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("复制 \(label)")   // 同 RowActionButton：省 HelpView 状态机
        }
    }
}
