#!/bin/bash
#
# wifi-watch.sh — 记录网络稳定性（支持 Wi-Fi 和手机热点两种主链路）
#
# 用法：
#   ./wifi-watch.sh              # 一直跑，日志写到 ~/wifi-watch.log
#   ./wifi-watch.sh /tmp/a.log   # 指定日志路径
#   ./wifi-watch.sh --once       # 只采样一次
#   Ctrl-C 停止
#
# 每轮记录：当前主链路、链路状态、RSSI/信道/速率（仅 Wi-Fi）、到网关和公网的丢包/延迟。
# 发现掉线时自动追加当时的 airportd 日志。
#
set -u

LOG="$HOME/wifi-watch.log"
ONCE=0
for arg in "$@"; do
  case "$arg" in
    --once) ONCE=1 ;;
    *) LOG="$arg" ;;
  esac
done

INTERVAL="${WIFI_WATCH_INTERVAL:-10}"
IFACE="en0"
BLOCK_COOLDOWN="${WIFI_WATCH_BLOCK_COOLDOWN:-600}"   # 掉线现场块的限流间隔（秒）
STATE_FILE="${WIFI_WATCH_STATE:-$HOME/.wifi-watch-block-time}"

# ping 统计 -> "loss% avg_ms"
ping_stat() {
  local out loss avg
  out=$(ping -c 4 -i 0.4 -W 900 -t 3 "$1" 2>/dev/null | tail -3)
  loss=$(printf '%s\n' "$out" | sed -n 's/.* \([0-9.]*\)% packet loss.*/\1/p' | tail -1)
  avg=$(printf '%s\n' "$out" | sed -n 's/.*min\/avg\/max\/stddev = [0-9.]*\/\([0-9.]*\)\/.*/\1/p' | tail -1)
  echo "${loss:-100} ${avg:--}"
}

primary_if() {
  route -n get default 2>/dev/null | awk '/interface:/{print $2}'
}

sample() {
  local ts pif active sp raw rssi noise ch rate gw_loss gw_avg net_loss net_avg bad wififield gw_host
  ts=$(date '+%F %T')
  pif=$(primary_if)
  [ -z "$pif" ] && pif="none"

  if ifconfig "$pif" 2>/dev/null | grep -q 'status: active'; then
    active=UP
  else
    active=DOWN
  fi

  if [ "$pif" = "$IFACE" ] && [ "$active" = "UP" ]; then
    sp=$(system_profiler SPAirPortDataType 2>/dev/null)
    raw=$(printf '%s\n' "$sp" | awk '/Current Network Information:/ {c=1} c && /Signal \/ Noise:/ {print; exit}')
    rssi=$(printf '%s' "$raw" | sed -E 's/.*Signal \/ Noise: (-?[0-9]+) dBm.*/\1/')
    noise=$(printf '%s' "$raw" | sed -E 's/.*\/ (-?[0-9]+) dBm.*/\1/')
    ch=$(printf '%s\n' "$sp" | sed -n 's/^ *Channel: \(.*\)$/\1/p' | head -1)
    rate=$(printf '%s\n' "$sp" | sed -n 's/.*Transmit Rate: \([0-9]*\).*/\1/p' | head -1)
    gw_host=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')
    read -r gw_loss gw_avg <<<"$(ping_stat "${gw_host:-192.168.1.1}")"
    wififield="wifi=on"
  else
    rssi="-" noise="-" ch="-" rate="-"
    gw_loss="-" gw_avg="-"
    wififield="wifi=off"
  fi

  read -r net_loss net_avg <<<"$(ping_stat 1.1.1.1)"

  printf '%s  if=%-4s link=%-4s %s rssi=%-4s noise=%-4s ch=%-18s rate=%-4s gw=%s%%/%sms net=%s%%/%sms\n' \
    "$ts" "$pif" "$active" "$wififield" "$rssi" "$noise" "$ch" "$rate" \
    "$gw_loss" "$gw_avg" "$net_loss" "$net_avg" | tee -a "$LOG"

  # 掉线判定：链路断 / 公网全丢
  bad=0
  [ "$active" = "DOWN" ] && bad=1
  awk -v l="$net_loss" 'BEGIN{exit !(l+0>=100)}' && bad=1

  if [ "$bad" = 1 ] && [ "$pif" = "$IFACE" ]; then
    now=$(date +%s)
    last=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
    if [ $((now - last)) -lt "$BLOCK_COOLDOWN" ]; then
      printf '%s  [掉线限流] 距上次展开 %ss，未重复记录系统日志\n' \
        "$ts" "$((now - last))" >>"$LOG"
    else
      echo "$now" >"$STATE_FILE"
      {
      echo "---- 掉线现场 $ts ----"
      echo "[接口] $(ipconfig getsummary "$IFACE" 2>/dev/null | awk -F' : ' '/Router|yiaddr/{gsub(/^ +/,"",$2); printf "%s=%s ", $1, $2}')"
      echo "[日志]"
      log show --last 3m --style compact \
        --predicate 'process == "airportd" AND (eventMessage CONTAINS "disassoc" OR eventMessage CONTAINS "linkDown" OR eventMessage CONTAINS "ROAMED")' \
        2>/dev/null | tail -15
      echo
      } >>"$LOG"
    fi
  fi
}

if [ "$ONCE" = "1" ]; then
  sample
  exit 0
fi

echo "wifi-watch 开始，日志：${LOG}（Ctrl-C 停止）"
while true; do
  sample
  sleep "$INTERVAL"
done
