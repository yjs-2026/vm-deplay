#!/usr/bin/env bash
#===============================================================================
# create-vm.sh — 使用 govc 创建 VM，通过 guestinfo 注入 cloud-init 数据
# VMware 原生 cloud-init 支持，无需 ISO 交换
#===============================================================================
set -euo pipefail

# ---------- 默认参数（由调用者覆盖） ----------
VC_URL="${VC_URL:-}"
VC_USER="${VC_USER:-}"
VC_PASS="${VC_PASS:-}"
VM_NAME="${VM_NAME:-}"
VM_FOLDER="${VM_FOLDER:-/}"
DATASTORE="${DATASTORE:-}"
PORTGROUP="${PORTGROUP:-}"
RESOURCE_POOL="${RESOURCE_POOL:-}"
VM_TEMPLATE="${VM_TEMPLATE:-}"
CPU="${CPU:-2}"
MEMORY_MB="${MEMORY_MB:-2048}"
NETWORK_NAME="${NETWORK_NAME:-}"

# cloud-init 数据（通过 guestinfo 注入）
CLOUDINIT_USERDATA="${CLOUDINIT_USERDATA:-}"
CLOUDINIT_METADATA="${CLOUDINIT_METADATA:-}"

# ---------- 日志 ----------
LOG_FILE="${LOG_FILE:-./outputs/deployment-log.txt}"

log() {
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$ts] [create-vm] $*" | tee -a "$LOG_FILE"
}

die() {
  log "FATAL: $*"
  exit 1
}

# ---------- 前置检查 ----------
check_deps() {
  command -v govc >/dev/null 2>&1 || die "govc 未安装或不在 PATH 中"
  command -v python3 >/dev/null 2>&1 || die "python3 未安装"
  command -v base64 >/dev/null 2>&1 || die "base64 未安装"
}

export_govc_env() {
  export GOVC_URL="$VC_URL"
  export GOVC_USERNAME="$VC_USER"
  export GOVC_PASSWORD="$VC_PASS"
  export GOVC_TLS_CA_CERTS="${GOVC_TLS_CA_CERTS:-}"
  export GOVC_INSECURE=1   # 自签名证书
  export GOVC_DATACENTER=$(govc ls | awk -F'/' '{print $2}' | head -1)
  export GOVC_FOLDER="$VM_FOLDER"
}

# ---------- 等待 VM 进入目标状态 ----------
wait_for_state() {
  local vm="$1"
  local state="${2:-poweredOn}"
  local timeout="${3:-300}"
  local interval="${4:-10}"
  local elapsed=0

  log "等待 VM '$vm' 进入状态: $state (超时 ${timeout}s)..."
  while true; do
    local current
    current=$(govc vm.info "$vm" 2>/dev/null | grep "Power state:" | awk -F': ' '{print $2}' | tr -d ' ')
    if [[ "$current" == "$state" ]]; then
      log "VM 状态: $state ✓"
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
    if ((elapsed >= timeout)); then
      die "等待 VM 状态超时 (${timeout}s)，当前状态: ${current:-未知}"
    fi
    log "  当前状态: ${current:-未知}，已等待 ${elapsed}s..."
  done
}

# ---------- 通过 guestinfo 注入 cloud-init 数据 ----------
# cloud-init 通过 VMware guestinfo 数据源读取 ExtraConfig 键
# 官方文档要求：必须设置 encoding 参数（base64 或 gzip+base64）
# 参考：https://docs.cloud-init.io/en/25.3/reference/datasources/vmware.html
inject_cloudinit_guestinfo() {
  local vm="$VM_NAME"
  local metadata="$1"
  local userdata="$2"

  log "注入 cloud-init 数据到 guestinfo ..."

  # 编码后的数据
  local meta_enc user_enc
  meta_enc=$(echo -n "$metadata" | gzip | base64 | tr -d '\n')
  user_enc=$(echo -n "$userdata" | gzip | base64 | tr -d '\n')

  # 1. 先关机（必须，文档要求）
  log "关机 VM: $vm"
  govc vm.power -off "$vm" 2>&1 | tee -a "$LOG_FILE" || true
  sleep 5

  # 2. 设置 guestinfo.metadata（gzip+base64 编码）
  log "设置 guestinfo.metadata (gzip+base64, ${#meta_enc} chars)"
  govc vm.change \
    -vm "$vm" \
    -e "guestinfo.metadata=$meta_enc" \
    -e "guestinfo.metadata.encoding=gzip+base64" \
    2>&1 | tee -a "$LOG_FILE"

  # 3. 设置 guestinfo.userdata（gzip+base64 编码）
  log "设置 guestinfo.userdata (gzip+base64, ${#user_enc} chars)"
  govc vm.change \
    -vm "$vm" \
    -e "guestinfo.userdata=$user_enc" \
    -e "guestinfo.userdata.encoding=gzip+base64" \
    2>&1 | tee -a "$LOG_FILE"

  # 4. 标识 cloud-init 数据已就绪
  govc vm.change \
    -vm "$vm" \
    -e "guestinfo.have-cloud-init=true" \
    2>&1 | tee -a "$LOG_FILE"

  log "cloud-init guestinfo 注入完成 ✓"
}

# ---------- 创建 VM ----------
do_create_vm() {
  log "=== 开始创建 VM ==="
  log "  VM 名称: $VM_NAME"
  log "  VM 模板: $VM_TEMPLATE"
  log "  Datastore: $DATASTORE"
  log "  CPU: $CPU | 内存: ${MEMORY_MB}MB"
  log "  Portgroup: $PORTGROUP"

  # 1. 检查同名 VM 是否已存在
  existing=$(govc vm.info "$VM_NAME" 2>&1)
  if [ -n "$existing" ]; then
    log "警告: VM '$VM_NAME' 已存在，将尝试使用现有 VM"
  fi

  # 2. 从模板克隆 VM（全克隆，不使用链接克隆）
  if [ -z "$existing" ]; then
    log "正在从模板克隆 VM ..."

    # 构建 clone 命令（RESOURCE_POOL 为空时不加 -pool 参数）
    local clone_cmd=(govc vm.clone -vm="$VM_TEMPLATE" -ds="$DATASTORE" -folder="$VM_FOLDER" "$VM_NAME")
    if [[ -n "$RESOURCE_POOL" ]]; then
      clone_cmd+=(-pool="$RESOURCE_POOL")
    fi
    "${clone_cmd[@]}" 2>&1 | tee -a "$LOG_FILE"
    log "模板克隆完成 ✓"
  else
    log "VM 已存在，跳过克隆"
  fi

  # 3. 克隆后 VM 默认是 poweredOn，等待 5s 让硬件就绪
  sleep 5

  # 4. 配置 VM（CPU、内存）
  log "配置 VM 规格: CPU=$CPU, Memory=${MEMORY_MB}MB"
  govc vm.change \
    -vm "$VM_NAME" \
    -c "$CPU" \
    -m "$MEMORY_MB" \
    2>&1 | tee -a "$LOG_FILE"

  # 5. 配置网络
  if [[ -n "$NETWORK_NAME" ]]; then
    log "配置网络: $NETWORK_NAME"
    govc vm.network.change \
      -vm "$VM_NAME" \
      -net="$NETWORK_NAME" \
      -net.adapter=vmxnet3 2>&1 | tee -a "$LOG_FILE" || true
  fi

  # 6. 注入 cloud-init 数据（通过 guestinfo，无需 ISO）
  #    必须在关机状态下注入，文档要求
  if [[ -n "$CLOUDINIT_USERDATA" ]]; then
    inject_cloudinit_guestinfo "$CLOUDINIT_METADATA" "$CLOUDINIT_USERDATA"
  else
    log "警告: 未提供 cloud-init userdata，跳过 guestinfo 注入"
  fi

  # 7. 开机（inject_cloudinit_guestinfo 已将 VM 关机，注入完成后重新开机）
  log "启动 VM: $VM_NAME"
  govc vm.power -on "$VM_NAME" 2>&1 | tee -a "$LOG_FILE"

  log "=== VM 创建与启动完成 ==="
}

# ---------- 主入口 ----------
main() {
  check_deps
  export_govc_env
  do_create_vm
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
