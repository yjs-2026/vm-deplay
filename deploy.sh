#!/usr/bin/env bash
#===============================================================================
# deploy.sh — VM 自动化部署主入口
# 交互式 TUI，收集参数后通过 govc + guestinfo 完成 cloud-init 部署
# 输入错误时不退出，弹出提示后重新交互
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

# ---------- TUI 基础函数 ----------
# 对话框，用 --clear 先清屏避免残影
tui_clear() { clear; }
tui_msg() {
  dialog --backtitle "VM 部署向导" --msgbox "$1" 8 60
}
tui_error() {
  dialog --backtitle "VM 部署向导" --msgbox "输入错误：$1\n\n请重新输入。" 9 60
}
tui_input() {
  local var="$1"; local title="$2"; local text="$3"; local def="${4:-}"
  local result
  result=$(dialog --ok-label "下一步" --backtitle "VM 部署向导" \
    --inputbox "$text" 12 60 "$def" 3>&1 1>&2 2>&3)
  echo "$result"
}
tui_password() {
  local title="$1"; local text="$2"
  local result
  result=$(dialog --ok-label "下一步" --backtitle "VM 部署向导" \
    --passwordbox "$text" 12 60 "" 3>&1 1>&2 2>&3)
  echo "$result"
}
tui_yesno() {
  local text="$1"
  dialog --yes-label "确认" --no-label "返回" --backtitle "VM 部署向导" \
    --yesno "$text" 15 65
}

# ---------- 通用验证函数 ----------
# 返回 0=合法，1=非法，打印错误消息到 stderr
validate_nonempty() {
  local val="$1"; local field="$2"
  [[ -n "$val" ]] && return 0
  echo "$field 不能为空" >&2
  return 1
}

validate_ipv4() {
  local val="$1"; local field="$2"
  local re='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
  [[ "$val" =~ $re ]] || { echo "$field 格式无效，请输入有效 IPv4 地址" >&2; return 1; }
  # 检查每段范围
  IFS='.' read -ra OCTETS <<< "$val"
  for oct in "${OCTETS[@]}"; do
    (( oct >= 0 && oct <= 255 )) || { echo "$field 每段数值需在 0-255 之间" >&2; return 1; }
  done
  return 0
}

validate_netmask() {
  local val="$1"
  [[ "$val" =~ ^[0-9]+$ ]] && (( val >= 0 && val <= 32 )) || \
    { echo "子网掩码位数需为 0-32 的整数" >&2; return 1; }
  return 0
}

validate_positive_int() {
  local val="$1"; local field="$2"
  [[ "$val" =~ ^[0-9]+$ ]] && (( val > 0 )) || \
    { echo "$field 需为正整数" >&2; return 1; }
  return 0
}

validate_nonneg_int() {
  local val="$1"; local field="$2"
  [[ "$val" =~ ^[0-9]+$ ]] || { echo "$field 需为整数" >&2; return 1; }
  return 0
}

validate_url() {
  local val="$1"; local field="$2"
  # 允许空值（选填字段），否则验证格式
  [[ -z "$val" ]] && return 0
  [[ "$val" =~ ^https?:// ]] || [[ "$val" =~ ^ftp:// ]] || \
    { echo "$field 需以 http://、https:// 或 ftp:// 开头" >&2; return 1; }
  return 0
}

validate_username() {
  local val="$1"
  [[ "$val" =~ ^[a-z_][a-z0-9_-]*$ ]] || \
    { echo "用户名需以字母或下划线开头，仅支持字母、数字、下划线、连字符" >&2; return 1; }
  return 0
}

# ---------- 步骤 1: vCenter 连接 ----------
step_vcenter() {
  tui_clear
  dialog --backtitle "VM 部署向导" --title "步骤 1/6" \
    --msgbox "VM 自动化部署向导\n\n请提供 vCenter 连接信息和 VM 部署参数" 8 60

  # VC_URL
  while true; do
    VC_URL=$(tui_input "" "vCenter 地址" "请输入 vCenter URL:\n例: https://vc.example.com" "")
    if validate_nonempty "$VC_URL" "vCenter URL"; then
      validate_url "$VC_URL" "vCenter URL" && break
    fi
    tui_error "$(validate_nonempty "$VC_URL" "vCenter URL" 2>&1 || true)"
  done

  # VC_USER
  while true; do
    VC_USER=$(tui_input "" "用户名" "请输入 vCenter 用户名:\n格式: user@domain" "")
    if validate_nonempty "$VC_USER" "用户名"; then break; fi
    tui_error "用户名不能为空"
  done

  # VC_PASS
  while true; do
    VC_PASS=$(tui_password "密码" "请输入 vCenter 密码:")
    if validate_nonempty "$VC_PASS" "密码"; then break; fi
    tui_error "密码不能为空"
  done

  VC_HOST="$(echo "$VC_URL" | sed -E 's|https?://||' | cut -d':' -f1 | sed 's|/||g')"
}

# ---------- 步骤 2: VM 位置与规格 ----------
step_vm_info() {
  # VM_NAME
  while true; do
    VM_NAME=$(tui_input "" "VM 信息" "请输入 VM 名称:\n（部署后在 vCenter 中的显示名）" "")
    if validate_nonempty "$VM_NAME" "VM 名称"; then break; fi
    tui_error "VM 名称不能为空"
  done

  # OVF_PATH
  while true; do
    OVF_PATH=$(tui_input "" "OVF 模板路径" "请输入 Datastore 中的 OVF 模板路径:\n例: /datastore/ova/ubuntu2404.ovf" "")
    if validate_nonempty "$OVF_PATH" "OVF 路径"; then break; fi
    tui_error "OVF 路径不能为空"
  done

  # DATASTORE
  while true; do
    DATASTORE=$(tui_input "" "Datastore" "请输入目标 Datastore 名称:\n（VM 将创建在此存储上）" "")
    if validate_nonempty "$DATASTORE" "Datastore"; then break; fi
    tui_error "Datastore 不能为空"
  done

  # PORTGROUP
  while true; do
    PORTGROUP=$(tui_input "" "网络" "请输入 Portgroup / 网络标签名称:\n（VM 将连接到此网络）" "")
    if validate_nonempty "$PORTGROUP" "Portgroup"; then break; fi
    tui_error "Portgroup 不能为空"
  done

  # RESOURCE_POOL（选填）
  RESOURCE_POOL=$(tui_input "" "资源池" "请输入 Resource Pool 路径:\n（留空使用默认资源池）\n例: /Cluster/Resources/DefaultPool" "")

  # VM_FOLDER（选填，有默认值）
  VM_FOLDER=$(tui_input "" "VM 文件夹" "请输入 vCenter VM 文件夹路径:\n（留空使用 /vm）\n例: /vm" "/vm")

  # CPU
  while true; do
    CPU=$(tui_input "" "CPU 核心数" "请输入 CPU 核心数:" "2")
    if validate_positive_int "$CPU" "CPU 核心数"; then break; fi
    tui_error "CPU 核心数需为正整数"
  done

  # MEMORY_MB
  while true; do
    MEMORY_MB=$(tui_input "" "内存大小" "请输入内存大小（MB）:" "4096")
    if validate_positive_int "$MEMORY_MB" "内存大小"; then break; fi
    tui_error "内存大小需为正整数"
  done
}

# ---------- 步骤 3: 网络配置 ----------
step_network() {
  # IP_ADDRESS
  while true; do
    IP_ADDRESS=$(tui_input "" "静态 IP 地址" "请输入 VM 的静态 IP 地址:\n例: 192.168.1.100" "")
    if validate_nonempty "$IP_ADDRESS" "IP 地址" && \
       validate_ipv4 "$IP_ADDRESS" "IP 地址"; then break; fi
  done

  # NETMASK_BITS
  while true; do
    NETMASK_BITS=$(tui_input "" "子网掩码位数" "请输入子网掩码位数:\n例: 24 (= 255.255.255.0)" "24")
    if validate_nonempty "$NETMASK_BITS" "子网掩码"; then
      validate_netmask "$NETMASK_BITS" && break
    fi
  done

  # GATEWAY
  while true; do
    GATEWAY=$(tui_input "" "网关" "请输入默认网关 IP 地址:\n例: 192.168.1.1" "")
    if validate_nonempty "$GATEWAY" "网关" && \
       validate_ipv4 "$GATEWAY" "网关"; then break; fi
  done

  # DNS_SERVERS（选填）
  DNS_SERVERS=$(tui_input "" "DNS 服务器" "请输入 DNS 服务器:\n（逗号分隔，多个 DNS 留空使用 Google DNS）\n例: 8.8.8.8,8.8.4.4" "8.8.8.8,8.8.4.4")
}

# ---------- 步骤 4: 系统配置 ----------
step_system() {
  # SUDO_USER
  while true; do
    SUDO_USER=$(tui_input "" "sudo 用户" "请输入初始 sudo 用户名:\n（非 root，将授予 sudo 无密码权限）" "ubuntu")
    if validate_nonempty "$SUDO_USER" "用户名" && \
       validate_username "$SUDO_USER"; then break; fi
  done

  # SUDO_PASSWD
  while true; do
    SUDO_PASSWD=$(tui_password "用户密码" "请输入 $SUDO_USER 的密码:\n（用于 SSH 登录和 sudo 操作）")
    if validate_nonempty "$SUDO_PASSWD" "密码"; then break; fi
    tui_error "密码不能为空"
  done

  # SSH 公钥（选填）
  SSH_KEY_FILE=$(tui_input "" "SSH 公钥" "请输入 SSH 公钥文件路径或直接粘贴公钥内容:\n（支持 ~/.ssh/id_rsa.pub 或直接粘贴 ssh-rsa AAAA... 格式）\n留空则不注入公钥" "")
  if [[ -f "$SSH_KEY_FILE" ]]; then
    SSH_KEYS=$(cat "$SSH_KEY_FILE")
  else
    SSH_KEYS="$SSH_KEY_FILE"
  fi

  # SECOND_DISK_GB
  while true; do
    SECOND_DISK_GB=$(tui_input "" "第二块盘" "请输入第二块数据盘大小（GB）:\n（0 表示不添加第二块盘）\n第二块盘将自动格式化为 ext4 并挂载到 /home" "0")
    if validate_nonneg_int "$SECOND_DISK_GB" "第二块盘大小"; then break; fi
    tui_error "第二块盘大小需为整数"
  done
}

# ---------- 步骤 5: 软件包下载 ----------
step_package() {
  # FTP_URL（选填）
  FTP_URL=$(tui_input "" "FTP 下载" "请输入 FTP 匿名下载 URL:\n例: ftp://192.168.1.100/software.tar.gz\n留空则跳过软件包下载" "")

  # DOWNLOAD_FILE（选填，但 FTP_URL 非空时必填）
  while true; do
    DOWNLOAD_FILE=$(tui_input "" "下载文件名" "请输入保存到本地的文件名:\n例: package.tar.gz" "package.tar.gz")
    if [[ -n "$FTP_URL" ]]; then
      validate_nonempty "$DOWNLOAD_FILE" "下载文件名" && break
    else
      break
    fi
  done

  # EXTRACT_DIR（选填，但 FTP_URL 非空时必填）
  while true; do
    EXTRACT_DIR=$(tui_input "" "解压目录" "请输入解压目标目录:\n（软件包将解压到此目录）\n例: /opt/app" "/opt/app")
    if [[ -n "$FTP_URL" ]]; then
      validate_nonempty "$EXTRACT_DIR" "解压目录" && break
    else
      break
    fi
  done
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

# ---------- 生成 cloud-init userdata ----------
gen_cloudinit_data() {
  log "生成 cloud-init 数据 ..."

  local ud="$OUTPUTS_DIR/cloud-init-userdata.yaml"
  USERDATA_OUT="$ud"

  # DNS 格式化
  local dns_lines="        addresses:"
  if [[ -n "$DNS_SERVERS" ]]; then
    for d in $(echo "$DNS_SERVERS" | tr ',' ' '); do
      dns_lines+="
          - ${d}"
    done
  else
    dns_lines+="
          - 8.8.8.8
          - 8.8.4.4"
  fi

  # SSH 公钥格式化
  local ssh_keys_yaml=""
  if [[ -n "$SSH_KEYS" ]]; then
    while IFS= read -r key; do
      [[ -z "$key" ]] && continue
      key="${key//[[:space:]]/}"
      [[ -z "$key" ]] && continue
      ssh_keys_yaml+="  - ${key}"$'\n'
    done <<< "$SSH_KEYS"
  fi

  # FTP 下载命令（条件化）
  local ftp_cmd=""
  if [[ -n "$FTP_URL" ]]; then
    ftp_cmd="- bash -c \"wget -q -O /tmp/${DOWNLOAD_FILE} '${FTP_URL}' && tar -xzf /tmp/${DOWNLOAD_FILE} -C ${EXTRACT_DIR} && rm -f /tmp/${DOWNLOAD_FILE}\""
  fi

  # 第二块盘挂载命令（条件化）
  local disk2_cmd=""
  if (( SECOND_DISK_GB > 0 )); then
    disk2_cmd="- bash -c \"
lsblk -no NAME /dev/sdb 2>/dev/null | grep -q sdb && {
  mkfs.ext4 -F /dev/sdb 2>/dev/null || mkfs.ext4 -F /dev/sdb1 2>/dev/null || true
  mkdir -p /home
  mount /dev/sdb /home 2>/dev/null || mount /dev/sdb1 /home 2>/dev/null || true
  grep -q '/dev/sdb1.*home' /etc/fstab || echo '/dev/sdb1 /home ext4 defaults,nofail 0 2' >> /etc/fstab
  chown -R ${SUDO_USER}:${SUDO_USER} /home
} || echo 'Second disk not found, skipping'\"
"
  fi

  cat > "$ud" << EOF
#cloud-config
# VMware guestinfo userdata — 由 deploy.sh 自动生成

hostname: ${VM_NAME}
manage_etc_hosts: true

users:
  - name: ${SUDO_USER}
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    passwd: ""

ssh_authorized_keys:
${ssh_keys_yaml:-  # （未提供 SSH 公钥）}

packages:
  - curl
  - wget
  - tar
  - gzip
  - net-tools
  - rsync
  - cloud-init
  - cloud-utils
  - growpart
  - parted

disk_setup:
  /dev/sdb:
    table_type: gpt
    layout:
      - 100
    overwrite: false

fs_setup:
  - label: data
    device: /dev/sdb1
    filesystem: ext4

mounts:
  - ["/dev/sdb1", "/home", "ext4", "defaults,nofail", "0", "2"]

network:
  version: 2
  renderer: networkd
  ethernets:
    ens160:
      addresses:
        - ${IP_ADDRESS}/${NETMASK_BITS}
      gateway4: ${GATEWAY}
      nameservers:
${dns_lines}
      dhcp4: false
      optional: false

runcmd:
  - [sleep, 10]
  - bash -c "echo '${SUDO_USER}:${SUDO_PASSWD}' | chpasswd -e"
  - [netplan apply]
  - [bash, -c, "growpart /dev/sda 1 || true"]
  - [bash, -c, "resize2fs /dev/sda1 || true"]
${disk2_cmd}${ftp_cmd}
  - bash -c "sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config && systemctl restart sshd"

power_state:
  mode: reboot
  delay: now
  condition: True
EOF

  log "cloud-init userdata 生成完成: $USERDATA_OUT"

  local md="$OUTPUTS_DIR/cloud-init-metadata.yaml"
  METADATA_OUT="$md"
  cat > "$md" << EOF
instance-id: ${VM_NAME}-$(date +%s)
local-hostname: ${VM_NAME}
EOF
  log "cloud-init metadata 生成完成: $METADATA_OUT"
}

# ---------- 执行 govc 部署 ----------
do_deploy() {
  log "========================================="
  log "  开始部署 VM: $VM_NAME"
  log "========================================="

  local userdata metadata
  userdata=$(cat "$USERDATA_OUT")
  metadata=$(cat "$METADATA_OUT")

  VM_NAME="$VM_NAME" \
  OVF_PATH="$OVF_PATH" \
  DATASTORE="$DATASTORE" \
  PORTGROUP="$PORTGROUP" \
  RESOURCE_POOL="$RESOURCE_POOL" \
  VM_FOLDER="$VM_FOLDER" \
  CPU="$CPU" \
  MEMORY_MB="$MEMORY_MB" \
  NETWORK_NAME="$PORTGROUP" \
  CLOUDINIT_USERDATA="$userdata" \
  CLOUDINIT_METADATA="$metadata" \
  SECOND_DISK_GB="$SECOND_DISK_GB" \
  LOG_FILE="$LOG_FILE" \
  GOVC_INSECURE=1 \
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

  echo "=========================================" >> "$LOG_FILE"
  log "部署会话开始"
  log "========================================="

  step_vcenter
  step_vm_info
  step_network
  step_system
  step_package

  if ! step_confirm; then
    tui_msg "用户取消部署"
    exit 0
  fi

  gen_cloudinit_data
  do_deploy
  do_verify

  tui_msg "部署完成！\n\nVM: $VM_NAME\nIP: $IP_ADDRESS\n用户: $SUDO_USER\n\n日志: $LOG_FILE"
}

main "$@"
