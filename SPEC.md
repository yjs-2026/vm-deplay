# VM 自动化部署项目 — 设计规格书

## 1. 项目概述

**目标：** 通过 `govc` + `cloud-init` 实现 VMware 虚拟机一键自动化部署，交互式 TUI 收集参数，无需手动配置。

**环境要求：**
- VMware vCenter / ESXi（自签名证书）
- govc CLI（已安装并配置环境变量）
- Ubuntu 24.04 OVF 模板（已上传至 vCenter Datastore）
- Bash 4.0+

## 2. 系统架构

```
deploy.sh (主入口，TUI 交互)
    │
    ├── config/cloud-init-ubuntu2404.tpl  ← cloud-init user-data 模板
    │
    scripts/
        ├── gen-cloud-init.sh   ← 渲染 user-data 模板
        ├── create-vm.sh        ← govc 创建/部署 VM
        └── verify.sh           ← 部署成功验证
    │
    outputs/
        └── deployment-log.txt  ← 部署日志
```

## 3. TUI 交互字段

### 步骤1：vCenter 连接
| 字段 | 类型 | 说明 |
|------|------|------|
| vCenter URL | 文本 | 例：https://vc.example.com |
| Username | 文本 | 格式：user@domain |
| Password | 隐藏 | 不回显 |

### 步骤2：VM 位置与规格
| 字段 | 类型 | 说明 |
|------|------|------|
| VM 名称 | 文本 | 部署后的显示名 |
| OVF 模板路径 | 文本 | Datastore 路径，如 /datastore/ova/ubuntu2404.ovf |
| Datastore | 文本 | 目标存储名称 |
| Portgroup / 网络 | 文本 | 目标网络标签 |
| 集群 / Resource Pool | 文本 | 可留空使用默认 |

### 步骤3：网络配置
| 字段 | 类型 | 说明 |
|------|------|------|
| IP 地址 | 文本 | 静态 IPv4 |
| 子网掩码位数 | 数字 | 如 24 |
| 网关 | 文本 | 默认路由 |
| DNS 服务器 | 文本 | 逗号分隔，如 8.8.8.8,8.8.4.4 |

### 步骤4：系统配置
| 字段 | 类型 | 说明 |
|------|------|------|
| sudo 用户名 | 文本 | 非 root，如 ubuntu |
| sudo 用户密码 | 隐藏 | 加密存储于 user-data |
| SSH 公钥 | 多行文本 | 支持粘贴或从文件读取 |
| 第二块盘大小 | 数字 | 单位：GB，0 表示不添加 |

### 步骤5：软件包下载
| 字段 | 类型 | 说明 |
|------|------|------|
| FTP URL | 文本 | 匿名下载，如 ftp://192.168.1.100/pkg.tar.gz |
| 解压目标目录 | 文本 | 如 /opt/app |
| 下载文件名 | 文本 | 保存到本地临时文件名 |

## 4. cloud-init 自动化内容

### 4.1 静态网络
通过 Netplan YAML 配置（Ubuntu 24.04）：
- 禁用 cloud-init 网络管理（`network: {version: 2, renderer: networkd}`)
- 写入静态 IP/网关/DNS 到 `/etc/netplan/99-cloud-init.yaml`
- `netplan apply` 生效

### 4.2 SSH 公钥
- 写入指定用户的 `~/.ssh/authorized_keys`
- 禁用密码登录（`PasswordAuthentication no`）

### 4.3 sudo 用户
- 创建非 root sudo 用户（默认：ubuntu）
- 密码通过 `chpasswd` 加密注入（SHA512）
- 加入 sudo 组，无密码 sudo

### 4.4 第二块盘
- `lsblk` 检测第二块未挂载磁盘（通常 `/dev/sdb`）
- `mkfs.ext4` 格式化
- 挂载到 `/home`
- 写入 `/etc/fstab` 持久化

### 4.5 软件包下载
- `runcmd` 执行 `wget -O /tmp/<file> <ftp-url>`
- `tar -xzf` 解压到指定目录
- 清理临时文件

### 4.6 磁盘扩展
- `growpart` 扩展分区表
- `resize2fs` 扩展文件系统

## 5. govc 操作流程

```bash
# 1. 导出 vCenter 环境变量
export GOVC_URL=$VC_URL
export GOVC_USERNAME=$USER
export GOVC_PASSWORD=$PASS
export GOVC_TLS_CA_CERTS=$VC_CERT_PATH   # 自签名证书
export GOVC_INSECURE=1                    # 允许不安全连接

# 2. 创建 VM（从 OVF 部署）
govc import.ovf -ds=$DATASTORE -pool=$POOL $OVF_PATH $VM_NAME

# 3. 挂载 cloud-init ISO（user-data + network-config）
govc vm.disk.attach -vm $VM_NAME -size $SECOND_DISK_SIZEG  # 可选第二块盘
govc device.cdrom.insert -vm $VM_NAME -file "[$DATASTORE] $ISO_FILE"
govc vm.change -vm $VM_NAME -c $CPU -m $MEMORY_MB

# 4. 开机
govc vm.power -on $VM_NAME

# 5. 等待 cloud-init 完成（verify.sh）
```

## 6. 验证方式

| 步骤 | 命令 | 成功条件 |
|------|------|----------|
| VM 开机 | `govc vm.power -on` | 无错误 |
| SSH 端口开放 | `nc -zv $IP 22` | 连接成功 |
| cloud-init 完成 | `ssh $USER@$IP cloud-init status` | 输出 `status: done` |
| 第二块盘挂载 | `ssh $USER@$IP df -h \| grep /home` | 有输出 |
| 软件包存在 | `ssh $USER@$IP ls $DEST_DIR/` | 文件列表非空 |

验证超时：600 秒，轮询间隔 15 秒。

## 7. 部署日志

日志文件：`outputs/deployment-log.txt`

格式：
```
=== VM 部署日志 | $(date) ===
vCenter    : $VC_URL
VM 名称    : $VM_NAME
IP 地址    : $IP
Datastore  : $DATASTORE
...

[$(timestamp)] 开始部署 VM...
[$(timestamp)] cloud-init ISO 生成完成
[$(timestamp)] VM 创建成功，开始开机...
[$(timestamp)] VM 已开机，等待 SSH...
[$(timestamp)] cloud-init 完成，验证通过
[$(timestamp)] 第二块盘已挂载 /home
[$(timestamp)] 软件包下载完成
=== 部署成功 ===
```

## 8. 目录结构

```
vm-deplay/
├── README.md
├── SPEC.md
├── deploy.sh
├── config/
│   └── cloud-init-ubuntu2404.tpl
├── scripts/
│   ├── gen-cloud-init.sh
│   ├── create-vm.sh
│   └── verify.sh
├── outputs/
│   └── deployment-log.txt
└── requirements.txt
```

## 9. 依赖项

- `govc`（需预先安装并配置 GOVC_ 环境变量或传入参数）
- `dialog` 或 `whiptail`（TUI 交互）
- `sshpass`（非交互式 SSH 密码验证）
- `cloud-utils`（growpart 命令）
- `openssh-client`（ssh/scp 命令）
- `netcat-openbsd` 或 `nc`（端口检测）
