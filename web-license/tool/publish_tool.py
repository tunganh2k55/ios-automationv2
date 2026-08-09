# -*- coding: utf-8 -*-
"""Phát hành 1 bản build tool desktop lên kho /tool/<slug>/ (cho auto-update + tải tay).

Việc script làm:
  1) Copy file .exe (portable) vào web-license/tool/<slug>/ (đặt tên có version).
  2) Tính sha256 + size, ghi <slug>/latest.json (manifest client đọc để tự cập nhật).
  3) Dọn các .exe cũ, chỉ giữ --keep bản mới nhất (tránh phình repo).
  4) Cập nhật tool/index.json (danh mục mọi tool — để mở rộng nhiều tool nhỏ).

Dùng:
  python tool/publish_tool.py \
      --slug pokemontool --name PokemonTool \
      --exe ../BuildToolElectron/Pokemon/release/PokemonTool-1.0.5-portable.exe \
      --version 1.0.5 --notes "Tăng tốc USB, bỏ nút tải script" [--mandatory] [--keep 3]

Nếu bỏ --version: tự trích từ tên file (…-<version>-portable.exe).
Sau khi chạy: commit web-license/tool/ rồi deploy (giống cách deploy /repo).
"""
import argparse, hashlib, json, os, re, shutil, sys, urllib.request, urllib.error

# Console Windows mặc định cp1252 → in tiếng Việt/em-dash sẽ UnicodeEncodeError. Ép stdout UTF-8.
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))          # web-license/tool
VER_RE = re.compile(r"-(\d+\.\d+\.\d+(?:[-.][0-9A-Za-z]+)*)-portable\.exe$", re.I)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def infer_version(exe_name):
    m = VER_RE.search(exe_name)
    return m.group(1) if m else None


def prune_old(slug_dir, keep, keep_name):
    exes = [f for f in os.listdir(slug_dir) if f.lower().endswith(".exe")]
    # Sắp theo mtime giảm dần; luôn giữ file vừa phát hành + (keep-1) file mới kế.
    exes.sort(key=lambda f: os.path.getmtime(os.path.join(slug_dir, f)), reverse=True)
    keep_set = {keep_name}
    for f in exes:
        if len(keep_set) >= keep:
            break
        keep_set.add(f)
    removed = []
    for f in exes:
        if f not in keep_set:
            os.remove(os.path.join(slug_dir, f))
            removed.append(f)
    return removed


def update_index(slug, name, version):
    idx_path = os.path.join(HERE, "index.json")
    try:
        idx = json.load(open(idx_path, "r", encoding="utf-8"))
    except Exception:
        idx = {"tools": []}
    tools = idx.get("tools", [])
    entry = next((t for t in tools if t.get("slug") == slug), None)
    if not entry:
        entry = {"slug": slug}
        tools.append(entry)
    entry["name"] = name
    entry["version"] = version
    entry["manifest"] = f"/tool/{slug}/latest.json"
    idx["tools"] = sorted(tools, key=lambda t: t.get("slug", ""))
    with open(idx_path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(idx, f, ensure_ascii=False, indent=2)
        f.write("\n")


def purge_cloudflare(urls, zone=None, token=None):
    """Purge cache Cloudflare cho đúng các URL vừa publish (bất biến nhưng URL có thể bị đè bytes
    khác → CDN kẹt bản cũ; xem sự cố 1.0.8). Best-effort: thiếu zone/token thì bỏ qua, KHÔNG chặn
    phát hành. Zone id + API token lấy từ tham số hoặc env CF_ZONE_ID / CF_API_TOKEN."""
    zone = zone or os.environ.get("CF_ZONE_ID")
    token = token or os.environ.get("CF_API_TOKEN")
    if not zone or not token:
        print("[CF] bỏ qua purge (chưa có CF_ZONE_ID/CF_API_TOKEN) — NHỚ purge tay các URL trên.")
        return False
    body = json.dumps({"files": urls}).encode("utf-8")
    req = urllib.request.Request(
        f"https://api.cloudflare.com/client/v4/zones/{zone}/purge_cache",
        data=body, method="POST",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            ok = json.load(r).get("success")
        print(f"[CF] purge {'OK' if ok else 'THẤT BẠI'}: {len(urls)} URL")
        return bool(ok)
    except urllib.error.HTTPError as e:
        print(f"[CF] purge lỗi HTTP {e.code}: {e.read().decode('utf-8', 'ignore')[:200]}")
    except Exception as e:
        print(f"[CF] purge lỗi: {e}")
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--slug", required=True, help="định danh tool, vd: pokemontool")
    ap.add_argument("--exe", required=True, help="đường dẫn file *-portable.exe")
    ap.add_argument("--name", default=None, help="tên hiển thị (mặc định = slug)")
    ap.add_argument("--version", default=None, help="version; bỏ trống = trích từ tên file")
    ap.add_argument("--notes", default="", help="ghi chú thay đổi (hiện cho người dùng)")
    ap.add_argument("--mandatory", action="store_true", help="ép buộc cập nhật (client chặn dùng bản cũ)")
    ap.add_argument("--base-url", default="https://iosautos.com", help="gốc URL công khai")
    ap.add_argument("--released-at", default=None, help="ISO8601; bỏ trống = tự lấy giờ hiện tại (UTC)")
    ap.add_argument("--keep", type=int, default=3, help="số bản .exe giữ lại (dọn bản cũ)")
    ap.add_argument("--cf-zone", default=None, help="Cloudflare Zone ID (mặc định env CF_ZONE_ID)")
    ap.add_argument("--cf-token", default=None, help="Cloudflare API token (mặc định env CF_API_TOKEN)")
    ap.add_argument("--no-purge", action="store_true", help="bỏ qua purge Cloudflare")
    args = ap.parse_args()

    exe = os.path.abspath(args.exe)
    if not os.path.isfile(exe):
        sys.exit(f"[LỖI] Không thấy file exe: {exe}")

    version = args.version or infer_version(os.path.basename(exe))
    if not version:
        sys.exit("[LỖI] Không xác định được version (đặt --version hoặc dùng tên …-<ver>-portable.exe)")
    name = args.name or args.slug

    slug_dir = os.path.join(HERE, args.slug)
    os.makedirs(slug_dir, exist_ok=True)

    # 1) Copy exe vào kho (chuẩn hoá tên có version cho bất biến/cache dài).
    dst_name = f"{name}-{version}-portable.exe"
    dst = os.path.join(slug_dir, dst_name)
    if os.path.abspath(exe) != os.path.abspath(dst):
        shutil.copy2(exe, dst)

    # 2) Tính sha256 + size → latest.json
    size = os.path.getsize(dst)
    digest = sha256_file(dst)
    # released_at: KHÔNG tự lấy giờ máy tuỳ tiện — theo quy ước dự án, truyền vào hoặc để trống.
    released_at = args.released_at
    manifest = {
        "slug": args.slug,
        "name": name,
        "version": version,
        "mandatory": bool(args.mandatory),
        "notes": args.notes,
        "portable": {
            "file": dst_name,
            "url": f"{args.base_url}/tool/{args.slug}/{dst_name}",
            "download": f"{args.base_url}/tool/{args.slug}/download",
            "size": size,
            "sha256": digest,
        },
    }
    if released_at:
        manifest["releasedAt"] = released_at
    with open(os.path.join(slug_dir, "latest.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
        f.write("\n")

    # 3) Dọn exe cũ
    removed = prune_old(slug_dir, max(1, args.keep), dst_name)

    # 4) Registry mọi tool
    update_index(args.slug, name, version)

    print(f"[OK] {args.slug} v{version} -> tool/{args.slug}/{dst_name}")
    print(f"     size={size:,}B sha256={digest[:16]}")
    print(f"     manifest: {args.base_url}/tool/{args.slug}/latest.json")
    print(f"     download: {args.base_url}/tool/{args.slug}/download")
    if removed:
        print(f"     pruned {len(removed)} old: {', '.join(removed)}")

    # 5) Purge Cloudflare cho các URL vừa đổi nội dung (exe + manifest + link download)
    if not args.no_purge:
        purge_cloudflare([
            manifest["portable"]["url"],
            manifest["portable"]["download"],
            f"{args.base_url}/tool/{args.slug}/latest.json",
        ], zone=args.cf_zone, token=args.cf_token)


if __name__ == "__main__":
    main()
