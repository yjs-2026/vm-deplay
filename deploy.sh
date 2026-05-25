#!/usr/bin/env bash
#===============================================================================
# deploy.sh — VM 自动化部署主入口
# 交互式 TUI，收集参数后调用 govc + cloud-init 完成部署
#===============================================================================
set -euo pipefail

# ---------- 基础路径 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
SCRIPTS_DIR="$PROJECT_ROOT/scripts"
CONFIG_DIR="$PROJECT_ROOT/config"
OUTPUTS_DIR="$PROJECT_ROOT/outputs"
LOG_FILE="$OUTPUTS_DIR/deployment-log.txt"

mkdir -p "$OUTPUTS_DIR"

# ---------- 检查依赖 ----------
check_deps() {
  local missing=()
  for cmd in dialog govc python3 sshpass nc; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if ((${#missing[@]} > 0)); then
    echo "缺少依赖: ${missing[*]}"
    echo "安装: apt install dialog govc python3 sshpass netcat-openbsd"
    exit 1
  fi
}

# ---------- TUI 包装函数 ----------
tui_msg() { dialog --msgbox "$1" 8 60; }
tui_input() {
  local var="$1"; local title="$2"; local text="$3"; local def="${4:-}"
  local result
  result=$(dialog --ok-label "下一步" --backtitle "VM 部署向导" \
    --inputbox "$text" 10 60 "$def" 3>&1 1>&2 2>&3)
  echo "$result"
}
tui_password() {
  local var="$1"; local title="$2"; local text="$3"
  local result
  result=$(dialog --ok-label "下一步" --backtitle "VM 部署向导" \
    --passwordbox "$text" 10 60 "" 3>&1 1>&2 2>&3)
  echo "$result"
}
tui_yesno() {
  local text="$1"
  dialog --yes-label "确认" --no-label "返回" --backtitle "VM 部署向导" \
    --yesno "$text" 10 60
}

# ---------- 日志 ----------
log() {
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$ts] $*" | tee -a "$LOG_FILE"
}

die() { log "FATAL: $*"; exit 1; }

# ---------- 步骤 1: vCenter 连接 ----------
step_vcenter() {
  dialog --backtitle "VM 部署向导" --title "步骤 1/6" \
    --msgbox "VM 自动化部署向导\n\n请提供 vCenter 连接信息和 VM 部署参数" 8 60

  VC_URL=$(tui_input VC_URL "vCenter 地址" "请输入 vCenter URL:\n例: https://vc.example.com" "")
  [[ -z "$VC_URL" ]] && die "vCenter URL 不能为空"

  VC_USER=$(tui_input VC_USER "用户名" "请输入 vCenter 用户名:\n格式: user@domain" "")
  [[ -z "$VC_USER" ]] && die "用户名不能为空"

  VC_PASS=$(tui_password VC_PASS "密码" "请输入 vCenter 密码:")

  # 提取 IP/域名（去掉 https:// 前缀和尾随斜杠）
  VC_HOST="$(echo "$VC_URL" | sed -E 's|https?://||' | cut -d':' -f1 | sed 's|/||g')"
}

# ---------- 步骤 2: VM 位置与规格 ----------
step_vm_info() {
  VM_NAME=$(tui_input VM_NAME "VM 信息" "请输入 VM 名称:\n（部署后在 vCenter 中的显示名）" "")
  [[ -z "$VM_NAME" ]] && die "VM 名称不能为空"

  OVF_PATH=$(tui_input OVF_PATH "OVF 模板路径" "请输入 Datastore 中的 OVF 模板路径:\n例: /datastore/ova/ubuntu2404.ovf" "")
  [[ -z "$OVF_PATH" ]] && die "OVF 路径不能为空"

  DATASTORE=$(tui_input DATASTORE "Datastore" "请输入目标 Datastore 名称:\n（VM 将创建在此存储上）" "")
  [[ -z "$DATASTORE" ]] && die "Datastore 不能为空"

  PORTGROUP=$(tui_input PORTGROUP "网络" "请输入 Portgroup / 网络标签名称:\n（VM 将连接到此网络）" "")
  [[ -z "$PORTGROUP" ]] && die "Portgroup 不能为空"

  RESOURCE_POOL=$(tui_input RESOURCE_POOL "资源池" "请输入 Resource Pool 路径:\n（留空使用默认资源池）\n例: /Cluster/Resources/DefaultPool" "")

  VM_FOLDER=$(tui_input VM_FOLDER "VM 文件夹" "请输入 vCenter VM 文件夹路径:\n（留空使用根目录）\n例: /vm" "/vm")

  CPU=$(tui_input CPU "CPU 核心数" "请输入 CPU 核心数:" "2")
  MEMORY_MB=$(tui_input MEMORY_MB "内存大小" "请输入内存大小（MB）:" "4096")
}

# ---------- 步骤 3: 网络配置 ----------
step_network() {
  IP_ADDRESS=$(tui_input IP_ADDRESS "静态 IP 地址" "请输入 VM 的静态 IP 地址:\n例: 192.168.1.100" "")
  [[ -z "$IP_ADDRESS" ]] && die "IP 地址不能为空"

  NETMASK_BITS=$(tui_input NETMASK_BITS "子网掩码位数" "请输入子网掩码位数:\n例: 24 (= 255.255.255.0)" "24")
  [[ -z "$NETMASK_BITS" ]] && NETMASK_BITS=24

  GATEWAY=$(tui_input GATEWAY "网关" "请输入默认网关 IP 地址:\n例: 192.168.1.1" "")
  [[ -z "$GATEWAY" ]] && die "网关不能为空"

  DNS_SERVERS=$(tui_input DNS_SERVERS "DNS 服务器" "请输入 DNS 服务器:\n（逗号分隔，多个 DNS 留空使用 Google DNS）\n例: 8.8.8.8,8.8.4.4" "8.8.8.8,8.8.4.4")
}

# ---------- 步骤 4: 系统配置 ----------
step_system() {
  SUDO_USER=$(tui_input SUDO_USER "sudo 用户" "请输入初始 sudo 用户名:\n（非 root，将授予 sudo 无密码权限）" "ubuntu")
  [[ -z "$SUDO_USER" ]] && die "用户名不能为空"

  SUDO_PASSWD=$(tui_password SUDO_PASSWD "用户密码" "请输入 $SUDO_USER 的密码:\n（用于 SSH 登录和 sudo 操作）")
  [[ -z "$SUDO_PASSWD" ]] && die "密码不能为空"

  # SSH 公钥（支持从文件读取或直接粘贴）
  SSH_KEY_FILE=$(tui_input SSH_KEY_FILE "SSH 公钥" "请输入 SSH 公钥文件路径或直接粘贴公钥内容:\n（支持 ~/.ssh/id_rsa.pub 或直接粘贴 ssh-rsa AAAA... 格式）\n留空则不注入公钥" "")

  if [[ -f "$SSH_KEY_FILE" ]]; then
    SSH_KEYS=$(cat "$SSH_KEY_FILE")
  else
    SSH_KEYS="$SSH_KEY_FILE"
  fi

  SECOND_DISK_GB=$(tui_input SECOND_DISK_GB "第二块盘" "请输入第二块数据盘大小（GB）:\n（0 表示不添加第二块盘）\n第二块盘将自动格式化为 ext4 并挂载到 /home" "0")
  [[ -z "$SECOND_DISK_GB" ]] && SECOND_DISK_GB=0
}

# ---------- 步骤 5: 软件包下载 ----------
step_package() {
  FTP_URL=$(tui_input FTP_URL "FTP 下载" "请输入 FTP 匿名下载 URL:\n例: ftp://192.168.1.100/software.tar.gz\n留空则跳过软件包下载" "")

  DOWNLOAD_FILE=$(tui_input DOWNLOAD_FILE "下载文件名" "请输入保存到本地的文件名:\n例: package.tar.gz" "package.tar.gz")

  EXTRACT_DIR=$(tui_input EXTRACT_DIR "解压目录" "请输入解压目标目录:\n（软件包将解压到此目录）\n例: /opt/app" "/opt/app")
}

# ---------- 步骤 6: 确认并开始部署 ----------
step_confirm() {
  local confirm_text="
========== 部署确认 ==========

vCenter : $VC_URL
用户    : $VC_USER

VM 名称 : $VM_NAME
OVF     : $OVF_PATH
存储    : $DATASTORE
网络    : $PORTGROUP
CPU     : $CPU 核心
内存    : ${MEMORY_MB}MB

IP 地址 : $IP_ADDRESS/${NETMASK_BITS}
网关    : $GATEWAY
DNS     : $DNS_SERVERS

用户    : $SUDO_USER
第二块盘: ${SECOND_DISK_GB}GB

FTP URL : ${FTP_URL:-（未配置）}
解压到  : ${EXTRACT_DIR:-（未配置）}

================================
"
  tui_yesno "$confirm_text" || return 1
  return 0
}

# ---------- 生成 cloud-init user-data ----------
gen_cloud_init() {
  log "生成 cloud-init user-data ..."

  local tmpl="$CONFIG_DIR/cloud-init-ubuntu2404.tpl"
  local out_dir="$OUTPUTS_DIR/cloud-init"
  mkdir -p "$out_dir"

  USER_DATA_OUT="$out_dir/user-data"
  NETWORK_CONFIG_OUT="$out_dir/network-config"
  ISO_OUT="$out_dir/$VM_NAME-cloud-init.iso"

  # DNS 格式化
  local dns_formatted
  if [[ -n "$DNS_SERVERS" ]]; then
    dns_formatted=$(echo "$DNS_SERVERS" | python3 -c "
import sys
dns = sys.stdin.read().strip()
lines = ['        addresses:']
for d in dns.split(','):
    d = d.strip()
    if d:
        lines.append(f'          - {d}')
print('\n'.join(lines))
")
  else
    dns_formatted="        addresses: []"
  fi

  # SSH 公钥格式化（多行缩进）
  local ssh_keys_formatted=""
  if [[ -n "$SSH_KEYS" ]]; then
    while IFS= read -r key; do
      [[ -z "$key" ]] && continue
      key="${key//[[:space:]]/}"
      [[ -z "$key" ]] && continue
      ssh_keys_formatted+="  - ${key}"$'\n'
    done <<< "$SSH_KEYS"
  fi

  # 渲染模板
  env \
    VM_NAME="$VM_NAME" \
    IP_ADDRESS="$IP_ADDRESS" \
    NETMASK_BITS="$NETMASK_BITS" \
    GATEWAY="$GATEWAY" \
    DNS_SERVERS="$dns_formatted" \
    SUDO_USER="$SUDO_USER" \
    SUDO_PASSWD="$SUDO_PASSWD" \
    SSH_KEYS="$ssh_keys_formatted" \
    FTP_URL="${FTP_URL:-}" \
    EXTRACT_DIR="${EXTRACT_DIR:-/opt}" \
    DOWNLOAD_FILE="${DOWNLOAD_FILE:-package.tar.gz}" \
    SECOND_DISK_GB="$SECOND_DISK_GB" \
    envsubst < "$tmpl" > "$USER_DATA_OUT"

  log "user-data 生成完成: $USER_DATA_OUT"

  # 生成 network-config（cloud-init network-config）
  cat > "$NETWORK_CONFIG_OUT" << EOF
version: 2
ethernets:
  ens160:
    addresses:
      - $IP_ADDRESS/$NETMASK_BITS
    gateway4: $GATEWAY
    nameservers:
      addresses:
$dns_formatted
    dhcp4: false
EOF

  log "network-config 生成完成: $NETWORK_CONFIG_OUT"

  # 打包为 ISO（使用 genisoimage 或 xorriso）
  if command -v genisoimage >/dev/null 2>&1; then
    genisoimage -o "$ISO_OUT" -V "cidata" -J -r "$USER_DATA_OUT" "$NETWORK_CONFIG_OUT" 2>&1 | tee -a "$LOG_FILE"
  elif command -v xorriso >/dev/null 2>&1; then
    xorriso -as mkisofs -o "$ISO_OUT" -V cidata -J -r "$USER_DATA_OUT" "$NETWORK_CONFIG_OUT" 2>&1 | tee -a "$LOG_FILE"
  else
    die "需要 genisoimage 或 xorriso 来创建 cloud-init ISO，请安装: apt install genisoimage"
  fi

  log "cloud-init ISO 生成完成: $ISO_OUT"
}

# ---------- 执行 govc 部署 ----------
do_deploy() {
  log "========================================="
  log "  开始部署 VM: $VM_NAME"
  log "========================================="

  export GOVC_URL="$VC_URL"
  export GOVC_USERNAME="$VC_USER"
  export GOVC_PASSWORD="$VC_PASS"
  export GOVC_INSECURE=1

  # 调用 create-vm.sh
  VM_NAME="$VM_NAME" \
  OVF_PATH="$OVF_PATH" \
  DATASTORE="$DATASTORE" \
  PORTGROUP="$PORTGROUP" \
  RESOURCE_POOL="$RESOURCE_POOL" \
  VM_FOLDER="$VM_FOLDER" \
  CPU="$CPU" \
  MEMORY_MB="$MEMORY_MB" \
  NETWORK_NAME="$PORTGROUP" \
  ISO_FILE="$ISO_OUT" \
  USER_DATA_FILE="$USER_DATA_OUT" \
  NETWORK_CONFIG_FILE="$NETWORK_CONFIG_OUT" \
  SECOND_DISK_GB="$SECOND_DISK_GB" \
  LOG_FILE="$LOG_FILE" \
  bash "$SCRIPTS_DIR/create-vm.sh" 2>&1 | tee -a "$LOG_FILE"
}

# ---------- 执行验证 ----------
do_verify() {
  log "========================================="
  log "  开始验证部署"
  log "========================================="

  VM_IP="$IP_ADDRESS" \
  SUDO_USER="$SUDO_USER" \
  VERIFY_PASS="$SUDO_PASSWD" \
  VERIFY_USER="$SUDO_USER" \
  DEST_DIR="${EXTRACT_DIR:-}" \
  LOG_FILE="$LOG_FILE" \
  SSH_TIMEOUT=600 \
  bash "$SCRIPTS_DIR/verify.sh" 2>&1 | tee -a "$LOG_FILE"
}

# ---------- 主流程 ----------
main() {
  check_deps

  # 初始化日志
  echo "=========================================" >> "$LOG_FILE"
  log "部署会话开始"
  log "========================================="

  # 执行 TUI 向导
  step_vcenter
  step_vm_info
  step_network
  step_system
  step_package

  if ! step_confirm; then
    tui_msg "用户取消部署"
    exit 0
  fi

  # 部署
  gen_cloud_init
  do_deploy
  do_verify

  tui_msg "部署完成！\n\nVM: $VM_NAME\nIP: $IP_ADDRESS\n用户: $SUDO_USER\n\n日志: $LOG_FILE"
}

main "$@"
