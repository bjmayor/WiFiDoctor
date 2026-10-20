#!/bin/bash
#
# wifi-guard.sh — 断网 / 链路劣化时自动把 Wi-Fi 拉回来（给酒店/公共 Wi-Fi 用）
#
# 两种触发：
#   1) 完全不通：连续 N 次探测失败 → 关/开一次 Wi-Fi
#   2) 链路劣化：连续 M 次网关丢包 ≥ 阈值 → 关/开一次 Wi-Fi（换 AP）
#      劣化触发后有冷却期，避免反复折腾 AP
#
# 安全约束（避免干扰手机热点）：
#   - 只有当前默认路由在 Wi-Fi (en0) 上时才会动手
#   - Wi-Fi 电源已关闭时不动手
#   - 主链路是热点/USB 网卡时，只记录，不碰 Wi-Fi
#
# 用法：
#   ./wifi-guard.sh            # 正常跑
#   ./wifi-guard.sh --dry-run  # 只记录「本来会做什么」，不动真格
#   Ctrl-C 停止
#
# 可调环境变量：
#   WIFI_GUARD_INTERVAL=20        探测间隔（秒）
#   WIFI_GUARD_FAILS=3            连续失败几次才动手
#   WIFI_GUARD_LOSS=50            丢包阈值（%）
#   WIFI_GUARD_LOSS_CYCLES=3      连续几次超过阈值才动手
#   WIFI_GUARD_COOLDOWN=900       劣化触发的冷却时间（秒）
#   WIFI_GUARD_LOG=~/x.log        日志路径
#
set -u

IFACE="en0"
INTERVAL="${WIFI_GUARD_INTERVAL:-20}"
FAIL_LIMIT="${WIFI_GUARD_FAILS:-3}"
LOSS_LIMIT="${WIFI_GUARD_LOSS:-50}"
LOSS_CYCLES="${WIFI_GUARD_LOSS_CYCLES:-3}"
COOLDOWN="${WIFI_GUARD_COOLDOWN:-900}"
LOG="${WIFI_GUARD_LOG:-$HOME/wifi-guard.log}"
DRY=0
for arg in "$@"; do
  [ "$arg" = "--dry-run" ] && DRY=1
done

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }

primary_if() { route -n get default 2>/dev/null | awk '/interface:/{print $2}'; }
gateway_ip() { route -n get default 2>/dev/null | awk '/gateway:/{print $2}'; }
wifi_power_on() { networksetup -getairportpower "$IFACE" 2>/dev/null | grep -q "On"; }

healthy() {
  if [ "$(primary_if)" = "$IFACE" ]; then
    ifconfig "$IFACE" 2>/dev/null | grep -q 'status: active' || return 1
  fi
  # 先 ICMP；公共网络经常禁 ping，再用 TCP 443 兜底，避免误判
  ping -c 1 -W 1000 -t 3 1.1.1.1 >/dev/null 2>&1 && return 0
  nc -z -G 3 -w 3 1.1.1.1 443 >/dev/null 2>&1
}

# 到网关的丢包率（4 包、1 秒间隔，避开路由器对高频 ICMP 的限速）
gw_loss() {
  local host out loss
  host="$(gateway_ip)"
  [ -z "$host" ] && { echo 0; return; }
  out=$(ping -c 4 -i 1 -W 900 -t 6 "$host" 2>/dev/null | tail -2)
  loss=$(printf '%s\n' "$out" | sed -n 's/.* \([0-9.]*\)% packet loss.*/\1/p' | tail -1)
  echo "${loss:-100}"
}

recycle_wifi() {
  local reason="$1" after
  if [ "$DRY" = "1" ]; then
    log "[dry-run] 会重启 Wi-Fi（原因：${reason}）"
    return
  fi
  log "重启 Wi-Fi（原因：${reason}）"
  if ! networksetup -setairportpower "$IFACE" off 2>/dev/null; then
    log "setairportpower 失败，可能需要 sudo"
    return
  fi
  sleep 3
  networksetup -setairportpower "$IFACE" on 2>/dev/null
  sleep 12
  if healthy; then
    after=$(gw_loss)
    log "重连成功，网关丢包 ${after}%"
  else
    log "重连后仍不通：可能是酒店认证过期 / 上游故障"
  fi
}

fails=0
badq=0
cycles=0
last_qual=0
log "wifi-guard 启动：间隔 ${INTERVAL}s，失败阈值 ${FAIL_LIMIT} 次，丢包阈值 ${LOSS_LIMIT}%x${LOSS_CYCLES}，冷却 ${COOLDOWN}s，dry-run=${DRY}"

while true; do
  if healthy; then
    if [ "$fails" -gt 0 ]; then
      log "已恢复（此前连续失败 ${fails} 次）"
    fi
    fails=0

    # 链路劣化判定：只在 Wi-Fi 作为主链路时测
    if [ "$(primary_if)" = "$IFACE" ] && wifi_power_on; then
      loss=$(gw_loss)
      now=$(date +%s)
      if awk -v l="$loss" -v t="$LOSS_LIMIT" 'BEGIN{exit !(l+0 >= t+0)}'; then
        badq=$((badq + 1))
        log "质量差：网关丢包 ${loss}%（连续 ${badq}/${LOSS_CYCLES}）"
        if [ "$badq" -ge "$LOSS_CYCLES" ] && [ $((now - last_qual)) -ge "$COOLDOWN" ]; then
          recycle_wifi "丢包 ${loss}%，连续 ${badq} 次"
          last_qual=$now
          badq=0
          cycles=$((cycles + 1))
        fi
      else
        if [ "$badq" -gt 0 ]; then
          log "质量恢复：网关丢包 ${loss}%"
        fi
        badq=0
      fi
    else
      badq=0
    fi
  else
    fails=$((fails + 1))
    log "探测不通（连续 ${fails} 次，主链路 $(primary_if)）"

    if [ "$fails" -ge "$FAIL_LIMIT" ]; then
      if [ "$(primary_if)" != "$IFACE" ]; then
        log "主链路不是 Wi-Fi（当前 $(primary_if)），不重启 Wi-Fi，只记录"
      elif ! wifi_power_on; then
        log "Wi-Fi 电源是关的，不处理"
      else
        recycle_wifi "连续 ${fails} 次探测不通"
        last_qual=$(date +%s)
        cycles=$((cycles + 1))
      fi

      fails=0
      if [ "$cycles" -ge 5 ]; then
        log "已重启 ${cycles} 次，暂停 5 分钟"
        sleep 300
        cycles=0
      fi
    fi
  fi
  sleep "$INTERVAL"
done
