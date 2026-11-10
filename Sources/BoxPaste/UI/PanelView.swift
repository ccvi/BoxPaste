import AppKit
import SwiftUI
import UniformTypeIdentifiers

// ============================================================
// 面板主界面：顶部搜索 + 分类，中部三种视图，底部状态条
//
// 交互由 PanelController 的键盘监听驱动（见 WindowControllers.swift），
// 这里只负责"长什么样"和鼠标操作（点选、双击粘贴、拖出、拖入、右键菜单）。
// ============================================================

struct PanelRootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            WindowDragArea()
                .frame(height: 8)

            HeaderBar()
            CategoryTabs()

            if !model.multiSelection.isEmpty {
                MultiSelectBar()
            }

            if let hint = model.hint {
                HintBar(text: hint)
            }

            Divider().opacity(0.6)

            ContentArea()

            Divider().opacity(0.6)
            FooterBar()
        }
        // 材质底 + 圆角：窗口本身是透明的无边框窗口，圆角与毛玻璃都靠这里。
        // 用 thick 而不是 regular：这是信息密度高的列表，压在亮色壁纸上时
        // regular 的透光量会让正文对比度明显不够（实测过一版）。
        .background(.thickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelCorner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.panelCorner, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        }
        .overlay {
            if model.showsShortcutHelp {
                ShortcutHelpOverlay()
            }
        }
        .frame(minWidth: 340, minHeight: 380)
    }
}

// ── 顶部拖拽区 ───────────────────────────────────────────────

/// 无边框窗口默认不能拖。给顶部留一条 8pt 的透明带做拖拽手柄，
/// 顺带让内容不至于顶到圆角上。
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DraggableView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DraggableView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

// ── 头部：搜索 + 视图切换 ────────────────────────────────────

struct HeaderBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            PinButton()
            SearchField()
            ViewModeSwitch()
            Button {
                model.onRequestShowSettings?()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("设置")
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }
}

/// 置顶：打开后点别处面板不会自动收起（失焦收起的判断在 PanelController 里）。
/// 放在搜索框左边，和参考的剪贴板工具一致——"固定这块面板"是呼出后的第一个决定。
struct PinButton: View {
    @EnvironmentObject var model: AppModel
    @State private var hovering = false

    private var isOn: Bool { model.prefs.value.alwaysOnTop }

    var body: some View {
        Button {
            model.toggleAlwaysOnTop()
        } label: {
            Image(systemName: isOn ? "pin.fill" : "pin")
                .font(.system(size: 13))
                // 斜着的图钉，和参考图一致；点了之后转正，一眼能看出状态
                .rotationEffect(.degrees(isOn ? 0 : -35))
                .foregroundStyle(isOn ? Color.accentColor : Color.primary)
                .frame(width: 26, height: 26)
                .background(isOn ? Theme.selectionFill : (hovering ? Theme.hoverFill : .clear),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: isOn)
        .help(isOn ? "取消置顶" : "置顶：点别处不自动收起")
    }
}

struct SearchField: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            ZStack(alignment: .leading) {
                if model.query.isEmpty {
                    Text("输入开始搜索…")
                        .foregroundStyle(.tertiary)
                }
                if model.searchFocused {
                    TextField("", text: $model.query)
                        .textFieldStyle(.plain)
                        .focused($isFieldFocused)
                } else {
                    // 未聚焦时用静态文本显示查询：字符由键盘监听直接喂进 model.query，
                    // 这样空格键才能留给"预览"而不是插进搜索词里。
                    Text(model.query)
                }
            }
            .font(.system(size: 13))
            .frame(maxWidth: .infinity, alignment: .leading)

            if !model.query.isEmpty {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清空搜索（⌘L）")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            if model.searchFocused {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.selectionStroke.opacity(0.6), lineWidth: 1.5)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.searchFocused = true }
        .onChange(of: model.searchFocused) { _, focused in
            isFieldFocused = focused
        }
        .onChange(of: isFieldFocused) { _, focused in
            if !focused && model.searchFocused { model.searchFocused = false }
        }
    }
}

struct ViewModeSwitch: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 2) {
            // 显示顺序：丰富 → 简洁 → 网格（用户指定；与 allCases 的枚举序无关）
            ForEach([ViewMode.rich, .compact, .grid]) { mode in
                Button {
                    model.setViewMode(mode)
                } label: {
                    Image(systemName: mode.symbol)
                        .font(.system(size: 12))
                        .frame(width: 26, height: 26)
                        .background(model.viewMode == mode ? Color.primary.opacity(0.10) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("\(mode.title)（⌥\(mode.shortcutDigit)）")
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// ── 分类标签 ─────────────────────────────────────────────────

struct CategoryTabs: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                CategoryChip(title: "全部", symbol: "tray.full", isSelected: model.selectedCategoryID == nil) {
                    model.selectedCategoryID = nil
                }
                ForEach(model.prefs.value.categories) { category in
                    CategoryChip(title: category.name,
                                 symbol: category.symbol,
                                 isSelected: model.selectedCategoryID == category.id) {
                        model.selectedCategoryID = category.id
                    }
                }
                Button {
                    model.onRequestShowSettings?()
                    model.showHint("在「设置 → 分类」里新建分类")
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("新建分类（设置 → 分类）")
            }
            .padding(.horizontal, Theme.contentPadding)
            .padding(.bottom, 8)
        }
    }
}

struct CategoryChip: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10))
                Text(title).font(.system(size: 12))
            }
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(isSelected ? Theme.selectionFill : Color.primary.opacity(0.05),
                        in: Capsule())
            .overlay {
                if isSelected {
                    Capsule().strokeBorder(Theme.selectionStroke.opacity(0.55), lineWidth: 1)
                }
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

struct HintBar: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle.fill").font(.system(size: 11))
            Text(text).font(.system(size: 11)).lineLimit(2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, Theme.contentPadding)
        .padding(.bottom, 8)
    }
}

// ── 多选批量操作条 ───────────────────────────────────────────

/// ⌘单击勾选条目后出现：批量删除 / 批量收藏 / 取消。
/// 放在分类标签下面、列表上面——操作对象就是下面的列表，位置要贴着。
struct MultiSelectBar: View {
    @EnvironmentObject var model: AppModel

    /// 是否已处于全选状态：勾选框「打勾」的依据。
    /// 数量相等才算——条目增删后多选集合与可见列表重新对齐。
    private var isAllSelected: Bool {
        let visible = model.flatVisibleItems
        return !visible.isEmpty && model.multiSelection.count == visible.count
    }

    var body: some View {
        HStack(spacing: 10) {
            // 全选勾选框（用户指定）：勾上=全选当前列表，取消=清空选择。
            // 和「已选 N 项」并排，是这根工具条的总开关。
            Button {
                if isAllSelected {
                    model.clearMultiSelection()
                } else {
                    model.selectAllForMultiSelection()
                }
            } label: {
                Image(systemName: isAllSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(isAllSelected ? Color.accentColor : Color.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isAllSelected ? "取消全选" : "全选")

            Text("已选 \(model.multiSelection.count) 项")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
            Spacer(minLength: 8)
            // 主操作放最左：多选的目的一半就是"把这几条按顺序粘出去"。
            // 只在这里给按钮，不做 ⌘↩ 之类的新键位——多选状态下误按回车
            // 会把一整批内容灌进目标文档，撤销起来比删除麻烦得多。
            Button("粘贴") { model.pasteMultiSelection() }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .help("按列表顺序逐条粘贴选中的 \(model.multiSelection.count) 项")
            Button("收藏") { model.addMultiSelectionToFavorites() }
                .controlSize(.small)
                .buttonStyle(.bordered)
            Button("删除") { model.deleteMultiSelection() }
                .controlSize(.small)
                .buttonStyle(.bordered)
            Button("取消") { model.clearMultiSelection() }
                .controlSize(.small)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.bottom, 8)
    }
}

// ── 内容区 ───────────────────────────────────────────────────

struct ContentArea: View {
    @EnvironmentObject var model: AppModel
    @State private var isDropTargeted = false

    var body: some View {
        Group {
            if model.flatVisibleItems.isEmpty {
                EmptyStateView()
            } else {
                switch model.viewMode {
                case .grid:    GridContent()
                case .compact: CompactListContent()
                case .rich:    RichListContent()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.selectionStroke, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                    .padding(6)
                    .overlay {
                        Text("松开即加入历史")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.regularMaterial, in: Capsule())
                    }
            }
        }
        // 拖入收集：文件 / 图片 / 文本都收
        .onDrop(of: [UTType.fileURL.identifier,
                     UTType.image.identifier,
                     UTType.png.identifier,
                     UTType.tiff.identifier,
                     UTType.utf8PlainText.identifier,
                     UTType.url.identifier],
                isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { model.collect(files: [url]) }
            }
            return true
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data else { return }
                DispatchQueue.main.async { model.collect(imageData: data) }
            }
            return true
        }

        if provider.canLoadObject(ofClass: NSString.self) {
            _ = provider.loadObject(ofClass: NSString.self) { value, _ in
                guard let text = value as? String else { return }
                DispatchQueue.main.async { model.collect(text: text) }
            }
            return true
        }
        return false
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: model.items.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(model.items.isEmpty ? "还没有历史" : "没有匹配的内容")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            if model.items.isEmpty {
                Text("复制任意内容就会出现在这里")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// ── 网格视图 ─────────────────────────────────────────────────

struct GridContent: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GeometryReader { geometry in
            let columns = max(1, Int((geometry.size.width - Theme.contentPadding * 2 + 8) / (Theme.gridMinCard + 8)))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.sections) { section in
                            if !section.title.isEmpty {
                                SectionHeader(title: section.title, count: section.items.count)
                            }
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns),
                                      spacing: 8) {
                                ForEach(section.items) { item in
                                    GridCard(item: item)
                                        .id(item.id)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Theme.contentPadding)
                    .padding(.vertical, 10)
                }
                .scrollContentBackground(.hidden)
                .onChange(of: model.selectedID) { _, id in
                    // 只为键盘导航滚动：鼠标点选时目标就在光标底下，
                    // 再 scrollTo(.center) 会把列表抽走一截，第二下点歪（用户实测）。
                    defer { model.pendingScrollReveal = false }
                    guard let id, model.pendingScrollReveal else { return }
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
                }
                .onAppear { model.updateGridColumns(columns) }
                .onChange(of: columns) { _, value in model.updateGridColumns(value) }
            }
        }
    }
}

struct GridCard: View {
    @EnvironmentObject var model: AppModel
    let item: ClipItem
    @State private var hovering = false

    private var isSelected: Bool { model.selectedID == item.id }

    /// 行底色：多选勾中的优先级最高（批量操作时段，视觉焦点是"哪些被勾了"），
    /// 其余保持悬停蓝 > 单选灰的旧次序。
    private var rowFill: Color {
        if model.multiSelection.contains(item.id) { return Theme.selectionFill.opacity(0.55) }
        return hovering ? Theme.selectionFill : (isSelected ? Theme.hoverFill : .clear)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.cardCornerSmall, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                ItemArtwork(item: item, style: .grid)
            }
            .frame(height: 74)
            .clipped()

            Text(item.oneLineSummary)
                .font(.system(size: 11))
                .lineLimit(2)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // 网格卡片下面只留"置顶"这一个标记，不再挂时间戳（理由同丰富列表）。
            if item.pinned {
                HStack(spacing: 4) {
                    Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.orange)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(8)
        // 蓝框跟着鼠标走（用户指定）：悬停才画蓝框，选中只留浅灰底——
        // 键盘上下选行时仍有迹可循，但不会常驻一个刺眼的蓝框。
        .background(rowFill,
                    in: RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .strokeBorder(hovering ? Theme.selectionStroke.opacity(0.8) : Theme.cardBorder,
                              lineWidth: hovering ? 1.5 : 1)
        }
        .multiSelectBadge(model: model, item: item)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .clipItemGestures(model: model, item: item)
        .onDrag { DragProvider.make(for: item, store: model.store) }
        .contextMenu { ItemContextMenu(item: item) }
    }
}

// ── 简洁列表 ─────────────────────────────────────────────────

struct CompactListContent: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.sections) { section in
                        if !section.title.isEmpty {
                            SectionHeader(title: section.title, count: section.items.count)
                        }
                        ForEach(section.items) { item in
                            CompactRow(item: item).id(item.id)
                        }
                    }
                }
                .padding(.horizontal, Theme.contentPadding - 4)
                .padding(.vertical, 6)
            }
            .scrollContentBackground(.hidden)
            .onChange(of: model.selectedID) { _, id in
                // 只为键盘导航滚动：鼠标点选时目标就在光标底下，
                // 再 scrollTo(.center) 会把列表抽走一截，第二下点歪（用户实测）。
                defer { model.pendingScrollReveal = false }
                guard let id, model.pendingScrollReveal else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

struct CompactRow: View {
    @EnvironmentObject var model: AppModel
    let item: ClipItem
    @State private var hovering = false

    private var isSelected: Bool { model.selectedID == item.id }

    /// 行底色：多选优先（理由见 GridCard.rowFill）
    private var rowFill: Color {
        if model.multiSelection.contains(item.id) { return Theme.selectionFill.opacity(0.55) }
        return hovering ? Theme.selectionFill : (isSelected ? Theme.hoverFill : .clear)
    }

    var body: some View {
        HStack(spacing: 8) {
            ItemArtwork(item: item, style: .mini)
                .frame(width: 18, height: 18)

            Text(item.oneLineSummary)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            if item.pinned {
                Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        // 蓝框跟鼠标走（理由见 GridCard）
        .background(rowFill,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            if hovering {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Theme.selectionStroke.opacity(0.75), lineWidth: 1.2)
            }
        }
        .multiSelectBadge(model: model, item: item)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .clipItemGestures(model: model, item: item)
        .onDrag { DragProvider.make(for: item, store: model.store) }
        .contextMenu { ItemContextMenu(item: item) }
    }
}

// ── 丰富列表 ─────────────────────────────────────────────────

struct RichListContent: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.rowSpacing) {
                    ForEach(model.sections) { section in
                        if !section.title.isEmpty {
                            SectionHeader(title: section.title, count: section.items.count)
                        }
                        ForEach(section.items) { item in
                            RichRow(item: item).id(item.id)
                        }
                    }
                }
                .padding(.horizontal, Theme.contentPadding)
                .padding(.vertical, 8)
            }
            .scrollContentBackground(.hidden)
            .onChange(of: model.selectedID) { _, id in
                // 只为键盘导航滚动：鼠标点选时目标就在光标底下，
                // 再 scrollTo(.center) 会把列表抽走一截，第二下点歪（用户实测）。
                defer { model.pendingScrollReveal = false }
                guard let id, model.pendingScrollReveal else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

struct RichRow: View {
    @EnvironmentObject var model: AppModel
    let item: ClipItem
    @State private var hovering = false

    private var isSelected: Bool { model.selectedID == item.id }

    /// 行底色：多选优先（理由见 GridCard.rowFill）
    private var rowFill: Color {
        if model.multiSelection.contains(item.id) { return Theme.selectionFill.opacity(0.55) }
        return hovering ? Theme.selectionFill : (isSelected ? Theme.hoverFill : Color.primary.opacity(0.025))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                SourceIcon(item: item)
                    .frame(width: 16, height: 16)
                Text(item.kind.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)

                // 动作按钮只在选中/悬停时点亮：用"常驻占位 + 透明度"而不是
                // if 条件插入——插入会把 12pt 的标题行撑高 8pt，悬停时整列
                // 内容上下跳（用户实测反馈"条目有点晃动"）。disabled 挡住
                // 对隐形按钮的误点。
                HStack(spacing: 2) {
                    RowActionButton(symbol: "doc.on.doc", help: "复制到剪贴板") {
                        model.selectedID = item.id
                        model.copySelectedToList()
                    }
                    RowActionButton(symbol: item.pinned ? "pin.fill" : "pin",
                                    isActive: item.pinned,
                                    help: "置顶 / 取消置顶") {
                        model.selectedID = item.id
                        model.togglePinSelected()
                    }
                    RowActionButton(symbol: "trash", help: "删除") {
                        model.selectedID = item.id
                        model.deleteSelected()
                    }
                }
                .opacity(isSelected || hovering ? 1 : 0)
                .disabled(!(isSelected || hovering))
                // 行尾不再显示时间：具体某一条是几点几分对"找回一段内容"没有帮助，
                // 反而是每行都在跳动的干扰。日期已经由上面的分组标题（今天/昨天…）给过了。
            }

            ItemArtwork(item: item, style: .rich)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.cardPadding)
        // 蓝框跟鼠标走（理由见 GridCard）
        .background(rowFill,
                    in: RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .strokeBorder(hovering ? Theme.selectionStroke.opacity(0.8) : Theme.cardBorder,
                              lineWidth: hovering ? 1.5 : 1)
        }
        .multiSelectBadge(model: model, item: item)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .clipItemGestures(model: model, item: item)
        .onDrag { DragProvider.make(for: item, store: model.store) }
        .contextMenu { ItemContextMenu(item: item) }
    }
}

struct RowActionButton: View {
    let symbol: String
    // 有状态按钮（置顶）用：激活时橙色实心，一眼能看出"已经置顶了"。
    // 只换 pin/pin.fill 在 11pt 下几乎看不出差别（用户实测反馈过）。
    var isActive: Bool = false
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color.orange : Color.secondary)
        // 用无障碍标签而不是 .help：每个 .help 都会在 SwiftUI 里挂一套
        // HelpView/无障碍状态机，行 × 按钮数 × 重绘次数攒下来是几万个小节点
        //（内存排查实测：HelpStyle TypedElement 上万个）。语义留给 VoiceOver 即可。
        .accessibilityLabel(help)
    }
}

// ── 卡片内容 ─────────────────────────────────────────────────

enum ArtworkStyle {
    case mini
    case grid
    case rich
}

struct ItemArtwork: View {
    @EnvironmentObject var model: AppModel
    let item: ClipItem
    let style: ArtworkStyle

    var body: some View {
        switch style {
        case .mini:
            SourceIcon(item: item)
        case .grid:
            gridArtwork
        case .rich:
            richArtwork
        }
    }

    @ViewBuilder
    private var gridArtwork: some View {
        if item.kind == .image, let image = thumbnail {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else if item.kind == .color, let color = ContentClassifier.parseColor(item.text) {
            ZStack {
                Color(nsColor: color.platformColor)
                Text(color.hex)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(color.isLight ? .black : .white)
            }
        } else {
            VStack(spacing: 4) {
                SourceIcon(item: item, fallbackIcon: true)
                    .frame(width: 26, height: 26)
            }
        }
    }

    @ViewBuilder
    private var richArtwork: some View {
        switch item.kind {
        case .image:
            if let image = thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    // 150 的 70%：图片条目太高，一屏放不下几条（用户要求缩 30%）
                    .frame(maxHeight: 105)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Text("图片已不可用").font(.system(size: 11)).foregroundStyle(.tertiary)
            }

        case .color:
            if let color = ContentClassifier.parseColor(item.text) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: color.platformColor))
                        .frame(width: 40, height: 26)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                        }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(color.hex)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                        Text(color.rgbString)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }

        case .file:
            VStack(alignment: .leading, spacing: 4) {
                ForEach(item.fileURLs.prefix(3), id: \.self) { url in
                    HStack(spacing: 6) {
                        Image(nsImage: AppIcons.icon(forFile: url.path))
                            .resizable()
                            .frame(width: 14, height: 14)
                        Text(url.lastPathComponent)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                if item.fileURLs.count > 3 {
                    Text("另有 \(item.fileURLs.count - 3) 个")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

        case .text, .link:
            VStack(alignment: .leading, spacing: 3) {
                if item.kind == .link, let host = URL(string: item.text)?.host {
                    HStack(spacing: 4) {
                        Image(systemName: "globe").font(.system(size: 10))
                        Text(host).font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Color(nsColor: .systemBlue))
                }
                Text(item.text)
                    .font(.system(size: 12))
                    .lineLimit(3)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var thumbnail: NSImage? {
        guard let url = model.store.thumbnailURL(for: item) else { return nil }
        return ThumbnailCache.shared.thumbnail(at: url)
    }
}

/// 来源应用图标：取到就用系统图标，取不到退回类型图标。
/// 用了系统图标就"一眼看出这条是从哪来的"，这是剪贴板工具最常用的识别线索。
struct SourceIcon: View {
    let item: ClipItem
    var fallbackIcon: Bool = true

    var body: some View {
        if let bundleID = item.sourceBundleID, let image = AppIcons.icon(forBundleID: bundleID) {
            Image(nsImage: image).resizable()
        } else if let first = item.fileURLs.first {
            Image(nsImage: AppIcons.icon(forFile: first.path)).resizable()
        } else if fallbackIcon {
            Image(systemName: item.kind.symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.accent(for: item.kind))
        } else {
            Image(nsImage: AppIcons.genericApp).resizable()
        }
    }
}

struct SectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 6)
        .padding(.bottom, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// ── 底部状态条 ───────────────────────────────────────────────

struct FooterBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        // 计数放 ZStack 正中，而不是 HStack + Spacer：
        // 右侧可能出「空格 / Esc 关闭预览」的提示，用 Spacer 撑出来的"居中"
        // 会被它顶偏，只有叠一层才是真正的面板中心。
        ZStack {
            Text(model.countSummary)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            HStack(spacing: 6) {
                Spacer(minLength: 0)

                if model.isPreviewing {
                    Text("空格 / Esc 关闭预览")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, Theme.contentPadding)
        .frame(height: 26)
    }
}

// ── 快捷键一览 ───────────────────────────────────────────────

struct ShortcutHelpOverlay: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .onTapGesture { model.showsShortcutHelp = false }

            VStack(alignment: .leading, spacing: 10) {
                Text("键盘快捷键")
                    .font(.system(size: 14, weight: .semibold))

                VStack(alignment: .leading, spacing: 5) {
                    ForEach(ShortcutAction.allCases) { action in
                        let spec = model.prefs.value.spec(for: action)
                        HStack(spacing: 8) {
                            Text(spec.display)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .frame(width: 62, alignment: .leading)
                            Text(action.title).font(.system(size: 11))
                            Spacer(minLength: 0)
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 5) {
                    ForEach(ShortcutAction.fixedShortcuts, id: \.keys) { entry in
                        HStack(spacing: 8) {
                            Text(entry.keys)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .frame(width: 62, alignment: .leading)
                            Text(entry.action).font(.system(size: 11))
                            Spacer(minLength: 0)
                        }
                    }
                }

                Text("可在「设置 → 快捷键」里改上面那组")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: 320)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            }
            .padding(20)
        }
    }
}

// ── 右键菜单 / 拖拽 ──────────────────────────────────────────

extension View {
    /// 行条目的点按手势三件套，三种视图（网格/紧凑/丰富）共用。
    /// ⌘单击 = 多选开关（配合 MultiSelectBar 批量删除/收藏）；
    /// 按着 ⌘ 时不做即时选中，避免多选的同时把"当前条目"也改掉。
    func clipItemGestures(model: AppModel, item: ClipItem) -> some View {
        // 双击要先挂：SwiftUI 按"后挂的让位"解析同视图上的多个点按手势，
        // 单击在前会把第一次点击消费掉，双击永远不触发（用户实测踩过）。
        onTapGesture(count: 2) { model.selectedID = item.id; model.pasteSelected() }
            // 选中高亮的即时反馈靠 pressing 回调：**按下瞬间**就触发，
            // 不等松手、也不等 ~0.3s 的双击消歧窗口——只靠单击手势的话，
            // 这段时间界面毫无反应，手感就是"迟钝"（用户实测反馈过）。
            .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
                if pressing, !NSEvent.modifierFlags.contains(.command) {
                    model.selectedID = item.id
                }
            }, perform: {})
            // 单击兜底：万一 pressing 没触发，松手后仍会选中——
            // 慢一点，但不会"点了没反应"。
            .onTapGesture {
                if NSEvent.modifierFlags.contains(.command) {
                    model.toggleMultiSelect(item.id)
                } else {
                    model.clearMultiSelection()
                    model.selectedID = item.id
                }
            }
    }

    /// 多选勾选徽章：右上角一个 ✓ 圆标，只在被勾选时出现。
    @ViewBuilder
    func multiSelectBadge(model: AppModel, item: ClipItem) -> some View {
        overlay(alignment: .topTrailing) {
            if model.multiSelection.contains(item.id) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white, Color.accentColor)
                    .padding(3)
            }
        }
    }
}

struct ItemContextMenu: View {
    @EnvironmentObject var model: AppModel
    let item: ClipItem

    var body: some View {
        Button("粘贴") { model.selectedID = item.id; model.pasteSelected() }
        Button("复制到剪贴板") { model.selectedID = item.id; model.copySelectedToList() }
        // 富文本条目粘贴时默认带格式，这个入口给"就要素文本"的时刻
        if item.kind == .text || item.kind == .link || item.kind == .color {
            Button("复制为纯文本") { model.copyAsPlainText(item) }
        }
        if item.kind == .image {
            Button("OCR 文字到剪贴板") { model.ocrToClipboard(item) }
        }
        Button(item.pinned ? "取消置顶" : "置顶") { model.selectedID = item.id; model.togglePinSelected() }

        Divider()

        if item.kind == .link, let url = URL(string: item.text) {
            Button("打开链接") { NSWorkspace.shared.open(url) }
        }
        if item.kind == .file, !item.fileURLs.isEmpty {
            Button("在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting(item.fileURLs)
            }
        }
        if item.kind == .color, let color = ContentClassifier.parseColor(item.text) {
            Button("复制 HEX") { copyToPasteboard(color.hex) }
            Button("复制 RGB") { copyToPasteboard(color.rgbString) }
        }

        if !model.prefs.value.categories.isEmpty {
            Menu("移到分类") {
                ForEach(model.prefs.value.categories) { category in
                    Button(category.name) {
                        model.store.setManualCategories([category.id], for: item.id)
                        model.store.save()
                        model.refresh()
                        model.showHint("已归入「\(category.name)」")
                    }
                }
            }
        }

        Divider()
        Button("删除") { model.selectedID = item.id; model.deleteSelected() }
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        model.watcher.ignore(changeCount: pasteboard.changeCount)
        model.showHint("已复制 \(text)")
    }
}

enum DragProvider {
    /// 拖出去的载荷。文本给字符串；图片给 blob 文件；文件给第一个真实路径。
    /// 只给第一个文件是 NSItemProvider 的限制（一个 provider 一个载荷），
    /// 所以多文件条目拖出时给的是首个文件 + 文本路径兜底。
    static func make(for item: ClipItem, store: ClipStore) -> NSItemProvider {
        switch item.kind {
        case .text, .link, .color:
            return NSItemProvider(object: item.text as NSString)
        case .image:
            if let url = store.imageURL(for: item), let provider = NSItemProvider(contentsOf: url) {
                return provider
            }
            return NSItemProvider(object: item.oneLineSummary as NSString)
        case .file:
            if let first = item.fileURLs.first, let provider = NSItemProvider(contentsOf: first) {
                return provider
            }
            return NSItemProvider(object: item.text as NSString)
        }
    }
}

private extension ColorValue {
    /// 色块上写 HEX 时得知道用黑字还是白字，否则浅黄底白字基本看不见
    var isLight: Bool {
        (0.299 * red + 0.587 * green + 0.114 * blue) > 0.6
    }
}
