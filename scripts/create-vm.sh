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
OVF_PATH="${OVF_PATH:-}"
CPU="${CPU:-2}"
MEMORY_MB="${MEMORY_MB:-4096}"
NETWORK_NAME="${NETWORK_NAME:-}"

# cloud-init 数据（通过 guestinfo 注入）
CLOUDINIT_USERDATA="${CLOUDINIT_USERDATA:-}"
CLOUDINIT_METADATA="${CLOUDINIT_METADATA:-}"

# 第二块盘大小（GB，0 表示不添加）
SECOND_DISK_GB="${SECOND_DISK_GB:-0}"

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
  export GOVC_DATACENTER="${GOVC_DATACENTER:-ha-datacenter}"
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
    current=$(govc vm.info "$vm" 2>/dev/null | grep "Runtime state:" | awk -F': ' '{print $2}' | tr -d ' ')
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
# cloud-init 通过 VMware guestinfo 数据源读取这些 ExtraConfig 键
inject_cloudinit_guestinfo() {
  local vm="$VM_NAME"
  local metadata="$1"
  local userdata="$2"

  log "注入 cloud-init 数据到 guestinfo ..."

  # guestinfo.metadata：包含主机名（cloud-init 专用格式）
  if [[ -n "$metadata" ]]; then
    local metadata_b64
    metadata_b64=$(echo "$metadata" | base64 -w0)
    log "设置 guestinfo.metadata (base64, ${#metadata_b64} 字符)"
    govc vm.change \
      -vm "$vm" \
      -e "guestinfo.metadata=$metadata_b64" \
      2>&1 | tee -a "$LOG_FILE"
  fi

  # guestinfo.userdata：完整的 cloud-init #cloud-config 内容
  if [[ -n "$userdata" ]]; then
    local userdata_b64
    userdata_b64=$(echo "$userdata" | base64 -w0)
    log "设置 guestinfo.userdata (base64, ${#userdata_b64} 字符)"
    govc vm.change \
      -vm "$vm" \
      -e "guestinfo.userdata=$userdata_b64" \
      2>&1 | tee -a "$LOG_FILE"
  fi

  # 设置 cloud-init 标识，通知 guest cloud-init 数据已就绪
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
  log "  OVF 路径: $OVF_PATH"
  log "  Datastore: $DATASTORE"
  log "  CPU: $CPU | 内存: ${MEMORY_MB}MB"
  log "  Portgroup: $PORTGROUP"
  log "  第二块盘: ${SECOND_DISK_GB}GB"

  # 1. 检查 OVF 是否存在
  if ! govc lsf "$OVF_PATH" >/dev/null 2>&1; then
    die "OVF 模板不存在或路径错误: $OVF_PATH"
  fi

  # 2. 检查同名 VM 是否已存在
  if govc vm.info "$VM_NAME" >/dev/null 2>&1; then
    log "警告: VM '$VM_NAME' 已存在，将尝试使用现有 VM"
  fi

  # 3. 导入 OVF（govc import.ovf）
  if ! govc vm.info "$VM_NAME" >/dev/null 2>&1; then
    log "正在导入 OVF 模板..."
    govc import.ovf \
      -ds="$DATASTORE" \
      -pool="$RESOURCE_POOL" \
      -folder="$VM_FOLDER" \
      -name="$VM_NAME" \
      -force=true \
      "$OVF_PATH" \
      2>&1 | tee -a "$LOG_FILE"
    log "OVF 导入完成 ✓"
  else
    log "VM 已存在，跳过 OVF 导入"
  fi

  # 4. 等待 VM 创建完成
  sleep 5
  wait_for_state "$VM_NAME" "poweredOff" 120

  # 5. 配置 VM（CPU、内存）
  log "配置 VM 规格: CPU=$CPU, Memory=${MEMORY_MB}MB"
  govc vm.change \
    -vm "$VM_NAME" \
    -c "$CPU" \
    -m "$MEMORY_MB" \
    2>&1 | tee -a "$LOG_FILE"

  # 6. 配置网络
  if [[ -n "$NETWORK_NAME" ]]; then
    log "配置网络: $NETWORK_NAME"
    govc vm.network.change \
      -vm "$VM_NAME" \
      -net="$NETWORK_NAME" \
      -net.adapter=vmxnet3 2>&1 | tee -a "$LOG_FILE" || true
  fi

  # 7. 注入 cloud-init 数据（通过 guestinfo，无需 ISO）
  if [[ -n "$CLOUDINIT_USERDATA" ]]; then
    inject_cloudinit_guestinfo "$CLOUDINIT_METADATA" "$CLOUDINIT_USERDATA"
  else
    log "警告: 未提供 cloud-init userdata，跳过 guestinfo 注入"
  fi

  # 8. 添加第二块盘（可选）
  if (( SECOND_DISK_GB > 0 )); then
    log "添加第二块数据盘: ${SECOND_DISK_GB}GB"
    govc vm.disk.create \
      -vm "$VM_NAME" \
      -size "${SECOND_DISK_GB}G" \
      -name "${VM_NAME}-disk2" \
      -ds="$DATASTORE" \
      2>&1 | tee -a "$LOG_FILE"
    log "第二块盘添加完成 ✓"
  fi

  # 9. 开机
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
