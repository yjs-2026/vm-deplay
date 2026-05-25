# VM 自动化部署工具（VMware + cloud-init）

通过 `govc` + `cloud-init` 实现 VMware 虚拟机一键自动化部署，交互式 TUI 收集参数，无需手动配置。cloud-init 数据通过 VMware guestinfo 机制注入，**无需 ISO 文件**。

## 环境要求

- **VMware vCenter / ESXi**（支持自签名证书）
- **govc CLI**（已安装并在 PATH 中）
- **Ubuntu 24.04 OVF 模板**（已上传至 vCenter Datastore，且模板内置 cloud-init）
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
│   ├── create-vm.sh              # govc 创建 VM + guestinfo 注入
│   └── verify.sh                 # 部署成功验证
└── outputs/
    └── deployment-log.txt         # 部署日志
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
2. **VM 规格** — VM 名称、OVF 路径、Datastore、Portgroup、资源池、CPU、内存
3. **网络配置** — 静态 IP、子网掩码、网关、DNS
4. **系统配置** — sudo 用户名/密码、SSH 公钥、第二块盘大小
5. **软件包下载** — FTP URL（匿名）、解压目录
6. **确认部署** — 显示汇总信息，用户确认后开始

## cloud-init 自动化内容

| 功能 | 说明 |
|------|------|
| 静态网络 | Netplan YAML 配置（Ubuntu 24.04） |
| SSH 公钥 | 注入指定用户的 `~/.ssh/authorized_keys` |
| sudo 用户 | 非 root，创建并授予 sudo 无密码权限 |
| 第二块盘 | 自动分区/格式化/ext4，挂载 `/home` |
| 软件包 | FTP 匿名下载 `wget` + `tar -xzf` 解压到指定目录 |
| 磁盘扩展 | `growpart` + `resize2fs` 扩展根分区 |
| 密码登录 | 部署完成后自动禁用（仅允许密钥） |

## 技术原理

VMware 原生支持通过 ExtraConfig (guestinfo) 传递 cloud-init 数据：

| guestinfo 键 | 内容 |
|---|---|
| `guestinfo.metadata` | instance-id + local-hostname（YAML） |
| `guestinfo.userdata` | 完整 #cloud-config（base64 编码） |
| `guestinfo.have-cloud-init` | 标识位（`true`） |

VM 开机后 cloud-init 自动从 guestinfo 读取，无需 CD-ROM 或 ISO。

## 验证方式

部署完成后脚本自动验证：

```bash
# 1. SSH 端口开放
nc -zv $IP 22

# 2. cloud-init 完成
ssh $USER@$IP "cloud-init status"  # 期望输出: status: done

# 3. 第二块盘挂载
ssh $USER@$IP "df -h | grep /home"

# 4. 软件包存在
ssh $USER@$IP "ls $DEST_DIR/"
```

## 部署日志

日志文件：`outputs/deployment-log.txt`

每次部署会话追加写入，包含完整的时间戳和操作记录。

## 常见问题

**Q: vCenter 使用自签名证书，govc 报错怎么办？**
A: 脚本已设置 `GOVC_INSECURE=1`，自动信任自签名证书。

**Q: OVF 导入失败？**
A: 检查 Datastore 路径是否正确（格式：`/datastore-name/ova/ubuntu2404.ovf`），以及 govc 是否有足够权限。

**Q: cloud-init 没有执行？**
A: 确认 OVF 模板已内置 cloud-init 客户端（Ubuntu 24.04 官方镜像默认包含）。cloud-init 数据通过 guestinfo 注入，检查 VM 的 ExtraConfig 中是否有 `guestinfo.userdata`。

**Q: 静态 IP 不生效？**
A: 某些 OVF 模板自带网络管理，与 cloud-init 冲突。cloud-init 会通过 Netplan override 覆盖，VM 重启后生效。
