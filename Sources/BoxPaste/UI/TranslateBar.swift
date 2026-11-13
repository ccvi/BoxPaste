import SwiftUI

#if canImport(Translation)
import Translation

// ============================================================
// 预览窗底部的「翻译 + 中/英下拉」
//
// 交互照 BoxShot 的 OCR 翻译条（用户指定的参照）：按钮在最左、紧跟一个只显示「中 ⌄」
// 的小下拉；翻完就地替换正文，按钮变成「原文」，再点切回原始内容。
//
// 为什么用 `.translationTask` 而不是"自己 new 一个 session"：
// `TranslationSession` 没有公开的初始化方法，只能由 SwiftUI 的这个修饰器发下来；
// 而它正好也负责"语言包没装 → 弹系统下载框"这件事，省掉我们自己拼 NSSheet。
//
// 🔴 译文和原文分开存（`translated` 为 nil 就是原文）：翻译是"看一眼"的行为，
// 把原文覆盖掉等于让用户没法对照，切回原文也只能靠重开预览。
// ============================================================

@available(macOS 15.0, *)
struct TranslateBar: View {
    let sourceText: String
    /// 译文；nil = 正在显示原文
    @Binding var translated: String?
    @Binding var target: TranslateTarget
    /// 勾了「保留原文」→ 逐句对照（原文在上、译文在下）
    @Binding var keepOriginal: Bool
    /// 对照用的"一行原文 + 一行译文"（非对照模式为 nil）
    @Binding var pairs: [BilingualPair]?

    @State private var configuration: TranslationSession.Configuration?
    @State private var isWorking = false
    @State private var errorText: String?

    /// 逐行送翻时每批多少条。整篇一次塞进去在长文本上要等很久，
    /// 分批能让每一轮往返都短，出问题也只影响一批。
    private static let batchSize = 40

    var body: some View {
        HStack(spacing: 6) {
            Button(isShowingTranslation ? "原文" : "翻译") { toggle() }
                .controlSize(.small)
                .disabled(isWorking || sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(isShowingTranslation ? "切回原文" : "把这段文字翻译成\(target.title)")
            Menu {
                ForEach(TranslateTarget.allCases) { item in
                    Button {
                        target = item
                        TranslateTarget.remember(item)
                        // 换了目标语言，上一条提示说的是"上一个方向"，必须清掉
                        // （否则用户选了中文，界面上还挂着「这段文字已经是英文了」）
                        errorText = nil
                        // 已经有一份译文在显示时，换语言就当场重译一遍
                        if isShowingTranslation { startTranslation() }
                    } label: {
                        Text(item == target ? "✓ \(item.title)" : item.title)
                    }
                }
            } label: {
                HStack(spacing: 2) {
                    Text(target.short)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("翻译成哪种语言")

            // 保留原文：勾上就变成逐句对照（原文在上、译文在下），不勾是整段替换。
            // 状态写回 UserDefaults —— 这是使用习惯，每次重开预览都要重勾很烦。
            Toggle("保留原文", isOn: Binding(
                get: { keepOriginal },
                set: { value in
                    keepOriginal = value
                    TranslateTarget.rememberKeepOriginal(value)
                    errorText = nil
                    // 已经译过了：勾/取消勾都得重跑一次 —— 对照要"一行对一行"的数据，
                    // 整段译文里没有这个结构，硬拆会把行数对错。
                    if isShowingTranslation { startTranslation() }
                }))
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .fixedSize()
            .help("原文在上、译文在下，逐句对照")

            if isWorking {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            }
            if let errorText {
                Text(errorText)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        // 配置一变就重跑；首次调用时系统会自己弹「下载语言包」
        .translationTask(configuration) { session in
            await run(session)
        }
    }

    private var isShowingTranslation: Bool { translated != nil }

    private func toggle() {
        if isShowingTranslation {
            translated = nil          // 切回原文（原文一直留着，不做破坏性覆盖）
            pairs = nil
        } else {
            startTranslation()
        }
    }

    private func startTranslation() {
        errorText = nil
        let plan = TranslateTarget.plan(for: sourceText, into: target)
        // 整篇已经是目标语言（一个字都不用翻）时**别去问框架**：同语种它只会抛
        // TranslationError，界面上就是一句看不懂的「翻译失败：无法翻译」。
        guard plan.hasWork, let source = plan.source else {
            errorText = "这段文字已经是\(target.title)了，换个方向"
            return
        }
        // 🔴 源语种**显式给**，不能让框架自己认：中英混排时它认不出来，会弹
        // 「The language could not be automatically detected」并要求用户选源语言，
        // 我们这边只收到 Unable to Translate —— 用户看到的就是「两个方向都失败」。
        if var existing = configuration {
            // 同一对语言要"再来一次"，必须 invalidate —— 直接赋等值对象不会重新触发；
            // 换了方向则要把 source / target 一起改掉。
            existing.invalidate()
            existing.source = source.language
            existing.target = target.language
            configuration = existing
        } else {
            configuration = .init(source: source.language, target: target.language)
        }
    }

    private func run(_ session: TranslationSession) async {
        await MainActor.run { isWorking = true; errorText = nil }
        let plan = TranslateTarget.plan(for: sourceText, into: target)
        guard plan.hasWork else {
            await MainActor.run {
                isWorking = false
                errorText = "这段文字已经是\(target.title)了，换个方向"
            }
            return
        }
        do {
            // 语言包没装时它会弹系统下载框。
            // 🔴 **但它的失败不能当致命错误**：`prepareTranslation()` 在首次启动等情形下
            // 会抛 TranslationError/1，而紧接着的 `translations(from:)` **是成功的**。
            // 原来在这里 try 完就 catch，用户看到的是「语言包明明装了却说翻译失败」。
            try await session.prepareTranslation()
        } catch {
            let ns = error as NSError
            NSLog("[BoxPaste][translate] prepare 未通过（继续翻）%@/%d", ns.domain, ns.code)
        }
        do {
            if keepOriginal {
                // 对照模式：**逐行**送翻（去重后分批），回来才能一行对一行。
                // 这里不能复用上面那套"相邻同类行合并成块"的方案：一块回来是多行，
                // 再按 \n 拆回去并不可靠 —— 框架合并/拆句时行数就对不上，配错行比不配对更糟。
                let pending = TranslateTarget.linesNeedingTranslation(sourceText, into: target)
                var byOriginal: [String: String] = [:]
                var start = 0
                while start < pending.count {
                    let slice = Array(pending[start..<min(start + Self.batchSize, pending.count)])
                    let requests = slice.map { TranslationSession.Request(sourceText: $0) }
                    let responses = try await session.translations(from: requests)
                    for response in responses { byOriginal[response.sourceText] = response.targetText }
                    start += Self.batchSize
                }
                let built = TranslateTarget.bilingualPairs(sourceText, into: target,
                                                           translations: byOriginal)
                let joined = TranslateTarget.joinedTranslation(built)
                await MainActor.run {
                    isWorking = false
                    if joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        errorText = "没有译出内容"
                    } else {
                        pairs = built
                        translated = joined
                    }
                }
                return
            }

            // 只把"要翻的块"送进去，一次批量。每块语种单一，不会再把混排丢给框架去猜。
            let requests = plan.pendingTexts.map { TranslationSession.Request(sourceText: $0) }
            let responses = try await session.translations(from: requests)
            // 按 sourceText 回填（不依赖返回顺序），再按原文顺序拼回去
            var byOriginal: [String: String] = [:]
            for response in responses { byOriginal[response.sourceText] = response.targetText }
            var rebuilt: [String] = []
            for (piece, need) in zip(plan.pieces, plan.needsTranslation) {
                rebuilt.append(need ? (byOriginal[piece] ?? piece) : piece)
            }
            let result = rebuilt.joined(separator: "\n")
            await MainActor.run {
                isWorking = false
                if result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    errorText = "没有译出内容"
                } else {
                    pairs = nil            // 整段模式没有逐句结构，别让上一次的对照数据留着
                    translated = result
                }
            }
        } catch {
            // 诊断：`localizedDescription` 只有一句 "Unable to Translate"，
            // 到底是语种识别失败还是别的原因，只有把 domain/code 打出来才知道。
            let ns = error as NSError
            NSLog("[BoxPaste][translate] 翻译失败 domain=%@ code=%d userInfo=%@",
                  ns.domain, ns.code, String(describing: ns.userInfo))
            await MainActor.run {
                isWorking = false
                errorText = "翻译失败：\(error.localizedDescription)"
            }
        }
    }
}
#endif
