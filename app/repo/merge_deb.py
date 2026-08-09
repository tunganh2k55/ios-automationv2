#!/usr/bin/env python3
"""
Gộp 3 .deb con (daemon + touch + app) thành MỘT gói `com.iosauto` để khách cài 1 lần.

    python app/repo/merge_deb.py <debs_dir> <out_dir>

- Bung payload 3 gói vào chung 1 cây (đường dẫn không đè nhau) → thêm DEBIAN từ app/dist/
  (control + postinst + prerm) → đóng lại thành `com.iosauto_<ver>_iphoneos-arm64.deb`.
- Nhị phân daemon/tweak đã được ldid ký (entitlements) lúc build gói con → giữ nguyên bytes,
  KHÔNG cần ký lại.
YÊU CẦU: `dpkg-deb` (có trên runner CI). Version lấy từ app/dist/control.
"""
import glob
import os
import shutil
import subprocess
import sys
import tempfile

APP_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # app/
DIST = os.path.join(APP_DIR, "dist")
SUB_PREFIXES = ("com.iosauto.daemon", "com.iosauto.touch", "com.iosauto.app")


def ctrl_field(path, key):
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.startswith(key + ":"):
                return line.split(":", 1)[1].strip()
    return None


def main():
    if len(sys.argv) < 3:
        print("Dùng: merge_deb.py <debs_dir> <out_dir>")
        return 2
    debs_dir, out_dir = sys.argv[1], sys.argv[2]
    subs = [d for d in sorted(glob.glob(os.path.join(debs_dir, "*.deb")))
            if os.path.basename(d).startswith(SUB_PREFIXES)]
    if len(subs) < 3:
        print("Thiếu .deb con (cần daemon + touch + app). Thấy:", [os.path.basename(x) for x in subs])
        return 1

    version = ctrl_field(os.path.join(DIST, "control"), "Version")
    os.makedirs(out_dir, exist_ok=True)
    out_deb = os.path.join(out_dir, f"com.iosauto_{version}_iphoneos-arm64.deb")

    root = tempfile.mkdtemp()
    try:
        for deb in subs:
            print("  bung", os.path.basename(deb))
            subprocess.run(["dpkg-deb", "-x", deb, root], check=True)   # payload → chung 1 cây
        deb_dir = os.path.join(root, "DEBIAN")
        os.makedirs(deb_dir, exist_ok=True)
        shutil.copy(os.path.join(DIST, "control"), os.path.join(deb_dir, "control"))
        # postinst/prerm: chuẩn hoá LF (tránh CRLF từ Windows làm hỏng #!/bin/sh) + chmod 0755.
        for s in ("postinst", "prerm"):
            src = os.path.join(DIST, s)
            if os.path.isfile(src):
                txt = open(src, encoding="utf-8").read().replace("\r\n", "\n").replace("\r", "\n")
                dst = os.path.join(deb_dir, s)
                with open(dst, "w", encoding="utf-8", newline="\n") as f:
                    f.write(txt)
                os.chmod(dst, 0o755)
        # --root-owner-group: ép mọi file về root:root (dpkg-deb -x bung dưới user CI, không phải root)
        # → LaunchDaemon/binary phải thuộc root thì launchd mới nạp. -Zgzip khớp gói con.
        subprocess.run(["dpkg-deb", "--root-owner-group", "-Zgzip", "--build", root, out_deb], check=True)
        print("✓ Đã gộp →", out_deb, f"({os.path.getsize(out_deb)} bytes)")
    finally:
        shutil.rmtree(root, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
