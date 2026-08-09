#!/usr/bin/env python3
"""
Deploy .deb lên iPhone jailbreak qua SSH (paramiko) + cài bằng dpkg + restart daemon.

    python control/deploy_ssh.py [ip] [--only daemon|app|all]

Mặc định: ip=192.168.1.157, user=mobile, pass=1 (sudo cũng dùng pass này).
Đường dẫn rootless: dpkg=/var/jb/usr/bin/dpkg, launchctl=/var/jb/bin/launchctl.
"""
import os
import sys
import time
import paramiko

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEBS_DIR = os.path.join(ROOT, "repo", "debs")
IP = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else "192.168.1.157"
USER, PW = "mobile", "1"


def run(ssh, cmd, sudo=False):
    if sudo:
        cmd = f"echo {PW} | sudo -S -p '' {cmd}"
    stdin, stdout, stderr = ssh.exec_command(cmd, timeout=60)
    out = stdout.read().decode(errors="replace")
    err = stderr.read().decode(errors="replace")
    rc = stdout.channel.recv_exit_status()
    tag = "$" if not sudo else "#"
    print(f"  {tag} {cmd.split('|')[-1].strip()}")
    if out.strip():
        print("    " + out.strip().replace("\n", "\n    "))
    if err.strip() and "Password" not in err:
        print("    [err] " + err.strip().replace("\n", "\n    "))
    return rc, out, err


def main():
    debs = sorted(f for f in os.listdir(DEBS_DIR) if f.endswith(".deb"))
    if not debs:
        print("Không có .deb trong repo/debs/. Chạy gh run download trước.")
        return 1
    print(f"Kết nối {USER}@{IP} …")
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(IP, username=USER, password=PW, timeout=15,
                look_for_keys=False, allow_agent=False)

    print("Upload .deb → /var/mobile/ …")
    sftp = ssh.open_sftp()
    for d in debs:
        sftp.put(os.path.join(DEBS_DIR, d), f"/var/mobile/{d}")
        print(f"  ↑ {d}")
    sftp.close()

    # Cài daemon trước (app Depends daemon).
    order = sorted(debs, key=lambda x: 0 if "daemon" in x else 1)
    print("Cài đặt …")
    for d in order:
        run(ssh, f"/var/jb/usr/bin/dpkg -i /var/mobile/{d}", sudo=True)

    print("Khởi động lại daemon …")
    run(ssh, "/var/jb/bin/launchctl kickstart -k system/com.iosauto.daemon", sudo=True)
    time.sleep(1)
    run(ssh, "/var/jb/bin/launchctl print system/com.iosauto.daemon | grep -E 'state|pid' | head -3", sudo=True)
    ssh.close()
    print(f"\nXong. Kiểm tra: http://{IP}:8080")
    return 0


if __name__ == "__main__":
    sys.exit(main())
