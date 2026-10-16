#!/bin/bash
# ------------------------------------------------------------------
# WhaleFloat 安装脚本
#
# 从源码装出可用的应用。做四件事：
#   1. 编译并打包成 .app（含图标、角色素材、内置插件）
#   2. 装到 ~/Applications
#   3. 注册 launchd 自启（仅崩溃时拉起）
#   4. 启动它；首次运行时程序自己会提示安装配套插件
#
# 用法：  bash install.sh
# 卸载：  bash install.sh uninstall
# ------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="WhaleFloat"
APP="$HOME/Applications/${APP_NAME}.app"
PLIST_SRC="$HERE/ai.dsh.whalefloat.plist"
PLIST_DST="$HOME/Library/LaunchAgents/ai.dsh.whalefloat.plist"
LABEL="ai.dsh.whalefloat"

say() { printf '%s\n' "$*"; }

uninstall() {
  say "▸ 停止并移除自启…"
  launchctl unload "$PLIST_DST" 2>/dev/null
  rm -f "$PLIST_DST"
  pkill -f "${APP_NAME}.app/Contents/MacOS" 2>/dev/null
  say "▸ 删除应用…"
  rm -rf "$APP"
  say "✓ 已卸载（~/.dsh 下的配置与插件保留）"
  exit 0
}

[ "${1:-}" = "uninstall" ] && uninstall

# ── 前置检查 ────────────────────────────────────────────────
say "▸ 检查环境…"
command -v swift >/dev/null 2>&1 || { say "✗ 没找到 swift，请先装 Xcode 命令行工具：xcode-select --install"; exit 1; }
say "  swift: $(swift --version 2>&1 | head -1)"

if [ ! -d "$HOME/.dsh" ]; then
  say "  ⚠ 没发现 ~/.dsh —— 小鲸鱼依赖 DSH 才能取到余额与消耗数据。"
  say "    仍会安装，但功能会受限。"
fi

# ── 编译打包 ────────────────────────────────────────────────
say "▸ 编译并打包…"
bash "$HERE/build-app.sh" || { say "✗ 打包失败"; exit 1; }

# ── 自启 ────────────────────────────────────────────────────
say "▸ 注册开机自启（仅崩溃时自动拉起）…"
if [ -f "$PLIST_SRC" ]; then
  launchctl unload "$PLIST_DST" 2>/dev/null
  # plist 里的 __HOME__ 是占位符 —— launchd 不做变量展开，
  # 所以安装时替换成实际路径
  sed "s|__HOME__|$HOME|g" "$PLIST_SRC" > "$PLIST_DST"
  launchctl load -w "$PLIST_DST" 2>/dev/null
  say "  已注册：$LABEL"
else
  say "  ⚠ 缺少 $PLIST_SRC，跳过自启"
fi

# ── 启动 ────────────────────────────────────────────────────
say "▸ 启动…"
sleep 2
if ! pgrep -f "${APP_NAME}.app/Contents/MacOS" >/dev/null 2>&1; then
  open "$APP"
fi

say ""
say "✓ 安装完成"
say ""
say "  应用位置   $APP"
say "  配置       ~/.dsh/whalefloat.json"
say "  角色素材   ~/.dsh/whalefloat-assets/（导入的图）"
say ""
say "  首次运行若弹出「还差 N 个配套插件」，点「安装」即可。"
say "  那两个插件挂在 DSH 上采集「等待回答」与「每轮消耗」，装完需重启一次 DSH。"
say ""
say "  退出：右键鲸鱼 →「退出浮窗」，或「完全退出（并关闭 DSH）」"