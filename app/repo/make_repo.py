#!/usr/bin/env python3
"""
Sinh repo APT/Sileo TĨNH (Release + Packages + Packages.gz + debs/) để up lên domain.

    python repo/make_repo.py <debs_dir> <out_dir> [repo_url]

- <debs_dir>  : thư mục chứa *.deb (CI: out/ ; local: repo/debs/)
- <out_dir>   : thư mục kết quả (up thẳng lên web host)  → chứa Release, Packages,
                Packages.gz, debs/*.deb, CydiaIcon.png, index.html
- [repo_url]  : URL công khai của repo (mặc định https://apt.iosautos.com) — chỉ dùng
                cho trang index.html; Sileo KHÔNG cần URL trong metadata (Filename tương đối).

Đọc metadata từ CẢ 3 control (daemon + app + tweak) — khác serve_repo.py (bỏ sót tweak).
Không cần bung .deb (tránh phụ thuộc zstd/xz).
"""
import gzip
import hashlib
import os
import shutil
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

# app/repo/make_repo.py → APP_DIR = app/
APP_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Gói gộp `com.iosauto` (dist/control) là gói phân phối chính. Vẫn đọc 3 control con để
# make_repo dùng được cả khi repo chứa .deb con (linh hoạt; khớp theo tên gói ở tiền tố file).
CONTROLS = [
    os.path.join(APP_DIR, "dist", "control"),
    os.path.join(APP_DIR, "daemon", "control"),
    os.path.join(APP_DIR, "app", "control"),
    os.path.join(APP_DIR, "tweak", "control"),
]
# Icon (hiện cho NGUỒN + từng GÓI trong Sileo, field Icon trỏ về /repo/CydiaIcon.png).
# Ưu tiên icon app vuông 180x180; dự phòng AppLogo/logo.
ICON_CANDIDATES = [
    os.path.join(APP_DIR, "app", "Resources", "AppIcon60x60@3x.png"),
    os.path.join(APP_DIR, "app", "Resources", "AppLogo.png"),
    os.path.join(APP_DIR, "logo.png"),
]

# Thông tin repo (đổi tại đây nếu cần).
REPO_ORIGIN = "iOSAuto"
REPO_LABEL = "iOSAuto"
REPO_DESC = "iOSAuto — iPhone automation (iOS 15-16 rootless)"


def parse_control(path):
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


def build_packages(debs_dir):
    controls = {}
    for c in CONTROLS:
        d = parse_control(c)
        if d and d.get("Package"):
            controls[d["Package"]] = d

    stanzas = []
    for fn in sorted(os.listdir(debs_dir)):
        if not fn.endswith(".deb"):
            continue
        pkg = fn.split("_", 1)[0]
        ctrl = controls.get(pkg)
        if not ctrl:
            print(f"  ⚠️  bỏ qua {fn}: không có control cho '{pkg}'")
            continue
        with open(os.path.join(debs_dir, fn), "rb") as f:
            data = f.read()
        md5, sha1, sha256 = hashes(data)
        order = ["Package", "Name", "Version", "Architecture", "Maintainer",
                 "Author", "Section", "Depends", "Conflicts", "Replaces", "Provides",
                 "Icon", "Depiction", "Description"]
        lines = [f"{k}: {ctrl[k]}" for k in order if k in ctrl]
        lines += [f"Filename: debs/{fn}", f"Size: {len(data)}",
                  f"MD5sum: {md5}", f"SHA1: {sha1}", f"SHA256: {sha256}"]
        stanzas.append("\n".join(lines))
        print(f"  + {pkg} {ctrl.get('Version','?')} ({len(data)} bytes)")

    if not stanzas:
        return b""
    return ("\n\n".join(stanzas) + "\n").encode("utf-8")


def build_release(packages_bytes):
    gz = gzip.compress(packages_bytes)
    md5p, _, sha256p = hashes(packages_bytes)
    md5g, _, sha256g = hashes(gz)
    rel = (
        f"Origin: {REPO_ORIGIN}\n"
        f"Label: {REPO_LABEL}\n"
        "Suite: stable\n"
        "Version: 1.0\n"
        "Codename: ios\n"
        "Architectures: iphoneos-arm64\n"
        "Components: main\n"
        f"Description: {REPO_DESC}\n"
        "MD5Sum:\n"
        f" {md5p} {len(packages_bytes)} Packages\n"
        f" {md5g} {len(gz)} Packages.gz\n"
        "SHA256:\n"
        f" {sha256p} {len(packages_bytes)} Packages\n"
        f" {sha256g} {len(gz)} Packages.gz\n"
    )
    return rel.encode("utf-8"), gz


def landing_html(repo_url, packages_bytes):
    # Liệt kê gói + version cho trang chủ repo (khách mở bằng trình duyệt).
    rows = ""
    for st in packages_bytes.decode("utf-8").split("\n\n"):
        d = {}
        for ln in st.splitlines():
            if ": " in ln:
                k, v = ln.split(": ", 1); d[k] = v
        if d.get("Package"):
            rows += f"<tr><td>{d.get('Name', d['Package'])}</td><td><code>{d['Package']}</code></td><td>{d.get('Version','?')}</td></tr>"
    return f"""<!doctype html><html lang="vi"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>iOSAuto — Sileo repo</title>
<style>body{{font-family:-apple-system,system-ui,sans-serif;max-width:640px;margin:40px auto;padding:0 16px;color:#111}}
code{{background:#f2f2f7;padding:1px 6px;border-radius:5px}}table{{border-collapse:collapse;width:100%;margin-top:16px}}
td,th{{border-bottom:1px solid #eee;padding:8px;text-align:left}}.btn{{display:inline-block;background:#0a84ff;color:#fff;
padding:12px 18px;border-radius:12px;text-decoration:none;font-weight:600;margin-top:12px}}</style>
<h1>iOSAuto</h1>
<p>Thêm nguồn vào <b>Sileo</b>: <code>{repo_url}</code></p>
<a class="btn" href="sileo://source/{repo_url}">Thêm vào Sileo</a>
<table><tr><th>Gói</th><th>Bundle</th><th>Version</th></tr>{rows}</table>
<p style="color:#888;margin-top:20px">iOS 15–16 rootless. Cần key kích hoạt để dùng.</p>
</html>"""


def main():
    if len(sys.argv) < 3:
        print("Dùng: python repo/make_repo.py <debs_dir> <out_dir> [repo_url]")
        return 2
    debs_dir = sys.argv[1]
    out_dir = sys.argv[2]
    repo_url = sys.argv[3] if len(sys.argv) > 3 else "https://apt.iosautos.com"

    if not os.path.isdir(debs_dir):
        print(f"Không thấy thư mục .deb: {debs_dir}"); return 1

    print("Sinh repo từ", debs_dir)
    packages = build_packages(debs_dir)
    if not packages:
        print("⚠️  Không có .deb hợp lệ."); return 1
    release, packages_gz = build_release(packages)

    # Ghi ra out_dir
    os.makedirs(os.path.join(out_dir, "debs"), exist_ok=True)
    with open(os.path.join(out_dir, "Packages"), "wb") as f:
        f.write(packages)
    with open(os.path.join(out_dir, "Packages.gz"), "wb") as f:
        f.write(packages_gz)
    with open(os.path.join(out_dir, "Release"), "wb") as f:
        f.write(release)
    with open(os.path.join(out_dir, "index.html"), "w", encoding="utf-8") as f:
        f.write(landing_html(repo_url, packages))
    # .gitattributes: giữ Packages/Release LF (hash Release phải khớp Packages khi deploy Linux)
    # + coi .deb/.gz/icon là nhị phân. Ghi LẠI mỗi lần (update_repo.py xoá sạch out_dir trước khi sinh).
    with open(os.path.join(out_dir, ".gitattributes"), "w", encoding="utf-8", newline="\n") as f:
        f.write("# Repo APT: KHÔNG đổi EOL metadata (giữ hash Release khớp Packages), .deb/.gz nhị phân.\n"
                "Packages      -text\n"
                "Release       -text\n"
                "Packages.gz   binary\n"
                "*.deb         binary\n"
                "CydiaIcon.png binary\n")
    # copy debs
    for fn in os.listdir(debs_dir):
        if fn.endswith(".deb"):
            shutil.copy2(os.path.join(debs_dir, fn), os.path.join(out_dir, "debs", fn))
    # icon nguồn (Sileo tự dùng CydiaIcon.png ở gốc repo)
    for ic in ICON_CANDIDATES:
        if os.path.isfile(ic):
            shutil.copy2(ic, os.path.join(out_dir, "CydiaIcon.png"))
            break

    print(f"\n✓ Repo sẵn ở: {out_dir}")
    print("  Files: Release, Packages, Packages.gz, index.html, CydiaIcon.png, debs/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
