#!/usr/bin/env python3
"""
Sileo repo server (chạy trên PC) — phương thức cài "TesT" trong promt.md.

Đặt các file .deb vào  repo/debs/  rồi chạy:
    python repo/serve_repo.py [port]        (mặc định 8090)

Trên iPhone: Sileo → Sources → thêm  http://<ip-pc-trong-lan>:8090
Ví dụ PC có IP 192.168.1.50 → nguồn: http://192.168.1.50:8090

Repo dạng "flat" (Release + Packages ở gốc) — Sileo/Zebra đều đọc được.
Metadata (Package/Version/Depends…) đọc trực tiếp từ daemon/control + app/control
để khỏi phải bung .deb (tránh phụ thuộc zstd/xz).
"""
import gzip
import hashlib
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_DIR = os.path.join(ROOT, "repo")
DEBS_DIR = os.path.join(REPO_DIR, "debs")
CONTROLS = [os.path.join(ROOT, "daemon", "control"),
            os.path.join(ROOT, "app", "control"),
            os.path.join(ROOT, "tweak", "control")]


def parse_control(path):
    """control → dict giữ nguyên thứ tự field."""
    fields = {}
    if not os.path.isfile(path):
        return None
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            if ":" in line and not line.startswith(" "):
                k, v = line.split(":", 1)
                fields[k.strip()] = v.strip()
    return fields


def hashes(data):
    return (hashlib.md5(data).hexdigest(),
            hashlib.sha1(data).hexdigest(),
            hashlib.sha256(data).hexdigest())


def build_packages():
    """Ghép mỗi .deb với control theo tên Package (tiền tố tên file)."""
    controls = {}
    for c in CONTROLS:
        d = parse_control(c)
        if d and d.get("Package"):
            controls[d["Package"]] = d

    stanzas = []
    if not os.path.isdir(DEBS_DIR):
        os.makedirs(DEBS_DIR, exist_ok=True)
    for fn in sorted(os.listdir(DEBS_DIR)):
        if not fn.endswith(".deb"):
            continue
        pkg_name = fn.split("_", 1)[0]     # com.iosauto.daemon_0.2.0_... → com.iosauto.daemon
        ctrl = controls.get(pkg_name)
        if not ctrl:
            print(f"  ⚠️  bỏ qua {fn}: không có control cho '{pkg_name}'")
            continue
        with open(os.path.join(DEBS_DIR, fn), "rb") as f:
            data = f.read()
        md5, sha1, sha256 = hashes(data)

        lines = []
        # Giữ các field control chuẩn theo thứ tự thường gặp.
        order = ["Package", "Name", "Version", "Architecture", "Maintainer",
                 "Author", "Section", "Depends", "Description"]
        for k in order:
            if k in ctrl:
                lines.append(f"{k}: {ctrl[k]}")
        lines.append(f"Filename: debs/{fn}")
        lines.append(f"Size: {len(data)}")
        lines.append(f"MD5sum: {md5}")
        lines.append(f"SHA1: {sha1}")
        lines.append(f"SHA256: {sha256}")
        stanzas.append("\n".join(lines))
        print(f"  + {pkg_name} {ctrl.get('Version','?')} ({len(data)} bytes)")

    return ("\n\n".join(stanzas) + "\n").encode("utf-8") if stanzas else b""


def build_release(packages_bytes):
    gz = gzip.compress(packages_bytes)
    md5p, sha1p, sha256p = hashes(packages_bytes)
    md5g, sha1g, sha256g = hashes(gz)
    rel = (
        "Origin: iOSAuto\n"
        "Label: iOSAuto\n"
        "Suite: stable\n"
        "Version: 1.0\n"
        "Codename: ios\n"
        "Architectures: iphoneos-arm64\n"
        "Components: main\n"
        "Description: iOSAuto private test repo\n"
        "MD5Sum:\n"
        f" {md5p} {len(packages_bytes)} Packages\n"
        f" {md5g} {len(gz)} Packages.gz\n"
        "SHA256:\n"
        f" {sha256p} {len(packages_bytes)} Packages\n"
        f" {sha256g} {len(gz)} Packages.gz\n"
    )
    return rel.encode("utf-8"), gz


def lan_ip():
    import socket
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


class Repo:
    def __init__(self):
        self.rebuild()

    def rebuild(self):
        print("Quét .deb trong", DEBS_DIR)
        self.packages = build_packages()
        self.release, self.packages_gz = build_release(self.packages)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        print("  →", self.path)

    def _send(self, code, data, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        p = self.path.split("?", 1)[0].lstrip("/")
        repo = self.server.repo
        if p in ("", "Release"):
            return self._send(200, repo.release, "text/plain")
        if p == "Packages":
            return self._send(200, repo.packages, "text/plain")
        if p == "Packages.gz":
            return self._send(200, repo.packages_gz, "application/gzip")
        if p.startswith("debs/") and ".." not in p:
            fp = os.path.join(REPO_DIR, p)
            if os.path.isfile(fp):
                with open(fp, "rb") as f:
                    return self._send(200, f.read(), "application/x-debian-package")
        return self._send(404, b"not found", "text/plain")


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8090
    srv = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    srv.repo = Repo()
    ip = lan_ip()
    if not srv.repo.packages:
        print("\n⚠️  Chưa có .deb nào trong repo/debs/.")
        print("   Tải artifact CI: gh run download --repo tunganh2k55/ios-automation -n iosauto-debs -D repo/debs")
    print("\n" + "=" * 52)
    print(f"  Sileo source:  http://{ip}:{port}")
    print(f"  (local test):  http://127.0.0.1:{port}")
    print("=" * 52)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\ndừng.")


if __name__ == "__main__":
    main()
