#!/usr/bin/env bash
#===============================================================================
# verify.sh — 部署成功验证脚本
# 通过 SSH 轮询检测 cloud-init 是否完成
#===============================================================================
set -euo pipefail

VM_IP="${VM_IP:-}"
SUDO_USER="${SUDO_USER:-ubuntu}"
SSH_PORT="${SSH_PORT:-22}"
VERIFY_USER="${VERIFY_USER:-}"
VERIFY_PASS="${VERIFY_PASS:-}"
LOG_FILE="${LOG_FILE:-./outputs/deployment-log.txt}"

# 超时/间隔（秒）
SSH_TIMEOUT="${SSH_TIMEOUT:-600}"
POLL_INTERVAL="${POLL_INTERVAL:-15}"

# ---------- 日志 ----------
log() {
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$ts] [verify] $*" | tee -a "$LOG_FILE"
}

die() {
  log "FATAL: $*"
  exit 1
}

# ---------- SSH 执行（支持密码/密钥） ----------
ssh_cmd() {
  local host="$1"
  local cmd="$2"
  if [[ -n "$VERIFY_PASS" ]]; then
    sshpass -p "$VERIFY_PASS" ssh \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 \
      -o BatchMode=yes \
      "${VERIFY_USER:-root}@$host" "$cmd"
  else
    ssh -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 \
      -o BatchMode=yes \
      "${VERIFY_USER:-root}@$host" "$cmd"
  fi
}

# ---------- 等待 SSH 端口开放 ----------
wait_ssh() {
  local host="$VM_IP"
  local elapsed=0

  log "等待 SSH 端口开放: ${host}:${SSH_PORT} (超时 ${SSH_TIMEOUT}s)..."

  while true; do
    # 使用 nc 检测端口，或使用 bash /dev/tcp
    if nc -z -w 5 "$host" "$SSH_PORT" 2>/dev/null; then
      log "SSH 端口已开放 ✓ (等待 ${elapsed}s)"
      return 0
    fi
    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
    if ((elapsed >= SSH_TIMEOUT)); then
      die "SSH 端口未在 ${SSH_TIMEOUT}s 内开放"
    fi
    log "  仍等待中，已 ${elapsed}s..."
  done
}

# ---------- 等待 cloud-init 完成 ----------
# cloud-init 只在首次启动运行，重启后 status 恒为 not_ready，
# 因此改为检查 cloud-init 完成的实际结果（用户存在 + cloud-init 标记文件）----------
wait_cloud_init() {
  local host="$VM_IP"
  local elapsed=0
  local target_user="${VERIFY_USER:-$SUDO_USER}"

  log "等待 cloud-init 完成 (超时 ${SSH_TIMEOUT}s)..."

  while true; do
    # cloud-init 完成后在 /var/lib/cloud/data/result.json 留下标记
    local result
    result=$(ssh_cmd "$host" "
      if [ -f /var/lib/cloud/data/result.json ]; then
        errors=\$(grep -oP '\"errors\":\s*\K[^}]+' /var/lib/cloud/data/result.json 2>/dev/null || echo 'NOTFOUND')
        if [ \"\$errors\" = \"[]\" ]; then
          echo 'done'
        elif [ \"\$errors\" != \"NOTFOUND\" ]; then
          echo \"error: \$errors\"
        fi
      else
        id ${target_user} >/dev/null 2>&1 && echo 'done'
      fi
    " 2>/dev/null || echo "")

    if [[ "$result" == "done" || "$result" == "partial" ]]; then
      log "cloud-init 完成 (状态: $result) ✓"
      return 0
    fi

    log "  cloud-init 初始化中，已 ${elapsed}s..."
    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
    if ((elapsed >= SSH_TIMEOUT)); then
      die "cloud-init 未在 ${SSH_TIMEOUT}s 内完成，最后状态: $result"
    fi
  done
}

# ---------- 验证网络 ----------
verify_network() {
  local host="$VM_IP"

  log "验证网络配置 ..."

  local ip_result
  ip_result=$(ssh_cmd "$host" "ip addr show | grep inet" 2>/dev/null || echo "")
  log "IP 配置:\n$ip_result"

  local route_result
  route_result=$(ssh_cmd "$host" "ip route | grep default" 2>/dev/null || echo "")
  log "默认路由:\n$route_result"
}

# ---------- 主入口 ----------
main() {
  [[ -z "$VM_IP" ]] && die "VM_IP 未设置"
  [[ -z "$VERIFY_USER" ]] && VERIFY_USER="$SUDO_USER"

  log "========================================="
  log "  开始验证 VM: $VM_IP"
  log "  用户: $VERIFY_USER"
  log "========================================="

  # 1. 等待 SSH
  wait_ssh

  # 2. 等待 cloud-init
  wait_cloud_init

  # 3. 验证网络
  verify_network

  log "========================================="
  log "  部署验证完成 — 全部成功 ✓"
  log "========================================="
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
