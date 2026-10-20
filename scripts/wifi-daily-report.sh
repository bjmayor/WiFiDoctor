#!/bin/bash
#
# wifi-daily-report.sh — 每天凌晨生成昨日网络质量报告
#
# 由 launchd 在 05:05 触发，输出写入 ~/wifi-reports/YYYY-MM-DD.txt
#
set -uo pipefail

REPO="$HOME/data/codestation/git/WiFiDoctor"
OUT_DIR="$HOME/wifi-reports"
LOG_SRC="$HOME/wifi-watch.log"

# 昨天日期
YESTERDAY="$(date -v-1d +%Y-%m-%d)"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/$YESTERDAY.txt"

{
  echo "======================================================"
  echo " 网络质量日报  $YESTERDAY"
  echo " 生成时间：$(date '+%Y-%m-%d %H:%M:%S')"
  echo "======================================================"
  echo
} > "$OUT"

if [ ! -f "$LOG_SRC" ]; then
  echo "日志不存在：$LOG_SRC" >> "$OUT"
  exit 0
fi

if ! grep -q "^$YESTERDAY" "$LOG_SRC"; then
  echo "昨日无采样记录（可能未运行或当天没有数据）" >> "$OUT"
else
  cd "$REPO" || exit 1
  {
    echo "【按小时】"
    echo
    python3 wifi-report.py --log "$LOG_SRC" --bin 60 --date "$YESTERDAY"
    echo
    echo "【按 30 分钟】"
    echo
    python3 wifi-report.py --log "$LOG_SRC" --bin 30 --date "$YESTERDAY"
  } >> "$OUT" 2>&1
fi

# 保留最近 60 天
find "$OUT_DIR" -name "*.txt" -mtime +60 -delete 2>/dev/null

echo "报告已生成：$OUT"