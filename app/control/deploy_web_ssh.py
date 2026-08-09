#!/usr/bin/env python3
"""
Deploy NHANH chỉ phần web tĩnh (index.html/app.js/docs.js/style.css…) lên iPhone
jailbreak qua SSH — KHÔNG cần build .deb, KHÔNG cần restart daemon (file tĩnh phục
vụ tươi mỗi request).

    python control/deploy_web_ssh.py [ip]

Mặc định: ip=192.168.1.157, user=mobile, pass=1.
Thư mục web trên máy: /var/jb/usr/local/iosauto/web (root sở hữu → upload vào
/var/mobile rồi sudo cp vào).
"""
import os
import sys
import paramiko

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEB_DIR = os.path.join(ROOT, "web")
DEST = "/var/jb/usr/local/iosauto/web"
STAGE = "/var/mobile/iosauto_web_stage"
IP = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else "192.168.1.157"
USER, PW = "mobile", "1"

# Chỉ đẩy file tĩnh web (bỏ qua thư mục con, file tạm).
EXTS = (".html", ".js", ".css", ".png", ".ico", ".svg")


def run(ssh, cmd, sudo=False):
    if sudo:
        cmd = f"echo {PW} | sudo -S -p '' {cmd}"
    _, stdout, stderr = ssh.exec_command(cmd, timeout=60)
    out = stdout.read().decode(errors="replace")
    err = stderr.read().decode(errors="replace")
    rc = stdout.channel.recv_exit_status()
    print(f"  {'#' if sudo else '$'} {cmd.split('|')[-1].strip()}")
    if out.strip():
        print("    " + out.strip().replace("\n", "\n    "))
    if err.strip() and "Password" not in err:
        print("    [err] " + err.strip().replace("\n", "\n    "))
    return rc


def main():
    files = sorted(f for f in os.listdir(WEB_DIR)
                   if f.lower().endswith(EXTS) and os.path.isfile(os.path.join(WEB_DIR, f)))
    if not files:
        print("Không thấy file web nào trong app/web/.")
        return 1

    print(f"Kết nối {USER}@{IP} …")
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(IP, username=USER, password=PW, timeout=15,
                look_for_keys=False, allow_agent=False)

    # 1) Upload vào thư mục tạm (mobile ghi được).
    run(ssh, f"rm -rf {STAGE} && mkdir -p {STAGE}")
    print(f"Upload {len(files)} file → {STAGE} …")
    sftp = ssh.open_sftp()
    for f in files:
        sftp.put(os.path.join(WEB_DIR, f), f"{STAGE}/{f}")
        print(f"  ↑ {f}")
    sftp.close()

    # 2) Copy sang thư mục web thật bằng sudo, chỉnh quyền đọc.
    print(f"Cài vào {DEST} …")
    run(ssh, f"mkdir -p {DEST}", sudo=True)
    run(ssh, f"cp -f {STAGE}/* {DEST}/", sudo=True)
    run(ssh, f"chmod 644 {DEST}/*", sudo=True)
    run(ssh, f"rm -rf {STAGE}")
    run(ssh, f"ls -la {DEST}", sudo=True)

    ssh.close()
    print(f"\nXong. Mở lại (Ctrl/Cmd+Shift+R để bỏ cache): http://{IP}:8080")
    return 0


if __name__ == "__main__":
    sys.exit(main())
