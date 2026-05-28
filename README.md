# VM 自动化部署工具（VMware + cloud-init）

通过 `govc` + `cloud-init` 实现 VMware 虚拟机一键自动化部署，交互式 TUI 收集参数，无需手动配置。cloud-init 数据通过 VMware guestinfo 机制注入，**无需 ISO 文件**。

## 环境要求

- **VMware vCenter / ESXi**（支持自签名证书）
- **govc CLI**（已安装并在 PATH 中）
- **Ubuntu 24.04 VM 模板**（已上传至 vCenter，模板内置 cloud-init）
- **Bash 4.0+**

## 依赖安装

```bash
# Ubuntu/Debian
apt install dialog govc python3 sshpass netcat-openbsd

# macOS (Homebrew)
brew install dialog govc python3 sshpass netcat
```

## 目录结构

```
vm-deplay/
├── README.md
├── SPEC.md
├── deploy.sh                      # 主入口（TUI 交互）
├── scripts/
│   ├── create-vm.sh              # govc 克隆 VM + guestinfo 注入
│   ├── verify.sh                 # 部署成功验证
│   └── gen-userdata.py           # 生成 cloud-init userdata（Python）
└── outputs/
    ├── deployment-log.txt         # 部署日志
    ├── cloud-init-userdata.yaml  # 生成的 userdata
    └── cloud-init-metadata.yaml  # 生成的 metadata
```

## 快速开始

```bash
git clone https://github.com/yjs-2026/vm-deplay.git
cd vm-deplay
chmod +x deploy.sh scripts/*.sh
./deploy.sh
```

## TUI 交互步骤

1. **vCenter 连接** — URL、用户名、密码
2. **VM 规格** — VM 名称、模板路径、Datastore、Portgroup、资源池、CPU、内存
3. **网络配置** — 静态 IP、子网掩码位数、网关、DNS、网卡名称（cloud-init 网络配置中的设备名）
4. **系统配置** — sudo 用户名/密码、SSH 公钥（可选）
5. **确认部署** — 显示汇总信息，用户确认后开始
6. **自动验证** — 等待 SSH 端口开放、cloud-init 完成、网络配置验证

## cloud-init 自动化内容

| 功能 | 说明 |
|------|------|
| 静态网络 | Network Config v2（Cloud Config 格式），写入 metadata |
| SSH 公钥 | 注入用户的 `ssh-authorized-keys`（嵌套在用户对象下，非顶层 key） |
| sudo 用户 | 非 root，创建并授予 sudo 无密码权限 |
| qoder 解压 | VM 首次启动时自动解压 `/var/soft/qoder.tgz` 到 `/home/<user>/` |
| 密码登录 | 启用 SSH 密码认证（`PasswordAuthentication yes`） |
| 磁盘扩展 | `growpart` + `resize2fs` 扩展根分区（模板已完成） |

## 技术原理

VMware 原生支持通过 ExtraConfig (guestinfo) 传递 cloud-init 数据：

| guestinfo 键 | 内容 | 格式 |
|---|---|---|
| `guestinfo.metadata` | instance-id + local-hostname + network | YAML，gzip+base64 |
| `guestinfo.userdata` | 完整 #cloud-config | YAML，gzip+base64 |
| `guestinfo.have-cloud-init` | 标识位 | `true` |

VM 开机后 cloud-init 自动从 guestinfo 读取，无需 CD-ROM 或 ISO。

### metadata 网络配置格式

```yaml
instance-id: vm01-1748500000
local-hostname: vm01
network:
  version: 2
  ethernets:
    ens33:
      addresses:
        - 192.168.218.11/24
      nameservers:
        addresses:
          - 192.168.218.2
      routes:
        - to: default
          via: 192.168.218.2
      dhcp4: false
      optional: false
```

### userdata SSH 公钥格式

```yaml
#cloud-config
users:
  - name: ubuntu
    ssh-authorized-keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... user@host
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    plain_text_passwd: VMware1!
```

## 验证方式

部署完成后脚本自动验证：

```bash
# 1. SSH 端口开放
nc -zv 192.168.218.11 22

# 2. cloud-init 完成
sshpass -p 'VMware1!' ssh -o StrictHostKeyChecking=yes ubuntu@192.168.218.11 "cloud-init status"
# 期望输出: status: done

# 3. 静态 IP 生效
sshpass -p 'VMware1!' ssh -o StrictHostKeyChecking=yes ubuntu@192.168.218.11 "ip addr show ens33 | grep inet"

# 4. qoder 解压
sshpass -p 'VMware1!' ssh -o StrictHostKeyChecking=yes ubuntu@192.168.218.11 "ls /home/ubuntu/"
```

## 部署日志

日志文件：`outputs/deployment-log.txt`

每次部署会话追加写入，包含完整的时间戳和操作记录。

## 已知问题

**Q: 静态 IP 不生效？**
A: 确认 metadata 中的 `network.version: 2` 和 `ethernets` 设备名与 VM 内实际网卡名一致。某些模板镜像可能使用不同网卡名（如 `ens33` vs `enp0s3`），cloud-init 会忽略不匹配的设备配置。

**Q: SSH 公钥未注入？**
A: 确保公钥以 `ssh-ed25519` 或 `ssh-rsa` 开头，不含多余空格或换行符。

**Q: cloud-init 没有执行？**
A: 确认 VM 模板已内置 cloud-init 客户端（Ubuntu 24.04 官方镜像默认包含）。检查 VM 的 ExtraConfig 中是否有 `guestinfo.have-cloud-init=true`。