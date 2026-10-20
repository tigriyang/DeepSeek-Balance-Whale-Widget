#!/bin/bash
# ------------------------------------------------------------------
# 列出上游最近一段时间的“值得看”的提交，供人工判断是否移植。
#
# 这不是同步脚本 —— 不要 merge、不要 rebase、不要 cherry-pick 整条线。
# 上游是 JS 网页插件，本仓库是 Swift 应用；能跟的只有界面/交互/素材类改动。
#
# 用法：
#   bash tools/upstream-review.sh              # 最近 30 天
#   bash tools/upstream-review.sh "60 days ago"
# ------------------------------------------------------------------
set -uo pipefail

SINCE="${1:-30 days ago}"
REMOTE="${UPSTREAM_REMOTE:-upstream}"

if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
  echo "✗ 没有 $REMOTE remote。先加："
  echo "  git remote add upstream https://github.com/MeteorNOX/DeepSeek-Balance-Whale-Widget.git"
  exit 1
fi

echo "▸ 拉取 $REMOTE（只 fetch，不合并）…"
git fetch --quiet --no-tags "$REMOTE" main || {
  echo "✗ fetch 失败（网络？），下面用本地已有的 $REMOTE/main 继续"
}

echo ""
echo "上游 $SINCE 以来触及界面 / 交互 / 素材的提交："
echo "────────────────────────────────────────────────────────"
git log "$REMOTE/main" --since="$SINCE" --date=short \
  --pretty=format:'%h %ad %s' -- assets lib README.md PROVENANCE.md 2>/dev/null

echo ""
echo "────────────────────────────────────────────────────────"
echo "只看，不自动合并。决定移植的，读 diff 后手写或挑独立小提交："
echo "  git show <sha> -- assets/whale-widget.js"
echo "  git log $REMOTE/main --since=\"$SINCE\" --stat -- assets lib"
