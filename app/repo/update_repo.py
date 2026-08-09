#!/usr/bin/env python3
"""
Cập nhật repo phục vụ tại iosautos.com/repo:
  1) tải .deb bản build MỚI NHẤT (artifact 'iosauto-debs') từ CI (GitHub Actions),
  2) sinh lại web-license/repo/ (Release/Packages/debs…) bằng make_repo.py.

    python app/repo/update_repo.py

Sau đó: git add web-license/repo && git commit && push → deploy web-license → khách Sileo thấy update.
YÊU CẦU: `gh` đã đăng nhập (gh auth login) và build gần nhất đã xong (Version đã bump trong control).
"""
import os
import subprocess
import sys
import tempfile

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

APP_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))          # app/
ROOT = os.path.dirname(APP_DIR)                                                 # repo gốc
OUT = os.path.join(ROOT, "web-license", "repo")
REPO_URL = "https://iosautos.com/repo"


def sh(cmd, **kw):
    print("  $", " ".join(cmd))
    return subprocess.run(cmd, check=True, **kw)


def main():
    # 1) run thành công gần nhất của workflow build.yml
    r = subprocess.run(
        ["gh", "run", "list", "--workflow", "build.yml", "--status", "success",
         "--limit", "1", "--json", "databaseId", "-q", ".[0].databaseId"],
        capture_output=True, text=True)
    run_id = r.stdout.strip()
    if not run_id:
        print("Không tìm thấy build thành công. Push code + đợi CI xong trước.")
        return 1
    print("Build mới nhất:", run_id)

    with tempfile.TemporaryDirectory() as tmp:
        # Tải gói ĐÃ GỘP (com.iosauto). make_repo đọc app/dist/control → Packages.
        sh(["gh", "run", "download", run_id, "-n", "iosauto-merged", "--dir", tmp])
        # 2) sinh lại repo
        if os.path.isdir(OUT):
            import shutil
            shutil.rmtree(OUT)
        sh([sys.executable, os.path.join(APP_DIR, "repo", "make_repo.py"), tmp, OUT, REPO_URL])

    print(f"\n✓ Đã cập nhật {OUT}")
    print("  Tiếp theo: git add web-license/repo && git commit -m 'repo: <version>' && git push")
    return 0


if __name__ == "__main__":
    sys.exit(main())
