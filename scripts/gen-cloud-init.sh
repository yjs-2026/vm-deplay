#!/usr/bin/env bash
#===============================================================================
# gen-cloud-init.sh — 渲染 cloud-init user-data 模板
# 用法: gen-cloud-init.sh <tmpl> <output>
#===============================================================================
set -euo pipefail

TMPL="${1:?用法: $0 <模板文件> <输出文件>}"
OUTPUT="${2:?用法: $0 <模板文件> <输出文件>}"

# 从环境变量或调用者传入的参数读取占位符值
VM_NAME="${VM_NAME:-}"
IP_ADDRESS="${IP_ADDRESS:-}"
NETMASK_BITS="${NETMASK_BITS:-24}"
GATEWAY="${GATEWAY:-}"
DNS_SERVERS="${DNS_SERVERS:-}"
SUDO_USER="${SUDO_USER:-ubuntu}"
SUDO_PASSWD="${SUDO_PASSWD:-}"
SSH_KEYS="${SSH_KEYS:-}"
FTP_URL="${FTP_URL:-}"
EXTRACT_DIR="${EXTRACT_DIR:-/opt}"
DOWNLOAD_FILE="${DOWNLOAD_FILE:-package.tar.gz}"
SECOND_DISK_GB="${SECOND_DISK_GB:-0}"

# ---------- 辅助函数 ----------
log() { echo "[$(date '+%H:%M:%S')] [gen-cloud-init] $*"; }

die() { log "ERROR: $*"; exit 1; }

# 读取 SSH 公钥（支持多行缩进）
format_ssh_keys() {
  local keys="$1"
  if [[ -z "$keys" ]]; then
    echo "  # (未提供 SSH 公钥)"
    return
  fi
  while IFS= read -r key; do
    # 跳过空行
    [[ -z "$key" ]] && continue
    # 去除首尾空白
    key="${key//[[:space:]]/}"
    [[ -z "$key" ]] && continue
    echo "  - ${key}"
  done <<< "$keys"
}

# 生成 DNS 服务器块
format_dns() {
  local dns_str="$1"
  local result=""
  if [[ -z "$dns_str" ]]; then
    result="        addresses: []"
  else
    local first=true
    while IFS=',' read -ra DNS_ARRAY; do
      for d in "${DNS_ARRAY[@]}"; do
        d=$(echo "$d" | xargs)  # trim
        if $first; then
          result="        addresses:"
          first=false
        fi
        result+="
          - ${d}"
      done
    done <<< "$dns_str"
  fi
  echo "$result"
}

# 密码加密（调用 python3 或 openssl）
encrypt_password() {
  local plain="$1"
  # 使用 python3 生成 SHA512 加密密码
  python3 -c "
import crypt
print(crypt.crypt('$plain', crypt.mksalt(crypt.METHOD_SHA512)))
" 2>/dev/null || echo "$plain"
}

# ---------- 主逻辑 ----------

[[ -f "$TMPL" ]] || die "模板文件不存在: $TMPL"

# 渲染模板
# 使用 Python 做多占位符替换（处理多行内容）
python3 << 'PYEOF'
import sys

tmpl_path = sys.argv[1]
out_path = sys.argv[2]

# 环境变量
vars = {
    "__VM_NAME__":         "${VM_NAME}",
    "__IP_ADDRESS__":      "${IP_ADDRESS}",
    "__NETMASK_BITS__":   "${NETMASK_BITS}",
    "__GATEWAY__":        "${GATEWAY}",
    "__DNS_SERVERS__":    "${DNS_SERVERS}",
    "__SUDO_USER__":      "${SUDO_USER}",
    "__SUDO_PASSWD__":    "${SUDO_PASSWD}",
    "__SSH_KEYS__":       "${SSH_KEYS}",
    "__FTP_URL__":        "${FTP_URL}",
    "__EXTRACT_DIR__":    "${EXTRACT_DIR}",
    "__DOWNLOAD_FILE__":  "${DOWNLOAD_FILE}",
    "__SECOND_DISK_GB__": "${SECOND_DISK_GB}",
}

with open(tmpl_path, "r") as f:
    content = f.read()

# 简单替换
for placeholder, value in vars.items():
    content = content.replace(placeholder, str(value))

with open(out_path, "w") as f:
    f.write(content)

print(f"Generated: {out_path}")
PYEOF

log "cloud-init user-data 生成完成: $OUTPUT"
