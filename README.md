# ios-automation

Monorepo gồm 2 phần:

| Thư mục | Nội dung | Stack |
|---|---|---|
| [`app/`](app/) | Tự động hoá iPhone jailbreak (iOS 15–16): **daemon** (HTTP :8080 + relay TCP :8399), **tweak** (`com.iosauto.touch`, inject UIKit, TAP/SWIPE/TYPE/SHOT/DUMP/OCR…), **app** GUI, và **web control panel** (`app/web/`). | C / Objective-C (Theos rootless), Lua, JS |
| [`web-license/`](web-license/) | Website bán & verify license (đăng ký/đăng nhập, admin, cấp/kiểm license). | Node/Express + TypeScript, Supabase |

## app/ — build & cài

Build `.deb` chạy trên **GitHub Actions** (macOS runner + Theos rootless) — xem [`.github/workflows/build.yml`](.github/workflows/build.yml). Không build được trên Windows.

- Push lên `main` (đổi trong `app/**`) hoặc chạy `workflow_dispatch` → CI build 3 gói: `com.iosauto.daemon`, `com.iosauto.app`, `com.iosauto.touch`.
- Lấy `.deb`: tải artifact `iosauto-debs`, hoặc `git fetch` nhánh `ci-builds`.
- Cài lên thiết bị jailbreak (rootless `/var/jb`) qua SSH: `dpkg -i *.deb` rồi respring.

Chức năng nổi bật của tweak: điều khiển chạm an toàn (không đụng backboardd), **dump XML** cây view (page source), **OCR** màn hình qua Vision (trả toạ độ để tap theo chữ), đổi Dark Mode toàn máy.

## web-license/ — chạy website

```bash
cd web-license
npm install
cp .env.example .env   # điền SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, SESSION_SECRET
npm run build          # biên dịch TypeScript (src/ -> public/)
npm start
```

Chi tiết cấu hình & bảo mật: xem [`web-license/README.md`](web-license/README.md).

> Không commit `.env`, `node_modules/`, `*.deb` (đã có trong `.gitignore`).
