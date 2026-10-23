#!/usr/bin/env bash
#
# ============================================================
# BoxPaste 打包脚本
#
# 产出 dist/BoxPaste.app —— 可双击、可拖进 /Applications 的原生应用。
#
# 用法：
#   ./build-app.sh                发布构建（release，带图标，ad-hoc 签名）
#   ./build-app.sh --debug        调试构建
#   ./build-app.sh --no-sign      跳过签名
#   ./build-app.sh --no-sandbox   让 swift build 跳过 SwiftPM 自带的沙箱
#   ./build-app.sh --install      构建完装到 /Applications
#   ./build-app.sh --bump         强制版本号 +1（即使源码没变）
#   ./build-app.sh --no-bump      保持版本号不变（指纹照常更新）
#   ./build-app.sh --clean        先清掉 .build 再构建
#
# 关于 --no-sandbox：正常终端里不需要它。只有当这个脚本本身运行在另一个沙箱内部时
# （受限 CI、容器、某些编辑器内置终端），SwiftPM 会让 sandbox-exec 再套一层沙箱，
# 而嵌套沙箱会被内核拒绝，报 `sandbox-exec: sandbox_apply: Operation not permitted`。
#
# 版本号：唯一来源是工程根目录的 VERSION 文件（一行，形如 1.0.0）。
#   递增规则：**源码真的变了才 +1**。脚本对影响产物的文件取一份 sha256 指纹，与
#   上次打包记在 VERSION.fingerprint 里的比较，不一致就把第三段 +1：
#   1.0.0 → 1.0.1 → 1.0.2。于是反复构建、只改文档不会白吃版本号——
#   而版本号在一个只有补丁位的方案里是**用掉就回不来**的，虚涨不可逆。
#   没有指纹文件（第一次打包）时**不递增**：1.0.0 是初版，不是「改出来的」。
# ============================================================

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_ROOT"

CONFIGURATION="release"
DO_SIGN=1
DO_INSTALL=0
FORCE_BUMP=0
SKIP_BUMP=0
DO_CLEAN=0
SWIFT_FLAGS=()

for argument in "$@"; do
    case "$argument" in
        --debug)      CONFIGURATION="debug" ;;
        --no-sign)    DO_SIGN=0 ;;
        --no-sandbox) SWIFT_FLAGS+=(--disable-sandbox) ;;
        --install)    DO_INSTALL=1 ;;
        --bump)       FORCE_BUMP=1 ;;
        --no-bump)    SKIP_BUMP=1 ;;
        --clean)      DO_CLEAN=1 ;;
        -h|--help)
            sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "未知参数：${argument}（用 --help 查看用法）" >&2
            exit 1
            ;;
    esac
done

APP_NAME="BoxPaste"
DISPLAY_NAME="BoxPaste"
DIST_DIR="$PROJECT_ROOT/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

# ------------------------------------------------------------
# 0. 版本号
# ------------------------------------------------------------

VERSION_FILE="$PROJECT_ROOT/VERSION"
FINGERPRINT_FILE="$PROJECT_ROOT/VERSION.fingerprint"

# 参与指纹的文件：影响产物或构建方式的东西。不含 dist/（产物）、
# .build/（中间物）、VERSION*（就是被它决定的东西，算进去会形成自指）。
# Resources/icon-source.png 由 Tools/make-icon-source.swift 确定性生成，
# 同样脚本产同样字节，不会平白触发 +1。
SOURCE_INPUTS=(Package.swift build-app.sh Sources Resources Tools)

read_version_file() {
    if [[ ! -f "$VERSION_FILE" ]]; then
        echo "错误：缺少 VERSION 文件（应包含一行形如 1.0.0 的版本号）" >&2
        exit 1
    fi
    local value
    value="$(tr -d '[:space:]' < "$VERSION_FILE")"
    if [[ ! "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "错误：VERSION 内容不合法：「${value}」。要求形如 1.0.0（三段数字）。" >&2
        exit 1
    fi
    printf '%s' "$value"
}

bump_patch_version() {
    local major minor patch
    IFS='.' read -r major minor patch <<< "$1"
    printf '%s.%s.%s' "$major" "$minor" "$((patch + 1))"
}

# 三段版本号 → 构建号。major*10000+minor*100+patch，少维护一份计数器，
# 且天然满足 Apple「构建号必须单调递增」的要求。
build_number_of() {
    local major minor patch
    IFS='.' read -r major minor patch <<< "$1"
    printf '%s' "$((major * 10000 + minor * 100 + patch))"
}

compute_source_fingerprint() {
    local records=()
    local path entry digest
    for path in ${SOURCE_INPUTS[@]+"${SOURCE_INPUTS[@]}"}; do
        [[ -e "$PROJECT_ROOT/$path" ]] || continue
        if [[ -d "$PROJECT_ROOT/$path" ]]; then
            while IFS= read -r -d '' entry; do
                digest="$(shasum -a 256 "$entry" | awk '{print $1}')"
                records+=("${entry#$PROJECT_ROOT/}:$digest")
            done < <(find "$PROJECT_ROOT/$path" -type f ! -name '.DS_Store' -print0)
        else
            digest="$(shasum -a 256 "$PROJECT_ROOT/$path" | awk '{print $1}')"
            records+=("${path}:$digest")
        fi
    done
    # NUL 分隔 + 排序：与 find 的返回顺序无关，否则同一份源码会产生多个指纹，
    # 每次构建都误判成「改了」。
    printf '%s\0' ${records[@]+"${records[@]}"} \
        | LC_ALL=C sort -z \
        | shasum -a 256 | awk '{print $1}'
}

CURRENT_VERSION="$(read_version_file)"
CURRENT_FINGERPRINT="$(compute_source_fingerprint)"

STORED_FINGERPRINT=""
if [[ -f "$FINGERPRINT_FILE" ]]; then
    STORED_FINGERPRINT="$(tr -d '[:space:]' < "$FINGERPRINT_FILE")"
fi

if [[ "$FORCE_BUMP" == "1" ]]; then
    APP_VERSION="$(bump_patch_version "$CURRENT_VERSION")"
    VERSION_REASON="--bump 强制递增"
elif [[ ! -f "$FINGERPRINT_FILE" ]]; then
    # 第一次打包：VERSION 里的号码就是初版号，不该被当成「改出来的下一个版本」吃掉。
    APP_VERSION="$CURRENT_VERSION"
    VERSION_REASON="首次打包，沿用 VERSION 里的初版号"
elif [[ "$SKIP_BUMP" == "1" ]]; then
    APP_VERSION="$CURRENT_VERSION"
    VERSION_REASON="--no-bump 保持版本号"
elif [[ "$CURRENT_FINGERPRINT" != "$STORED_FINGERPRINT" ]]; then
    APP_VERSION="$(bump_patch_version "$CURRENT_VERSION")"
    VERSION_REASON="源码有改动"
else
    APP_VERSION="$CURRENT_VERSION"
    VERSION_REASON="源码未变，沿用当前版本"
fi
APP_BUILD_NUMBER="$(build_number_of "$APP_VERSION")"

# 变量一律写成 ${X}：macOS 自带 bash 3.2，`$X` 后紧跟中文字符时会把它也算进
# 变量名，报一个看不出所以然的 unbound variable。
echo "${DISPLAY_NAME} 打包（${APP_NAME}）"
echo "────────────────────────────────────────────────────"
echo "  版本号：${APP_VERSION}（构建号 ${APP_BUILD_NUMBER}）· ${VERSION_REASON}"
echo "  构建配置：${CONFIGURATION}"
echo "  输出位置：${APP_DIR}"
echo ""

# ------------------------------------------------------------
# 1. 编译
# ------------------------------------------------------------
if [[ "$DO_CLEAN" == "1" ]]; then
    echo "▶ 清理 .build…"
    rm -rf "$PROJECT_ROOT/.build"
fi

echo "▶ 编译（${CONFIGURATION}）…"
swift build -c "$CONFIGURATION" --product "$APP_NAME" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"}

BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"})/$APP_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "错误：没有找到可执行文件 ${BIN_PATH}" >&2
    exit 1
fi
echo "  ✓ 可执行文件：${BIN_PATH}"

# ------------------------------------------------------------
# 2. 自检
#
# 放在打包之前：自检不过就不该产出 .app。让人把一个坏版本装进 /Applications，
# 比让他这会儿在终端里看见失败要糟得多。
#
# ⚠️ 铁律：自检**只能**跑 $BIN_PATH（.build 下的裸产物，不在任何 .app 里）。
#    绝不能 exec .app 内的二进制（Contents/MacOS/BoxPaste）——macOS 26 实测
#    那样做会让这个 bundle id 的菜单栏登记**永久失效**，只能换 id 恢复。
#    机制与对照数据见 Sources/BoxPaste/Core/AppIdentity.swift 头注释。
# ------------------------------------------------------------
echo "▶ 核心自检…"
if "$BIN_PATH" --selftest > /tmp/boxpaste-selftest.log 2>&1; then
    grep -E '^✓' /tmp/boxpaste-selftest.log | sed 's/^/  /' || true
else
    echo "  ✗ 自检未通过，停止打包。完整输出：/tmp/boxpaste-selftest.log" >&2
    tail -20 /tmp/boxpaste-selftest.log | sed 's/^/    /' >&2
    exit 1
fi

# ------------------------------------------------------------
# 3. 图标
#
# 母版（icon-source.png）每次都从脚本重新生成。脚本是确定性的：
# 同一份脚本产出逐字节相同的 PNG，指纹不会因此抖动。
# ⚠️ 不能"缺了才生成"——家族里踩过：改了母版脚本但旧 PNG 还在盘上，
# 于是新图标从没进过包，Dock 里一直是旧版。
# ------------------------------------------------------------
echo "▶ 生成图标…"
ICON_TMP="$(mktemp -d)"
swift "$PROJECT_ROOT/Tools/make-icon-source.swift" > /dev/null 2>&1 || true
if [[ ! -f "$PROJECT_ROOT/Resources/icon-source.png" ]]; then
    echo "  ⚠ 图标母版生成失败" >&2
fi
if swift "$PROJECT_ROOT/Tools/make-icon.swift" "$ICON_TMP" > /dev/null 2>&1 \
   && iconutil -c icns "$ICON_TMP/AppIcon.iconset" -o "$ICON_TMP/AppIcon.icns" 2>/dev/null; then
    ICON_READY=1
else
    # 图标只是门面，生成失败不该阻断交付
    ICON_READY=0
fi

# ------------------------------------------------------------
# 4. 组装 bundle
# ------------------------------------------------------------
echo "▶ 组装应用包…"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"
printf 'APPL????' > "$CONTENTS/PkgInfo"

# Info.plist：先在模板上做版本替换，再对**替换后的产物**校验。
# 校验模板通过说明不了注入后的结果也合法，顺序反过来最坏情况是
# 「校验通过、装出来的应用双击无反应」。
sed -e "s/__BOXPASTE_VERSION__/$APP_VERSION/g" \
    -e "s/__BOXPASTE_BUILD__/$APP_BUILD_NUMBER/g" \
    "$PROJECT_ROOT/Resources/Info.plist" > "$CONTENTS/Info.plist"

if grep -q '__BOXPASTE_' "$CONTENTS/Info.plist"; then
    echo "错误：Info.plist 里仍有未替换的占位符，版本注入不完整。" >&2
    exit 1
fi
plutil -lint "$CONTENTS/Info.plist" > /dev/null
echo "  ✓ Info.plist（版本 ${APP_VERSION} · 构建 ${APP_BUILD_NUMBER}）"

if [[ "$ICON_READY" == "1" ]]; then
    cp "$ICON_TMP/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
    echo "  ✓ AppIcon.icns"
else
    echo "  ⚠ 图标生成失败，使用系统默认图标（不影响功能）"
fi

# 帮助文档：「使用帮助」菜单项从 Bundle 里读它，漏拷等于入口点了没反应
if [[ -f "$PROJECT_ROOT/Resources/Help.html" ]]; then
    cp "$PROJECT_ROOT/Resources/Help.html" "$RESOURCES_DIR/Help.html"
    echo "  ✓ Help.html（帮助文档）"
else
    echo "  ⚠ 缺少 Resources/Help.html，「使用帮助」将不可用" >&2
fi
rm -rf "$ICON_TMP"

xattr -cr "$APP_DIR" 2>/dev/null || true

# ------------------------------------------------------------
# 5. 签名
# ------------------------------------------------------------
if [[ "$DO_SIGN" == "1" ]]; then
    echo "▶ 代码签名（ad-hoc）…"
    # ⚠️ ad-hoc 签名下不要附加任何受限授权（com.apple.developer.*）：
    # 家族里实测过 AMFI 会直接拒绝，launchd spawn failed（POSIX 163），
    # 应用打不开——比少个功能严重得多。
    codesign --force --sign - --timestamp=none "$APP_DIR" 2>&1 | sed 's/^/  /' || {
        echo "  ⚠ 签名失败，应用仍可运行，但权限记忆可能不稳定" >&2
    }
    if codesign --verify --deep --strict "$APP_DIR" 2>/dev/null; then
        echo "  ✓ 签名校验通过"
    else
        echo "  ⚠ 签名校验未通过（改用 --no-sign 可跳过这一步）" >&2
    fi
else
    echo "▶ 已跳过签名（--no-sign）"
fi

# ------------------------------------------------------------
# 6. 版本号落盘
#
# 放在最后、所有可能失败的步骤之后：中途失败不该吃掉一个版本号。
# ------------------------------------------------------------
printf '%s\n' "$APP_VERSION" > "$VERSION_FILE"
printf '%s\n' "$CURRENT_FINGERPRINT" > "$FINGERPRINT_FILE"

# ------------------------------------------------------------
# 7. 完成
# ------------------------------------------------------------
echo ""
echo "────────────────────────────────────────────────────"
echo "打包完成：${APP_DIR}"
echo "版本号：${APP_VERSION}（构建号 ${APP_BUILD_NUMBER}）"
echo ""
du -sh "$APP_DIR" | sed 's/^/  体积 /'

if [[ "$DO_INSTALL" == "1" ]]; then
    echo ""
    echo "▶ 安装到 /Applications…"
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP_DIR" "/Applications/"
    xattr -cr "/Applications/$APP_NAME.app" 2>/dev/null || true
    codesign --force --sign - --timestamp=none "/Applications/$APP_NAME.app" > /dev/null 2>&1 || true
    echo "  ✓ 已安装：/Applications/$APP_NAME.app"
fi

cat <<'TIPS'

首次使用
────────────────────────────────────────────────────
1) 启动
     双击 dist/BoxPaste.app。默认**不占 Dock**（菜单栏工具），
     启动后看菜单栏多出来的剪贴板图标。想让它占 Dock 就在
     「设置 → 通用 → 在 Dock 中显示图标」打开。
     如果是从别人机器上拷来的副本，第一次打开请右键 → 打开
     （ad-hoc 签名在别的机器上会被 Gatekeeper 拦一次）。

2) 呼出面板
     默认 ⇧⌘V（可在「设置 → 快捷键」里改）。

3) 自动粘贴（可选）
     回车粘贴时需要"辅助功能"授权才能自动替你按 ⌘V。
     未授权时不会报错，只是降级成「内容已复制，你自己按 ⌘V」。
     授权入口：「设置 → 通用 → 自动粘贴 → 打开系统设置」。

4) 自检 / 诊断
     ⚠️ 不要直接执行 .app 里的二进制（Contents/MacOS/BoxPaste）！
        macOS 26 上那样做会把这个 bundle id 的菜单栏登记永久搞坏，
        图标从此再也不会出现在菜单栏上，只能换 bundle id 恢复。
     要跑自检或带 --show-panel 之类的诊断参数，用 .build 下的裸产物
     （不在 .app 里，安全，而且照样能落位）：
        .build/release/BoxPaste --selftest
        .build/release/BoxPaste --show-panel
     打包后的 .app 请双击启动（经 LaunchServices），不要从终端 exec 它。
TIPS
