#cloud-config
# Ubuntu 24.04 cloud-init user-data 模板
# 由 gen-cloud-init.sh 渲染

# ─────────────────────────────────────────────
# 1. 主机名
# ─────────────────────────────────────────────
hostname: __VM_NAME__
manage_etc_hosts: true

# ─────────────────────────────────────────────
# 2. 本地用户（sudo 非 root 用户）
# ─────────────────────────────────────────────
users:
  - name: __SUDO_USER__
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    # 密码通过 runcmd 的 chpasswd 设置（避免明文）
    passwd: ""

# ─────────────────────────────────────────────
# 3. SSH 公钥注入
# ─────────────────────────────────────────────
ssh_authorized_keys:
__SSH_KEYS__

# ─────────────────────────────────────────────
# 4. 包管理（预装基础工具）
# ─────────────────────────────────────────────
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

# ─────────────────────────────────────────────
# 5. 磁盘配置
#    - 扩展根分区（由 growpart + resize2fs 自动完成）
#    - 第二块盘挂载 /home（由 runcmd 处理）
# ─────────────────────────────────────────────
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

# ─────────────────────────────────────────────
# 6. 挂载点配置（第二块盘持久挂载）
# ─────────────────────────────────────────────
mounts:
  - ["/dev/sdb1", "/home", "ext4", "defaults,nofail", "0", "2"]

# ─────────────────────────────────────────────
# 7. 网络配置（禁用 cloud-init 自动化网络，
#    写入静态 IP，由 runcmd 的 netplan apply 生效）
# ─────────────────────────────────────────────
network:
  version: 2
  renderer: networkd
  ethernets:
    ens160:
      addresses:
        - __IP_ADDRESS__/__NETMASK_BITS__
      gateway4: __GATEWAY__
      nameservers:
        addresses:
__DNS_SERVERS__
      dhcp4: false
      optional: false

# ─────────────────────────────────────────────
# 8. runcmd（在 VM 首次启动时执行
# ─────────────────────────────────────────────
runcmd:
  # 8.1 等待网络就绪
  - [sleep, 10]

  # 8.2 设置用户密码（SHA512 加密）
  - bash -c "echo '__SUDO_USER__:__SUDO_PASSWD__' | chpasswd -e"

  # 8.3 应用 Netplan 静态网络（立即生效）
  - [netplan apply]

  # 8.4 扩展根分区（若存在未分配空间）
  - [bash, -c, "growpart /dev/sda 1 || true"]
  - [bash, -c, "resize2fs /dev/sda1 || true"]

  # 8.5 格式化并挂载第二块盘（/dev/sdb，若存在且未挂载）
  - [bash, -c,
     "lsblk -no NAME,SIZE /dev/sdb 2>/dev/null | grep -q sdb &&
      (mkfs.ext4 -F /dev/sdb 2>/dev/null || mkfs.ext4 -F /dev/sdb1 2>/dev/null || true) &&
      mkdir -p /home &&
      (mount /dev/sdb /home 2>/dev/null || mount /dev/sdb1 /home 2>/dev/null || true) &&
      echo '/dev/sdb1 /home ext4 defaults,nofail 0 2' >> /etc/fstab ||
      echo 'Second disk not found, skipping'"]

  # 8.6 下载并解压软件包（FTP 匿名下载）
  - bash -c "wget -q -O /tmp/__DOWNLOAD_FILE__ __FTP_URL__ && tar -xzf /tmp/__DOWNLOAD_FILE__ -C __EXTRACT_DIR__ && rm -f /tmp/__DOWNLOAD_FILE__"

  # 8.7 确保 /home 属主正确
  - bash -c "chown -R __SUDO_USER__:__SUDO_USER__ /home"

  # 8.8 禁用 SSH 密码登录（仅允许密钥）
  - bash -c "sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config && systemctl restart sshd"

# ─────────────────────────────────────────────
# 9. 禁用 cloud-init 自动化模块（按需调整）
# ─────────────────────────────────────────────
cloud_init_modules:
  - disk_setup
  - mounts
  - growpart
  -_resize2fs
  - set_hostname
  - update_hostname
  - ssh
  - set_passwords
  - package_update_upgrade_install
  - runcmd

cloud_config_modules:
  - runcmd

# ─────────────────────────────────────────────
# 10. 最终状态报告
# ─────────────────────────────────────────────
power_state:
  mode: reboot
  delay: now
  condition: True
