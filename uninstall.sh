#!/bin/bash
# ------------------------------------------------------------------
# 卸载小鲸鱼
#
# 做三件事：
#   1. 移除 launchd 自启
#   2. 删除应用本体
#   3. 停用它安装到 DSH 的插件（从 profile 里摘掉）
#
# **不动**用户的数据：
#   ~/.dsh/whalefloat.json          设置
#   ~/.dsh/whalefloat-assets/       导入的角色图
#   ~/.dsh/plugins/dsh-*            插件源码（只从 profile 摘除引用）
# 想要彻底清干净，加 --purge。
# ------------------------------------------------------------------
set -uo pipefail

APP_NAME="WhaleFloat"
LABEL="ai.dsh.whalefloat"
APP="$HOME/Applications/${APP_NAME}.app"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

say() { printf '%s\n' "$*"; }

say "▸ 停止并移除自启…"
launchctl unload "$PLIST" 2>/dev/null
rm -f "$PLIST"

say "▸ 结束进程…"
ps -axo pid=,command= | grep "[W]haleFloat.app/Contents/MacOS" | awk '{print $1}' \
  | while read p; do kill -9 "$p" 2>/dev/null; done
sleep 1

say "▸ 删除应用本体…"
rm -rf "$APP"

# ── 摘除 DSH 插件引用 ────────────────────────────────────────
say "▸ 停用 DSH 插件…"
DSH=""
for c in "$HOME/.npm-global/bin/dsh" "$HOME/.local/bin/dsh" /usr/local/bin/dsh /opt/homebrew/bin/dsh; do
  [ -x "$c" ] && { DSH="$c"; break; }
done
if [ -n "$DSH" ]; then
  for p in dsh-wait-state dsh-turn-usage dsh-notify-bridge; do
    "$DSH" plugin --profile web remove "$p" > /dev/null 2>&1 \
      && say "  ✓ 已摘除 $p" || say "  · $p 未安装"
  done
else
  say "  ⚠ 没找到 dsh 命令，插件引用需手动移除："
  say "     dsh plugin --profile web remove dsh-wait-state"
fi

if [ "$PURGE" = "1" ]; then
  say "▸ 清理数据（--purge）…"
  rm -rf "$HOME/.dsh/whalefloat.json"
  rm -rf "$HOME/.dsh/whalefloat-assets"
  rm -f "$HOME/.dsh/.whalefloat-notify.json" "$HOME/.dsh/.whalefloat-reply.json"
  rm -f "$HOME/.dsh/.whalefloat-wait.json" "$HOME/.dsh/.whalefloat-usage.json"
  rm -rf "$HOME/.dsh/plugins/dsh-wait-state" "$HOME/.dsh/plugins/dsh-turn-usage" "$HOME/.dsh/plugins/dsh-notify-bridge"
  say "  已删除设置、导入的角色、账本与插件源码"
fi

say ""
say "✓ 卸载完成"
[ "$PURGE" = "0" ] && say "  （设置与导入的角色保留在 ~/.dsh 下；要一并清掉请加 --purge）"
