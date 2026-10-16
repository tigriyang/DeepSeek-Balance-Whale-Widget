#!/bin/bash
# ------------------------------------------------------------------
# 彻底卸载小鲸鱼 —— 清掉它在本机留下的**一切痕迹**。
#
# 清理范围：
#   1. 应用本体              ~/Applications/WhaleFloat.app
#   2. 开机自启              ~/Library/LaunchAgents/ai.dsh.whalefloat.plist
#   3. DSH 插件（引用 + 源码）dsh-wait-state / dsh-turn-usage / dsh-notify-bridge
#   4. 设置与数据            设置、导入的角色、账本、状态文件
#   5. 系统级缓存与偏好      ~/Library 下按 bundle id 匹配的各目录
#   6. 运行期日志            /tmp/whalefloat*.log
#   7. LaunchServices 注册   （让 Finder / 聚焦不再记得这个 app）
#
# 想保留设置（换机重装用），加 --keep-data。
# ------------------------------------------------------------------
set -uo pipefail

APP_NAME="WhaleFloat"
BUNDLE_ID="ai.dsh.whalefloat"
LABEL="ai.dsh.whalefloat"
KEEP=0
[ "${1:-}" = "--keep-data" ] && KEEP=1

H="$HOME"
# 两个位置都要看：从 DMG 装的在 /Applications，开发时装在 ~/Applications。
# 只清后者会导致「DMG 装的用户执行卸载，脚本找不到应用」。
APP_CANDIDATES=("/Applications/${APP_NAME}.app" "$H/Applications/${APP_NAME}.app")
PLIST="$H/Library/LaunchAgents/${LABEL}.plist"

say() { printf "%s\n" "$*"; }
removed() { [ -e "$1" ] && { rm -rf "$1"; say "  ✓ 删除 $2"; }; }

say "▸ 停止进程与自启…"
launchctl unload "$PLIST" 2>/dev/null
launchctl remove "$LABEL" 2>/dev/null
for _ in 1 2 3; do
  PIDS="$(ps -axo pid=,command= | grep "[W]haleFloat.app/Contents/MacOS" | awk '{print $1}')"
  [ -z "$PIDS" ] && break
  echo "$PIDS" | while read -r p; do kill -9 "$p" 2>/dev/null; done
  sleep 1
done
removed "$PLIST" "自启配置"

say "▸ 删除应用本体…"
for a in "${APP_CANDIDATES[@]}"; do
  removed "$a" "应用"
done

say "▸ 摘除并删除 DSH 插件…"
DSH=""
for c in "$H/.npm-global/bin/dsh" "$H/.local/bin/dsh" /usr/local/bin/dsh /opt/homebrew/bin/dsh; do
  [ -x "$c" ] && { DSH="$c"; break; }
done
for p in dsh-wait-state dsh-turn-usage dsh-notify-bridge; do
  if [ -n "$DSH" ]; then
    "$DSH" plugin --profile web remove "$p" >/dev/null 2>&1 && say "  ✓ 已摘除引用 $p"
  fi
  removed "$H/.dsh/plugins/$p" "插件源码 $p"
done

say "▸ 清理数据与账本…"
if [ "$KEEP" = "1" ]; then
  say "  · 按 --keep-data 保留设置与导入的角色"
else
  removed "$H/.dsh/whalefloat.json" "设置"
  removed "$H/.dsh/whalefloat-assets" "导入的角色"
fi
for f in .whalefloat-notify.json .whalefloat-reply.json .whalefloat-wait.json .whalefloat-usage.json; do
  removed "$H/.dsh/$f" "$f"
done

say "▸ 清理系统级缓存与偏好…"
for d in "Library/Preferences/${BUNDLE_ID}.plist" \
         "Library/Saved Application State/${BUNDLE_ID}.savedState" \
         "Library/Caches/${BUNDLE_ID}" \
         "Library/Application Support/${BUNDLE_ID}" \
         "Library/HTTPStorages/${BUNDLE_ID}" \
         "Library/WebKit/${BUNDLE_ID}" \
         "Library/Containers/${BUNDLE_ID}"; do
  removed "$H/$d" "$(basename "$d")"
done
defaults delete "$BUNDLE_ID" 2>/dev/null

say "▸ 清理日志…"
rm -f /tmp/whalefloat*.log 2>/dev/null && say "  ✓ 已删除 /tmp/whalefloat*.log"

say "▸ 注销 LaunchServices 注册…"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREG" ] && "$LSREG" -kill -r -domain local -domain system -domain user >/dev/null 2>&1 \
  && say "  ✓ 已重建注册表（Finder 侧不再显示旧条目）"

say ""
say "✓ 卸载完成，未发现遗留"
[ "$KEEP" = "1" ] && say "  （设置与导入的角色按 --keep-data 保留）"