#!/bin/bash
# ------------------------------------------------------------------
# WhaleFloat 打包脚本
#
# 把 SwiftPM 的可执行文件打成标准 macOS .app bundle，装到 ~/Applications。
#
# 为什么要 .app 而不是裸可执行文件：
#   · 系统把它当正式应用对待（Dock/通知/权限归属都正常）
#   · Resources 有标准位置，素材随包走，不依赖外部路径
#   · launchd 可直接按 app 路径启动
# ------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="WhaleFloat"
BUNDLE_ID="ai.dsh.whalefloat"
# 版本号从源码读。它在 AppInfo.swift 里，
# 原先在 Menu.swift —— 拆分文件后这里的路径没跟着改，
# 读不到就回退成 0.1.0，Finder 里于是看到旧版本。
# 用 grep -r 扫整个源码目录，以后再搬家也不会失效。
VERSION="$(grep -rhoE 'static let version = "[0-9.]+"' "$HERE/Sources/WhaleFloat/" 2>/dev/null \
  | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
[ -z "$VERSION" ] && VERSION="0.1.0"
# 装到系统的 /Applications —— Finder 侧边栏「应用程序」指向的是这里，
# 装到 ~/Applications 的话在侧边栏里看不到，也不符合拖进「应用程序」的直觉。
# 普通用户对 /Applications 有写权限，不需要 sudo。
DEST="/Applications/${APP_NAME}.app"

echo "▸ 编译 release 版本…"
cd "$HERE"
swift build -c release 2>&1 | tail -3

BIN="$(swift build -c release --show-bin-path)/${APP_NAME}"
[ -x "$BIN" ] || { echo "✗ 找不到可执行文件 $BIN"; exit 1; }

echo "▸ 组装 app bundle…"
rm -rf "$DEST"
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"

cp "$BIN" "$DEST/Contents/MacOS/${APP_NAME}"

# 素材随包走 —— 程序自足，不依赖 ~/.dsh 下的路径
# png=角色立绘  gif=摸摸头动画  mp3=按压音效  icns=应用图标
for ext in png gif mp3 wav icns; do
  for f in "$HERE/Resources/"*."$ext"; do
    [ -f "$f" ] && cp "$f" "$DEST/Contents/Resources/"
  done
done

# 内置法定节假日数据（官方发布，见 HolidayCalendar.swift）。
# 随包放几年，离线也能用；联网后会自行更新到更新的年份。
if [ -d "$HERE/Resources/holidays" ]; then
  rm -rf "$DEST/Contents/Resources/holidays"
  cp -R "$HERE/Resources/holidays" "$DEST/Contents/Resources/holidays"
  echo "  内置节假日数据：$(ls "$HERE/Resources/holidays" | tr '\n' ' ')"
fi

# 内置 launchd 模板 —— 首次运行时程序自己装自启，
# 这样从 DMG 拖进「应用程序」就能用，不需要再跑 install.sh。
cp "$HERE/ai.dsh.whalefloat.plist" "$DEST/Contents/Resources/launchagent.plist"

# 内置 DSH 启动器 —— 「启动 DSH GUI」菜单要用。
# 原先写死的是 ~/dsh-workspace/... 下的路径，换台机器必然找不到；
# 随包带一份，运行时优先用包内的。
LAUNCHER_SRC="$HOME/dsh-workspace/.dsh/skills/dsh-launcher/scripts/dsh-launcher.sh"
if [ -f "$LAUNCHER_SRC" ]; then
  cp "$LAUNCHER_SRC" "$DEST/Contents/Resources/dsh-launcher.sh"
  echo "  内置启动器：dsh-launcher.sh"
fi

# 内置「中介」插件 —— 它们挂在 DSH 上采集事件，本程序读文件。
#
# 源从**项目目录**取，不是从 ~/.dsh/plugins/。
# 后者是安装目标：卸载脚本会把它清掉，从那里读会导致
# 「卸过一次之后，再构建出来的包里就没有插件了」。
mkdir -p "$DEST/Contents/Resources/plugins"
for p in dsh-wait-state dsh-turn-usage dsh-notify-bridge; do
  SRC_PLUGIN="$HERE/plugins/$p"
  if [ -d "$SRC_PLUGIN" ]; then
    rm -rf "$DEST/Contents/Resources/plugins/$p"
    cp -R "$SRC_PLUGIN" "$DEST/Contents/Resources/plugins/$p"
    echo "  内置插件：$p"
  else
    echo "  ⚠ 项目里缺少插件源码：$SRC_PLUGIN"
  fi
done

cat > "$DEST/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>小鲸鱼</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <!-- 必须 >= 26：系统按「链接 SDK 版本」决定是否启用 Liquid Glass。
         写 13.0 时实测 NSPopover 给的是纯白底，不是系统材质。 -->
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <!-- 进 Dock，有图标（可在 Dock 上右键退出/切换） -->
    <key>LSUIElement</key><false/>
    <key>NSHighResolutionCapable</key><true/>
    <!-- 读系统日历只为判断「今天是不是法定假日」。
         没有这一项时系统不会弹授权框，而是直接拒绝。 -->
    <key>NSCalendarsUsageDescription</key>
    <string>读取「中国大陆节假日」日历，用于判断当前是高峰还是低谷计价。只读节假日标记，不读你个人的日程。</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>读取「中国大陆节假日」日历，用于判断当前是高峰还是低谷计价。只读节假日标记，不读你个人的日程。</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
PLIST

# 签名策略：本地构建与发布包分开。
#
#   本地构建（默认）    用自签名证书「WhaleFloat Dev」
#                       → TCC 认证书身份，反复构建也不会重置权限
#   发布包（RELEASE=1） 用 ad-hoc
#                       → 自签名证书不在用户机器上，分发出去反而多一层
#                         「未知证书」的恐吓提示。反正都要右键打开，
#                         ad-hoc 更干脆。
#
# 另一个事实：分发的 app 不会重建，CDHash 固定，权限本来就稳定 ——
# 「权限反复要」只是开发期的现象。
SIGN_ID="WhaleFloat Dev"

if [ "${RELEASE:-0}" = "1" ]; then
    echo "▸ 签名（发布包：ad-hoc）…"
    codesign --force --deep --sign - "$DEST" 2>&1 | tail -1 \
        || echo "（签名跳过，本地运行不受影响）"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    echo "▸ 签名（本地构建：$SIGN_ID）…"
    codesign --force --deep --sign "$SIGN_ID" "$DEST" 2>&1 | tail -1 \
        || echo "（签名失败，回退 ad-hoc）"
else
    echo "▸ 签名（未找到证书，回退 ad-hoc）…"
    codesign --force --deep --sign - "$DEST" 2>&1 | tail -1 \
        || echo "（签名跳过，本地运行不受影响）"
fi
echo "  运行：open "$DEST""