#!/usr/bin/env bash
#===============================================================================
# create-vm.sh — 使用 govc 创建 VM 并挂载 cloud-init ISO
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
CLUSTER="${CLUSTER:-}"
OVF_PATH="${OVF_PATH:-}"
CUSTOMIZATION_SPEC="${CUSTOMIZATION_SPEC:-}"
CPU="${CPU:-2}"
MEMORY_MB="${MEMORY_MB:-4096}"
DISK_SIZE_GB="${DISK_SIZE_GB:-40}"
NETWORK_NAME="${NETWORK_NAME:-}"
ISO_FILE="${ISO_FILE:-}"

# cloud-init 文件（挂载到 VM）
USER_DATA_FILE="${USER_DATA_FILE:-}"
NETWORK_CONFIG_FILE="${NETWORK_CONFIG_FILE:-}"

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

# ---------- 获取 VM 唯一 ID ----------
get_vm-ref() {
  govc vm.info "$VM_NAME" 2>/dev/null | grep "UUID:" | awk '{print $2}' | tr -d ' '
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
  #    如果 VM 已存在则跳过
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

  # 7. 挂载 cloud-init ISO（CD-ROM）
  if [[ -n "$ISO_FILE" && -f "$ISO_FILE" ]]; then
    log "挂载 cloud-init ISO: $ISO_FILE"
    # 先获取 CD-ROM 设备
    CDROM_DEV=$(govc vm.device.info -vm "$VM_NAME" 2>/dev/null | grep "CD-ROM" | head -1 | awk '{print $1}' | tr -d ':')
    if [[ -n "$CDROM_DEV" ]]; then
      govc device.cdrom.insert \
        -vm "$VM_NAME" \
        -device="$CDROM_DEV" \
        -file="[$DATASTORE] $ISO_FILE" \
        2>&1 | tee -a "$LOG_FILE"
    else
      # 没有 CD-ROM 则添加
      govc device.cdrom.add \
        -vm "$VM_NAME" \
        2>&1 | tee -a "$LOG_FILE"
      CDROM_DEV=$(govc vm.device.info -vm "$VM_NAME" 2>/dev/null | grep "CD-ROM" | head -1 | awk '{print $1}' | tr -d ':')
      govc device.cdrom.insert \
        -vm "$VM_NAME" \
        -device="$CDROM_DEV" \
        -file="[$DATASTORE] $ISO_FILE" \
        2>&1 | tee -a "$LOG_FILE"
    fi
    log "cloud-init ISO 挂载完成 ✓"
  else
    log "警告: 未提供 cloud-init ISO 文件，跳过挂载"
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
