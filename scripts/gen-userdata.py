#!/usr/bin/env python3
"""
gen-userdata.py — 生成 cloud-init userdata
用法: gen-userdata.py <vm_name> <sudo_user> <sudo_pass> <ssh_keys_yaml> <output_path>
"""
import sys
import yaml

def main():
    if len(sys.argv) != 6:
        print(f"用法: {sys.argv[0]} <vm_name> <sudo_user> <sudo_pass> <ssh_keys_yaml> <output_path>", file=sys.stderr)
        sys.exit(1)

    vm_name   = sys.argv[1]
    sudo_user = sys.argv[2]
    sudo_pass = sys.argv[3]
    ssh_keys  = sys.argv[4]
    out_path  = sys.argv[5]

    # qoder 解压：用 sudo_user 查 home 目录
    tar_cmd = (
        f"bash -c \"TARGET=$(getent passwd {sudo_user} | cut -d: -f6) "
        f"&& [ -n \\$TARGET ] && tar -xzf /var/soft/qoder.tgz -C \\$TARGET 2>/dev/null || true\""
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
                "plain_text_passwd": sudo_pass,
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

    if ssh_keys.strip():
        keys_list = [k.strip() for k in ssh_keys.strip().splitlines() if k.strip()]
        userdata["ssh_authorized_keys"] = keys_list

    with open(out_path, "w") as f:
        f.write("#cloud-config\n")
        yaml.dump(userdata, f, default_flow_style=False, allow_unicode=True, sort_keys=False)

    print(f"Generated: {out_path}")

if __name__ == "__main__":
    main()
