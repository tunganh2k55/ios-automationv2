# /tool — Kho tải & auto-update cho tool desktop

Phục vụ tĩnh tại `https://iosautos.com/tool/`. Mỗi tool một thư mục con `/tool/<slug>/`,
mở rộng được cho nhiều tool nhỏ (pokemontool, và các tool sau).

## Cấu trúc

```
tool/
  index.json                  # danh mục mọi tool (slug, name, version, manifest)
  publish_tool.py             # script phát hành 1 bản build
  <slug>/
    latest.json               # manifest cập nhật — client đọc để tự cập nhật
    index.html + download.js   # trang tải cho người dùng
    <Name>-<ver>-portable.exe  # binary (KHÔNG commit git — xem .gitignore)
```

## Endpoint

| URL | Ý nghĩa |
|---|---|
| `GET /tool/<slug>/latest.json` | Manifest (no-cache) — client auto-update đọc cái này |
| `GET /tool/<slug>/download` | 302 sang exe hiện hành — **link tải ổn định**, không đổi theo version |
| `GET /tool/<slug>/<file>.exe` | Binary (cache 1 năm, bất biến vì tên có version) |
| `GET /tool/<slug>/` | Trang tải cho người dùng |
| `GET /tool/index.json` | Danh mục mọi tool |

## Hợp đồng `latest.json` (client dựa vào)

```json
{
  "slug": "pokemontool",
  "name": "PokemonTool",
  "version": "1.0.4",              // so sánh semver với version đang chạy
  "mandatory": false,             // true = ép cập nhật (client chặn bản cũ)
  "notes": "…",                   // hiện cho người dùng
  "releasedAt": "2026-08-04T16:58:00+07:00",
  "portable": {
    "file": "PokemonTool-1.0.4-portable.exe",
    "url":  "https://iosautos.com/tool/pokemontool/PokemonTool-1.0.4-portable.exe",
    "download": "https://iosautos.com/tool/pokemontool/download",
    "size": 81639416,
    "sha256": "330bb82…"          // client tải xong PHẢI verify sha256 trước khi thay
  }
}
```

Client (Electron, bản portable) auto-update:
1. `fetch latest.json` → so `version` với bản đang chạy.
2. Nếu mới hơn: tải `portable.url`, verify `sha256`.
3. Nhắc người dùng → thay file exe khi thoát (portable không tự ghi đè lúc đang chạy).

## Phát hành bản mới

```bash
python tool/publish_tool.py \
  --slug pokemontool --name PokemonTool \
  --exe ../BuildToolElectron/Pokemon/release/PokemonTool-1.0.5-portable.exe \
  --version 1.0.5 --notes "…" [--mandatory] [--keep 3]
```

Script: copy exe vào `tool/<slug>/`, tính sha256 + size, ghi `latest.json`, dọn bản cũ (giữ `--keep`),
cập nhật `index.json`.

## Deploy binary

`*.exe` **không commit git** (mỗi bản ~80MB → phình repo). Sau khi chạy publish:
- Commit `latest.json` + `index.json` (nhỏ) như bình thường.
- Upload file `.exe` lên server (scp/panel) vào đúng `tool/<slug>/`.
- (Nếu vẫn muốn commit exe: `git add -f tool/<slug>/<file>.exe`.)
