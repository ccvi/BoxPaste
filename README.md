# BoxPaste

macOS 菜单栏常驻的剪贴板历史管理器：轮询记录剪贴板，全局热键呼出无边框面板，选中后回写剪贴板并可选模拟 ⌘V。

- 当前版本：**1.0.29**
- 作者：ccvi1223 · ccvi1223@qq.com
- 工程最低版本：`.macOS(.v14)`（`Package.swift`）——不抬到 26 的理由同 BoxMouse 家族：抬上去换不到任何东西，却让 14 / 15 上一行都跑不起来

---

## 功能（1.0.29 已实现）

| 位置 | 能力 |
| --- | --- |
| 菜单栏左键 | 呼出面板 |
| 菜单栏右键 | 打开面板 / 暂停记录·恢复记录 / 记录富文本 / 设置… / 关于 / 使用帮助 / 退出 |
| 面板顶栏 | 图钉（点别处不自动收起）、搜索框「输入开始搜索…」、三视图切换（丰富 / 简洁 / 网格）、齿轮 |
| 分类 | 「全部」+ 收藏 / 链接 / 图片 / 文件 + 自建分类（在「设置 → 分类」里新建） |
| 双击 | 选中并粘贴 |
| ⌘ 单击 | 多选，工具条出现「已选 N 项」「粘贴」「收藏」「删除」「取消」+ 全选勾选框 |
| 批量粘贴 | 多选后点「粘贴」：按列表顺序逐条写剪贴板 + 替你按 ⌘V，间隔 0.25s；中途重新呼出面板即中止 |
| 右键菜单 | 粘贴 / 复制到剪贴板 / 复制为纯文本 / **OCR 文字到剪贴板** / 置顶 / 打开链接 / 在访达中显示 / 复制 HEX·RGB / 移到分类 / 删除 |
| 空格预览 | 图片大图（降采样 1200）、全文可选中、链接、HEX·RGB·HSL、文件列表 |
| 预览翻译 | 文本条目底部「翻译」+ 中/英下拉：系统离线翻译（macOS 15+），就地替换、可切回原文；勾「保留原文」变逐句对照（原文在上、译文在下） |
| 拖入面板 | 文件 / 图片 / 文本，松开即加入历史 |
| 快捷键 | 呼出热键可自定义；⌘1–9 直接粘贴对应条目（置顶不占编号） |
| 设置 | 通用 / 分类 / 快捷键 / 关于 四个页签 |

**隐私**：支持整体暂停记录（菜单栏「暂停记录」），暂停期间不读剪贴板。

## 快速开始

```bash
./build-app.sh --install          # 构建并安装到 /Applications
./build-app.sh --install --debug  # 带诊断输出
```

首次启动会写入 `~/Library/LaunchAgents/com.pcxx.boxpastemac.plist` 并注册开机自启（可在设置里关）。热键默认值见「设置 → 快捷键」。

## 焦点恢复：为什么粘贴要等一会儿

这是「双击粘贴」最容易做成半成品的地方。完整链路是两步，缺一步就会粘贴到 BoxPaste 自己身上：

1. `show()` 时记下最前面的**非本应用**进程，并**强引用**住它（弱引用会在面板收起后失效）
2. 粘贴时先 `onReactivatePreviousApp` 把焦点还回去，再由 `AppModel.sendPasteWhenFrontmost` **轮询比对 pid**，确认真的切到前台了才发 ⌘V —— 上限约 1.2 秒

所以双击到文字真的被粘贴，中间有几十到几百毫秒。这不是卡，是在等焦点交接完成。

## 剪贴板采集

- 轮询 `NSPasteboard.changeCount`，默认 0.35 秒
- **面板收起后放慢到 `max(base*2.6, 0.8)`**：看不见的时候没必要高频读剪贴板
- 图片走 ImageIO，**不解全图**；缩略图另存 `@thumb`

## 预览翻译：语种不能交给框架去猜

用的是 macOS 15 起自带的 Translation 框架（离线、免密钥）。代码在 `Core/TranslateTarget.swift`（纯逻辑，30 项自检）+ `UI/TranslateBar.swift`（视图）。三条都是踩出来的，别改回去：

- **源语种必须显式给**。`source: nil` 让框架自己识别，纯中/纯英都还行，**中英混排它认不出来**，会弹系统面板「The language could not be automatically detected」，我们只收到 `TranslationError/1`。
- **按行分流**。目标中文只翻「汉字占比 < 15%」的行，目标英文只翻「含汉字」的行，相邻同类行合并成块再批量送 —— 保住行结构，也不会把中文再"翻"一遍。
- **`prepareTranslation()` 抛错不等于不能翻**。它在首次启动等情形下会抛 `TranslationError/1`，而紧接着的 `translations(from:)` 是成功的；把它当致命错误，用户看到的就是「语言包明明装了却说翻译失败」。

另外：同语种会被框架直接拒（en→en），所以默认目标按内容猜（中文内容 → 英文），并在 `plan` 没有可翻块时先提示用户换方向，不惊动框架。

还有一个界面坑：预览窗和面板是**两个独立的 NSPanel**。点预览里的控件（翻译/复制）时预览会接过 key，面板随即收到 `windowDidResignKey`，照旧逻辑会 `hide()` 面板 —— 而 `hide()` 里连预览一起收掉，用户看到的就是「点翻译，窗口直接关了」。所以 `windowDidResignKey` 里必须先判断「键盘是不是落在自己的窗口上」，是就不收。同理，预览 `show()` 要用 `makeKeyAndOrderFront` 而不是 `orderFront`：非 key 窗口的**第一下点击只用来抢焦点**，控件动作会被吞，用户得点两次才翻译。

### 右上角 × 会"点了没反应"（1.0.28 修）

真凶不是按钮，是**状态先脱节了**：预览窗还在台上，`model.isPreviewing` 已经是 `false`。这时点 × 赋一次 `false`，`didSet` 因为"值没变"根本不跑，窗口自然关不掉。日志留痕是 `关闭预览：模型已是 false，补一次收起通知`（`/tmp/boxpaste-diag.log`）。

脱节从哪来：`isPreviewing = true` → `preview.show()` → `makeKeyAndOrderFront` 内部触发面板的 `windowDidResignKey`，而那一刻 `NSApp.keyWindow` 可能已经是 **nil**（应用未激活时就是这样），于是"键盘在自己窗口上"判成否 → `hide()` 收掉面板、连预览一起收、`isPreviewing = false`；可 `makeKeyAndOrderFront` 还没返回，紧接着又把预览窗摆回台上。**窗口回来了，模型没回来。**

三处一起改，少一处都不够：
1. `PanelController` 加 `isOpeningPreview` 标志，`preview.show()` 前后置位，`windowDidResignKey` 见到就早退 —— 过渡期里的 resignKey 是开预览的副作用，不是"用户离开面板"；
2. `isKeyboardOnOwnWindow` 里 `keyWindow == nil` 只在过渡期算"自己"（应用切后台时它也是 nil，那时该收）；
3. `AppModel.closePreview()`：值没变时也显式补一次通知，作为兜底 —— 窗口和模型再脱节，× 也一定能把窗口收掉。

顺带把 × 的命中区从 14pt 图标撑到 24×24（`.contentShape(Rectangle())`），并给预览窗的 `NSHostingView` 子类打开 `acceptsFirstMouse`，窗口不是 key 时第一下点击也直接落到控件上。

## 「保留原文」：逐句对照必须逐行送翻

勾上工具条上的「保留原文」，预览变成一句原文（次要色）在上、它自己的译文（正文色）在下。这条需求把翻译的**送翻粒度**改了：

- 普通模式仍然是"相邻同类行合并成块"整块送（跨句上下文在，读起来更连贯）；
- 对照模式必须**逐行**送（`TranslateTarget.linesNeedingTranslation`，重复行只送一次），回来才能一行对一行。**不能**把整块译文按 `\n` 拆回去 —— 框架合并/拆分句子时行数会对不上，配错行比不配对更糟。
- 配对用行号当 `ForEach` 的 id：空行和重复行都会撞原文，撞了直接画错或崩。
- 勾/取消勾「保留原文」时如果已经在看译文，**当场重译**（和切语言同一个处理）：整段译文里没有逐句结构，硬拆必然错。
- 勾选状态写 `UserDefaults`（`boxpaste.keepOriginal`），默认 false —— 默认行为与之前完全一致。

`translatedText`（整段，供字数和"整段模式复制"用）与 `translatedPairs`（逐句）**并存**，不是二选一。底部按钮固定叫「复制」，复制的就是**屏幕上看到的那份**：对照模式 = 原文 + 译文逐句交替（`joinedBilingual`），整段译文 = 译文（`joinedTranslation`），没翻译 = 记录本身；具体复制什么写在 `.help` 里，不靠按钮文案随状态变。

## 呼出判据：`isVisible` 不等于"看得见"

面板是 `.nonactivatingPanel`。当抢激活被系统拒掉（前台全屏应用、别的应用开着模态、刚从锁屏回来），窗口会被摆上窗口栈却**从没成为 key**；而唯一的自动收起入口是 `windowDidResignKey` —— 没成为 key 就永远收不起来。结果 `window.isVisible` 一直是 true、用户眼前什么都没有。

如果 `toggle()` 只看 `isVisible`，这种状态下按热键就是把它 `hide()`，症状是**"按了完全没反应，再按几次才出来"**（1.0.27 修的就是这个）。正确判据是 `isVisible && occlusionState.contains(.visible)`：它只回答"这一帧里窗口有没有被画出来"。命中"在台上但看不见"时走 `bringOnScreen()`（`orderFrontRegardless` + `makeKey`），既不重置分类/搜索，也不重跑剪贴板补扫。

## 面板交互里的两个 SwiftUI 陷阱

| 陷阱 | 现象与原因 |
| --- | --- |
| **双击手势必须先挂** | SwiftUI 按"后挂的让位"解析同一视图上的多个点按手势。单击在前会把第一次点击消费掉，双击**永远不触发** |
| **少用 `.help`** | 每个 `.help` 都会挂一套 HelpView / 无障碍状态机。面板里条目一多，`HelpStyle` TypedElement 轻松上万个 |

## 预览正文：14pt + 4pt 行距

正文统一 `PreviewCard.bodyFontSize = 14`、`bodyLineSpacing = 4`（行高约 21pt），纯文本 / 译文 / 富文本 / 链接地址四处共用这两个常量 —— 分开写的话，切换"原文 ↔ 译文"或换条目时字号行距会跳一下。

**行距只能加在视图上（`.lineSpacing`），不能写进 attributed string。** 实测（三行文本量 `NSHostingView.fittingSize`）：`NSParagraphStyle.lineSpacing = 4` 让富文本还是 51.0pt（和填 0 一模一样），改视图 `.lineSpacing(4)` 才是 59.0pt。SwiftUI 的 `Text` 会吞掉段落的行距设置，两处都写也不会翻倍（因为段落那条根本没用）。同理，`resizedRichText` 只改字号，别去动源文档的段落样式（对齐/缩进要原样留着）。

## 预览必须在上游截断

长文本预览不做截断会直接把进程打死。实测：10000 行 / 40 万字符的文本，卡在 `ViewLayoutEngine.sizeThatFits` 60 秒以上，footprint 冲到 101 MB，最后 **exit 137**。

所以阈值卡在**200 行 / 20000 字符**，超出的部分不进布局。

## 菜单栏落位

macOS 26 上**没有任何 API 能查询「状态项是否被系统挪走了」**——`isVisible` 恒为 true，只能看窗口几何判断。应用侧同样没有 API 能代改，`.autosaveName` / `.removalAllowed` 这两条路都被对照实验推翻了。

## 数据安全：两条硬规矩

1. **历史没装载完不许 `save()`**。否则空仓库会把磁盘上的真实历史整个覆盖掉。采集侧同样有守卫
2. **孤儿 blob 对账要求条目非空**。安全前提不满足时**宁可留垃圾，也不能删用户数据**

## 工程结构

```
Sources/BoxPaste/
├── main.swift          进程入口：拦掉 --selftest / --version 再起 NSApplication
├── App/                AppDelegate（装配）/ AppModel（状态中枢）/ SelfTest / PerfFixtures
├── Core/               AppIdentity / ContentClassifier / HotKeyCenter / ImageTools
│                       Paster / Preferences / Shortcuts / SoundFeedback / Support
├── Model/              ClipItem（纯值）/ ClipStore（落盘）/ ClipboardWatcher（轮询）
└── UI/                 WindowControllers / PanelView / PreviewView / SettingsView / Theme
Tools/                  make-icon-source.swift、make-icon.swift（被 build-app.sh 调用）
                        以及设计稿导入与对照图脚本
```

## 几个不能改坏的约束

1. 🔴 **永远不要直接执行 `.app` 里的二进制**。绕过 LaunchServices 会让这个 bundle id 的**状态栏登记永久失效**，只能换 bundle id 才能救。自检因此只跑 `.build` 里的裸产物
2. 🔴 **bundle id 不能随便改回去**（`AppIdentity.swift`），改一次状态项登记就废一次
3. 🔴 **签名用固定本地证书，安装时绝不重新签名**。「辅助功能」授权是 TCC 按签名要求记的：
   ad-hoc（`--sign -`）的 cdhash 每次构建都变，等于每装一次新版本授权就掉一次；
   打包默认自动挑 `FastFind Local Signing`，签名要求因此变成
   `identifier "com.pcxx.boxpastemac" and certificate root = H"…"`，跨版本稳定。
   安装段必须是 `ditto` + `xattr -cr` + cdhash 比对，**不能跟一句 `codesign --force --sign -`**
   ——那句会把证书覆盖回 ad-hoc，症状是"装完看着一切正常，自动粘贴一条都不触发"。
   另：固定证书下仍然不要附加受限授权（`com.apple.developer.*`），会让 launchd spawn 失败（POSIX 163）
4. 🔴 **`NSCache` 的 cost 必须按"解码后的位图字节"算，不是文件字节**。
   缩略图 PNG 文件平均 132KB，解码成 600px 位图是 1.44MB —— 按文件字节计费等于
   把上限低估十倍，名义 20MB 实际能缓存到 200MB 位图才淘汰（图片记录一多就顶爆
   footprint）。见 `ThumbnailCache.bitmapBytes(of:)`，自检有断言钉住这个口径。
5. 🔴 **正则要缓存编译结果**。`NSRegularExpression(pattern:)` 一次 4.9μs，
   而 `rebuildCategoryCounts` 是「分类数 × 条目数」次调用（402×4=1608 次/刷新）——
   不缓存就是每次刷新白烧 7.8ms。见 `ContentClassifier.cachedRegex(_:)`。
6. **热键注册 API 的"先注册后清理"形状是刻意的**：早先的写法在 `register()` 内部先 `unregisterAll()`，于是注册第二个热键时把第一个一起清了，表现是**呼出热键静默失效**
7. **热键回调闭包不能捕获上下文**：它被当成 C 函数指针传下去
8. **`LSUIElement` 应用的最小主菜单不能删**：没有系统菜单栏，文本框就按不出 ⌘C / ⌘V / ⌘A

## 版本规则

`VERSION` 是唯一来源，`build-app.sh` 按源码指纹决定是否 patch+1；`--no-bump` 保持版本号，`--bump` 强制递增。

```bash
./build-app.sh --help     # --debug --no-sign --no-sandbox --install --bump --no-bump --clean
```

## 自检

```bash
.build/arm64-apple-macosx/debug/BoxPaste --selftest
```

166 处断言（`check(` 85 + `equal(` 81），其中两组在循环里（颜色反例 8 条、内置分类 4 条），所以运行时打出的「✓」行数不等于 166。打包前强制跑，非 0 退出不出包。

## 诊断

| 参数 | 用途 |
| --- | --- |
| `--selftest` | 发布门禁 |
| `--store-root <dir>` | 指定数据根目录，用临时库跑实验，不碰真实历史 |
| `--seed-heavy` | 塞入大量测试条目，做性能与内存对照 |
| `--diagnose-status` | 状态项落位诊断（写 `/tmp/boxpaste-status-diagnostic.txt`） |
| `--preview-memory` | 预览内存对照实验 |
| `--show-panel` / `--show-preview` / `--show-settings` | 直接打开对应窗口 |
| `--keep-alive` | 不退出，便于外部附进程采样 |
| `--settings-close-test` | 设置窗「关窗即拆」的内存对照（开窗→量→关窗→量→退出） |
| `--measure-reopen` | 面板视图树重建耗时（决定要不要自动拆视图） |
| `--measure-teardown` | 滚完列表再拆视图树，量到底能回收多少 |
| `--batch-paste-test[=N]` | 批量粘贴端到端验证：取列表最上 N 条走完整链路。⚠️ `open -a X.app --args` 不传参，实际用触发文件 `/tmp/boxpaste-batch-test.trigger`（内容 `3` 或 `3:目标pid`），结果写 `/tmp/boxpaste-batch-test.log` |

自动重启的端到端验证用标记文件 `/tmp/boxpaste-autorestart-test.trigger`：存在时门槛降为
5MB / 空闲 3 秒 / 冷却 5 秒，可以几分钟内跑完「触发→落盘→退出→拉起→继承计数→停用→手动重置」全链路。

## 数据位置

| 数据 | 路径 |
| --- | --- |
| 历史元数据 | `~/Library/Application Support/BoxPaste/history.json` |
| 图片 / 富文本 blob | 同目录 `blobs/<hash>.png`、`<hash>@thumb.png`、`<hash>.rtf`、`<hash>.html` |
| 配置 | UserDefaults，键 `com.pcxx.boxpaste.preferences`（JSON 编码） |
| 面板位置 | UserDefaults 键 `com.pcxx.boxpaste.panelOriginX / Y` |
| 开机启动 | `~/Library/LaunchAgents/com.pcxx.boxpastemac.plist` |

缩略图缓存只在内存里（`NSCache`，200 条 / 24 MB，**按解码后的位图字节计费**），不落盘。
设置窗是**关掉就拆**的：`contentView` 置 nil、控制器一并释放，下次打开重建
（实测：402 条记录下设置窗视图树 = 9.3 万个对象 / 7.8 MB 活对象，常驻纯属浪费）。

## 一个已经量过的结论

1.0.20 实测：macOS 26 上 `malloc_zone_pressure_relief` **恒返回 0**，调用它没有任何作用，别再实现一遍。

1.0.23 实测（402 条记录、跑 4 小时的实例）：footprint 216MB 里，`heap` 活对象 107MB，其中 **SwiftUI 视图图 78.8MB（74%）**，而历史数据本身只有 212KB（history.json）。换句话说，这个应用的内存几乎全花在「界面结构」上：每行记录平均 190KB 视图图。
真正能降的只有两条路——**不让视图树常驻**（设置窗关掉即拆，已做；面板视图树还在，要拆得先量重建延迟）和**别让缓存上限算错**（缩略图计费，已修）。
另：分配器不是"free 就还页"，而是**整块 region 空了才还**——设置窗拆掉后 footprint 掉了 5.4MB，但小块反复分配回收的部分会一直留着，所以"内存数字不降"常见、并不等于泄漏。
