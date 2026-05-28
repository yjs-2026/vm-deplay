#!/usr/bin/env python3
"""
gen-userdata.py — 生成 cloud-init userdata
用法: gen-userdata.py <vm_name> <sudo_user> <sudo_pass> <ssh_keys_yaml> <output_path>
"""
import sys
import yaml
import hashlib
import secrets


def encrypt_password(plain):
    """生成 SHA512 加密密码（cloud-init hashed_passwd 要求格式 $6$salt$hash）"""
    salt = secrets.token_hex(8)
    key = hashlib.sha512((salt + plain).encode()).digest()
    return f"$6${salt}${key.hex()[:86]}"


def main():
    if len(sys.argv) != 6:
        print(f"用法: {sys.argv[0]} <vm_name> <sudo_user> <sudo_pass> <ssh_keys_yaml> <output_path>", file=sys.stderr)
        sys.exit(1)

    vm_name   = sys.argv[1]
    sudo_user = sys.argv[2]
    sudo_pass = sys.argv[3]
    ssh_keys  = sys.argv[4]
    out_path  = sys.argv[5]

    # 密码加密（使用 SHA512，cloud-init 推荐）
    hashed_pass = encrypt_password(sudo_pass)

    # qoder 解压：用 sudo_user 查 home 目录
    tar_cmd = (
        f"bash -c \"TARGET=$(getent passwd {sudo_user} | cut -d: -f6) "
        f"&& [ -n \\\\$TARGET ] && tar -xzf /var/soft/qoder.tgz -C \\\\$TARGET 2>/dev/null || true\""
    )

    userdata = {
        "hostname": vm_name,
        "manage_etc_hosts": True,
        "users": [
            {
                "name": sudo_user,
                "groups": "sudo",
                "shell": "/bin/bash",
                "sudo": "ALL=(ALL) NOPASSWD:ALL",
                "lock_passwd": False,
                "hashed_passwd": hashed_pass,
            }
        ],
        "packages": [
            "curl", "wget", "tar", "gzip", "net-tools",
            "rsync", "cloud-init", "cloud-utils", "growpart", "parted",
        ],
        "runcmd": [
            tar_cmd,
            "bash -c 'ls -la /home/*/.qoder/ 2>/dev/null || true'",
            "bash -c \"sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config && systemctl restart ssh\"",
        ],
        "power_state": {
            "mode": "reboot",
            "delay": "now",
            "condition": True,
        },
    }

    # SSH 公钥必须嵌套在对应用户的 ssh-authorized-keys 下，不是顶层 key
    if ssh_keys.strip():
        # ssh_keys 格式为多行 "- ssh-ed25519 ..."，需剥掉 "- " 前缀还原原始公钥
        keys_list = []
        for line in ssh_keys.strip().splitlines():
            line = line.strip()
            if not line:
                continue
            if line.startswith("- "):
                line = line[2:]
            keys_list.append(line)
        userdata["users"][0]["ssh-authorized-keys"] = keys_list

    with open(out_path, "w") as f:
        f.write("#cloud-config\n")
        yaml.dump(userdata, f, default_flow_style=False, allow_unicode=True, sort_keys=False)

    print(f"Generated: {out_path}")


if __name__ == "__main__":
    main()
