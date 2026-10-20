#!/bin/bash
# ------------------------------------------------------------------
# 打包成 DMG 安装包
#
# 产物：dist/WhaleFloat-<版本>.dmg
#   打开后会看到一个 WhaleFloat.app 和指向「应用程序」的快捷方式，
#   拖进去即完成安装（macOS 的标准安装方式）。
#
# 拖进 /Applications 后首次运行时，程序会自己装好 launchd 自启，
# 并静默安装配套插件 —— 不需要再跑任何脚本。
#
# 这个脚本**不覆盖 /Applications 里的开发版**：发布包在临时目录里组装、
# ad-hoc 签名，再打进 DMG。开发机上的应用保持「WhaleFloat Dev」自签名，
# 反复打包不会让 TCC（日历等）权限失效。
# ------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="WhaleFloat"
VOL_NAME="小鲸鱼"
DIST="$HERE/dist"

# 版本号从源码取。用 grep -r 扫整个目录 ——
# 它原先在 Menu.swift，随 AppInfo 拆出去后这里读不到，静默回退成 0.1.0，
# 于是 dmg 名字永远是旧的。
# 与 build-app.sh 一致：整串版本号（含 -alpha / -beta 后缀）。
VERSION="$(grep -rhoE 'static let version = "[^"]+"' "$HERE/Sources/WhaleFloat/" 2>/dev/null \
  | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
[ -z "$VERSION" ] && VERSION="0.1.0"

OUT="$DIST/${APP_NAME}-${VERSION}.dmg"

echo "▸ 构建发布包（不覆盖本机 /Applications）…"
BUILD_STAGE="$(mktemp -d)"
DMG_STAGE="$(mktemp -d)"
trap 'rm -rf "$BUILD_STAGE" "$DMG_STAGE"' EXIT
STAGE_DIR="$BUILD_STAGE" RELEASE=1 bash "$HERE/build-app.sh"

APP="$BUILD_STAGE/${APP_NAME}.app"
[ -d "$APP" ] || { echo "✗ 找不到 $APP"; exit 1; }

echo "▸ 准备 DMG 内容…"
mkdir -p "$DIST"
rm -f "$OUT"

cp -R "$APP" "$DMG_STAGE/"
# 指向 /Applications 的快捷方式 —— 用户拖进去即可
ln -s /Applications "$DMG_STAGE/应用程序"
# 素材来源与许可 —— 放在安装盘根部，不打开应用也能看到
if [ -f "$HERE/NOTICE-ASSETS.md" ]; then
  cp "$HERE/NOTICE-ASSETS.md" "$DMG_STAGE/素材来源与许可.md"
fi

echo "▸ 生成 DMG…"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$DMG_STAGE" \
  -ov -format UDZO \
  "$OUT" > /dev/null

# 固定文件名的一份副本，供 README 里的安装链接使用。
#
# releases/latest/download/<name> 认的是「最新 release 里叫这个名字的资产」。
# 若链接里带版本号，下个版本一发布它立刻 404 —— 而那是安装主路径。
# 有了这份固定名，README 写 .../latest/download/WhaleFloat.dmg 就永久有效。
STABLE="$DIST/${APP_NAME}.dmg"
cp "$OUT" "$STABLE"

echo ""
echo "✓ 已生成：$OUT"
echo "  大小：$(du -h "$OUT" | cut -f1)"
echo "✓ 固定名副本：$STABLE（发版时一并上传，README 用它）"
echo ""
echo "  安装：双击打开，把「小鲸鱼」拖进「应用程序」"
echo "  卸载：bash uninstall.sh"
