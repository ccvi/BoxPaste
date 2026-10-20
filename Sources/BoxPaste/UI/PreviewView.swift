import AppKit
import SwiftUI

// ============================================================
// 空格预览
//
// 覆盖在面板之上的一层，按内容类型给最合适的"看"法：
//   图像 → 大图；文本 → 全文可选中；链接 → 域名 + 完整地址；
//   颜色 → 大色块 + HEX/RGB/HSL 三种写法（都能一键复制）；
//   文件 → 逐个文件的大小与路径。
// 关闭方式：再按空格 / Esc / 点空白处。
// ============================================================

struct PreviewOverlayView: View {
    @EnvironmentObject var model: AppModel
    let item: ClipItem

    // 图片异步加载：NSImage(contentsOf:) 主线程同步解码大图，
    // 预览开着时每次重绘都重解一遍，退出时叠加列表重排直接卡死（用户实测）。
    // 降采样到 1600px：预览区宽不到 500pt，retina 2x 也足够清晰。
    @State private var previewImage: NSImage?
    @State private var previewPixelSize: (Int, Int)?
    @State private var previewLoadFailed = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .onTapGesture { model.isPreviewing = false }

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
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            }
            .padding(14)
        }
        .transition(.opacity)
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
                model.isPreviewing = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
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
                ImageTools.downsampledImage(at: url, maxPixel: 1600)
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
            // 文本预览开选择：用户经常需要在预览里挑一段再复制
            Text(item.text)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(item.text.count) 字符 · \(item.text.split(separator: "\n", omittingEmptySubsequences: false).count) 行 · \(Support.humanByteCount(item.byteCount))")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
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
                    .font(.system(size: 12, design: .monospaced))
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
            Button("复制") { model.copySelectedToList() }
                .controlSize(.small)
            Button(item.pinned ? "取消置顶" : "置顶") { model.togglePinSelected() }
                .controlSize(.small)
            Spacer(minLength: 0)
            Button("删除") { model.isPreviewing = false; model.deleteSelected() }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
