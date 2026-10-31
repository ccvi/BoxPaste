# BoxPaste

macOS 菜单栏常驻的剪贴板历史管理器：轮询记录剪贴板，全局热键呼出无边框面板，选中后回写剪贴板并可选模拟 ⌘V。

- 当前版本：**1.0.20**
- 作者：ccvi1223 · ccvi1223@qq.com
- 工程最低版本：`.macOS(.v14)`（`Package.swift`）——不抬到 26 的理由同 BoxMouse 家族：抬上去换不到任何东西，却让 14 / 15 上一行都跑不起来

---

## 功能（1.0.20 已实现）

| 位置 | 能力 |
| --- | --- |
| 菜单栏左键 | 呼出面板 |
| 菜单栏右键 | 打开面板 / 暂停记录·恢复记录 / 记录富文本 / 设置… / 关于 / 使用帮助 / 退出 |
| 面板顶栏 | 图钉（点别处不自动收起）、搜索框「输入开始搜索…」、三视图切换（丰富 / 简洁 / 网格）、齿轮 |
| 分类 | 「全部」+ 收藏 / 链接 / 图片 / 文件 + 自建分类（在「设置 → 分类」里新建） |
| 双击 | 选中并粘贴 |
| ⌘ 单击 | 多选，工具条出现「已选 N 项」「收藏」「删除」「取消」+ 全选勾选框 |
| 右键菜单 | 粘贴 / 复制到剪贴板 / 复制为纯文本 / **OCR 文字到剪贴板** / 置顶 / 打开链接 / 在访达中显示 / 复制 HEX·RGB / 移到分类 / 删除 |
| 空格预览 | 图片大图（降采样 1200）、全文可选中、链接、HEX·RGB·HSL、文件列表 |
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

## 面板交互里的两个 SwiftUI 陷阱

| 陷阱 | 现象与原因 |
| --- | --- |
| **双击手势必须先挂** | SwiftUI 按"后挂的让位"解析同一视图上的多个点按手势。单击在前会把第一次点击消费掉，双击**永远不触发** |
| **少用 `.help`** | 每个 `.help` 都会挂一套 HelpView / 无障碍状态机。面板里条目一多，`HelpStyle` TypedElement 轻松上万个 |

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
3. 🔴 **ad-hoc 签名下不要附加任何受限授权**（`com.apple.developer.*`），会让 launchd spawn 失败（POSIX 163）
4. **热键注册 API 的"先注册后清理"形状是刻意的**：早先的写法在 `register()` 内部先 `unregisterAll()`，于是注册第二个热键时把第一个一起清了，表现是**呼出热键静默失效**
5. **热键回调闭包不能捕获上下文**：它被当成 C 函数指针传下去
6. **`LSUIElement` 应用的最小主菜单不能删**：没有系统菜单栏，文本框就按不出 ⌘C / ⌘V / ⌘A

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

## 数据位置

| 数据 | 路径 |
| --- | --- |
| 历史元数据 | `~/Library/Application Support/BoxPaste/history.json` |
| 图片 / 富文本 blob | 同目录 `blobs/<hash>.png`、`<hash>@thumb.png`、`<hash>.rtf`、`<hash>.html` |
| 配置 | UserDefaults，键 `com.pcxx.boxpaste.preferences`（JSON 编码） |
| 面板位置 | UserDefaults 键 `com.pcxx.boxpaste.panelOriginX / Y` |
| 开机启动 | `~/Library/LaunchAgents/com.pcxx.boxpastemac.plist` |

缩略图缓存只在内存里（`NSCache`，400 条 / 20 MB），**不落盘**。

## 一个已经量过的结论

1.0.20 实测：macOS 26 上 `malloc_zone_pressure_relief` **恒返回 0** —— 现在的分配器 free 时就把页还给内核了，所谓"释放内存"在这里没有可释放的对象。做过对照实验才敢下这个结论，别再重复实现一遍。
