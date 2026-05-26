#cloud-config
# Ubuntu 24.04 cloud-init user-data 模板
# 参考：https://docs.cloud-init.io/en/25.3/reference/datasources/vmware.html
#
# Guestinfo 传输模式要求：
#   - guestinfo.metadata + guestinfo.metadata.encoding (gzip+base64)
#   - guestinfo.userdata + guestinfo.userdata.encoding (gzip+base64)
#   - VM 必须关机才能写入 guestinfo
#
# ─────────────────────────────────────────────
# 1. 主机名
# ─────────────────────────────────────────────
hostname: __VM_NAME__
manage_etc_hosts: true

# ─────────────────────────────────────────────
# 2. 本地用户（sudo 非 root 用户）
#    使用 plain_text_passwd 直接设置明文密码
# ─────────────────────────────────────────────
users:
  - name: __SUDO_USER__
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    plain_text_passwd: "__SUDO_PASSWD__"

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
# 5. 磁盘配置（第二块盘 /dev/sdb）
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
# 6. 挂载点配置（第二块盘持久挂载 /home）
# ─────────────────────────────────────────────
mounts:
  - ["/dev/sdb1", "/home", "ext4", "defaults,nofail", "0", "2"]

# ─────────────────────────────────────────────
# 7. 网络配置（静态 IP，networkd）
#    ens33 是模板实际网卡名
# ─────────────────────────────────────────────
network:
  version: 2
  renderer: networkd
  ethernets:
    ens33:
      addresses:
        - __IP_ADDRESS__/__NETMASK_BITS__
      gateway4: __GATEWAY__
      nameservers:
        addresses:
__DNS_SERVERS__
      dhcp4: false
      optional: false

# ─────────────────────────────────────────────
# 8. runcmd（VM 首次启动时执行）
# ─────────────────────────────────────────────
runcmd:
  # 8.1 等待网络就绪
  - [sleep, 10]

  # 8.2 扩展根分区（若存在未分配空间）
  - [bash, -c, "growpart /dev/sda 1 || true"]
  - [bash, -c, "resize2fs /dev/sda1 || true"]

  # 8.3 格式化并挂载第二块盘（/dev/sdb，若存在且未挂载）
  - [bash, -c,
     "lsblk -no NAME,SIZE /dev/sdb 2>/dev/null | grep -q sdb &&
      (mkfs.ext4 -F /dev/sdb 2>/dev/null || mkfs.ext4 -F /dev/sdb1 2>/dev/null || true) &&
      mkdir -p /home &&
      (mount /dev/sdb /home 2>/dev/null || mount /dev/sdb1 /home 2>/dev/null || true) &&
      echo '/dev/sdb1 /home ext4 defaults,nofail 0 2' >> /etc/fstab ||
      echo 'Second disk not found, skipping'"]

  # 8.4 解压 qoder 软件（已预装在模板镜像 /var/soft/qoder.tgz）
  - bash -c "tar -xzf /var/soft/qoder.tgz -C /home/__SUDO_USER__/ && chown -R __SUDO_USER__:__SUDO_USER__ /home/__SUDO_USER__"

  # 8.5 确保 /home 属主正确
  - bash -c "chown -R __SUDO_USER__:__SUDO_USER__ /home"

  # 8.6 允许 SSH 密码登录
  - bash -c "sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config && systemctl restart ssh"

# ─────────────────────────────────────────────
# 9. 最终状态：重启
# ─────────────────────────────────────────────
power_state:
  mode: reboot
  delay: now
  condition: True