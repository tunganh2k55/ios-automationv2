# Cài iOSAuto lên iPhone

## Lấy file .deb (từ CI)
```powershell
gh run download --repo tunganh2k55/ios-automation -n iosauto-debs -D repo/debs
```
(hoặc tải artifact `iosauto-debs` từ tab Actions trên GitHub, giải nén vào `repo/debs/`)

## Cách 1 — Sileo source (khuyến nghị, "TesT" trong promt.md)
```powershell
python repo/serve_repo.py        # cổng 8090
```
Script in ra URL kiểu `http://192.168.1.50:8090`.
Trên iPhone: **Sileo → Sources → + → dán URL đó** → cài **iOSAuto** (kéo theo daemon).

> PC và iPhone phải cùng mạng LAN. Nếu Windows Firewall chặn, cho phép Python nghe cổng 8090.

## Cách 2 — Cài tay qua SSH
```
scp repo/debs/*.deb mobile@<ip-iphone>:/var/mobile/
ssh mobile@<ip-iphone> "sudo /var/jb/usr/bin/dpkg -i /var/mobile/com.iosauto.*.deb"
```

## Sau khi cài
- daemon tự chạy (launchd), phục vụ web tại `http://<ip-iphone>:8080`.
- Mở app **iOSAuto** trên máy, hoặc mở `http://<ip-iphone>:8080` từ trình duyệt máy khác.
- Mở/đóng app: hoạt động. Tap/swipe: **Phase 4** (chưa dispatch — xem README gốc).

---

# Public repo cho khách (domain + Sileo add source)

## 1 gói gộp `com.iosauto` (khách cài 1 lần)
CI build 3 gói con (daemon/tweak/app) rồi `merge_deb.py` **gộp thành 1 gói `com.iosauto`**
(chứa hết daemon + tweak + app). Khách chỉ thấy & cài **iOSAuto**.
- `Conflicts/Replaces/Provides` 3 gói con → ai đang cài bản 3-gói cũ, khi cài `com.iosauto`
  Sileo tự gỡ 3 gói cũ và thay bằng gói gộp.
- `postinst`: bootstrap daemon (launchd) + `uicache` (hiện icon app). Tweak cần **respring**
  (Sileo tự hỏi respring vì Section=Tweaks).
- Metadata & version của gói gộp nằm ở **`app/dist/control`** (nguồn duy nhất để bump).

> ⚠️ Gói build **rootless** (`THEOS_PACKAGE_SCHEME=rootless`) → chỉ JB rootless (Dopamine,
> palera1n-rootless, XinaA15). Khách rootful (iOS 15 unc0ver/checkra1n) cần bản rootful riêng.

## Cách A (đang dùng) — license server phục vụ `iosautos.com/repo`
Repo tĩnh nằm sẵn trong **`web-license/repo/`** (đã commit, gồm cả `.deb`). `server.js` có route
`/repo` phục vụ thư mục đó → khi deploy license server, khách add source **`https://iosautos.com/repo`**.

**Ra bản mới (quy trình mỗi lần sửa):**
```powershell
# 1) sửa code + BUMP Version trong control gói đã đổi (web/ đổi = bump daemon)
# 2) git push  → đợi CI build xong (Actions)
# 3) tải build mới + sinh lại repo vào web-license/repo:
python app/repo/update_repo.py
# 4) commit repo + deploy license server:
git add web-license/repo && git commit -m "repo: 0.x.y" && git push
```
Deploy lại `web-license` (git pull trên VPS + `npm start`/pm2 restart) → Sileo hiện **Cập nhật**.

> `.deb` trong `web-license/repo/debs/` được commit (đã thêm ngoại lệ `.gitignore`). Kích thước
> nhỏ (~400KB/bản); nếu lo phình lịch sử về sau có thể chuyển sang Cách B (rsync, không commit binary).

## Cách B (tuỳ chọn) — CI tự rsync lên thư mục riêng trên VPS
CI (`.github/workflows/build.yml`) sau khi build sẽ:
1. `make_repo.py` sinh repo tĩnh (`out/repo/`: `Release`, `Packages`, `Packages.gz`, `debs/`,
   `CydiaIcon.png`, `index.html`) từ **cả 3 control**.
2. Upload artifact `iosauto-repo` (tải tay được).
3. `rsync` lên VPS **nếu** đã đặt secrets.

### Secrets cần thêm (Settings → Secrets and variables → Actions)
| Secret | Ví dụ | Ý nghĩa |
|--------|-------|---------|
| `APT_HOST` | `iosautos.com` | host SSH của VPS |
| `APT_USER` | `deploy` | user SSH |
| `APT_PATH` | `/var/www/apt` | **thư mục RIÊNG** cho repo (đừng trỏ vào webroot chung) |
| `APT_SSH_KEY` | *(private key)* | khoá SSH deploy (thêm public key vào `~/.ssh/authorized_keys` trên VPS) |
| `APT_PORT` | `22` | (tuỳ chọn) cổng SSH |
| `APT_URL` | `https://apt.iosautos.com` | (tuỳ chọn) URL công khai cho trang `index.html` |

Không đặt secrets → CI vẫn chạy, chỉ **bỏ qua bước đẩy** (lấy repo từ artifact `iosauto-repo`).

### Cấu hình web server trên VPS (phục vụ `APT_PATH` qua HTTPS)
Trỏ subdomain `apt.iosautos.com` → thư mục repo. Ví dụ **nginx**:
```nginx
server {
    listen 443 ssl;
    server_name apt.iosautos.com;
    root /var/www/apt;            # = APT_PATH
    autoindex off;
    location / { try_files $uri $uri/ =404; }
    # (cấu hình ssl_certificate… bằng certbot)
}
```
> **HTTPS bắt buộc** — Sileo cảnh báo/chặn source HTTP.

Khách: **Sileo → Sources → + → `https://apt.iosautos.com`**.

## Quản lý version (để khách nhận "Cập nhật")
Sileo so field **`Version`** trong `Packages`. Cao hơn bản đã cài → hiện update. Quy tắc:
- **Mỗi lần release, bump `Version` trong `app/dist/control`** (gói gộp — nguồn version DUY NHẤT).
  Không cần đụng version 3 control con (chúng chỉ để build gói con rồi bị gộp).
- Dùng semver: sửa lỗi → `x.y.Z+1`; thêm hàm → `x.Y+1.0`.
- **Không tái dùng** số version cũ (dpkg sẽ không cài đè).
- Push → CI rebuild + gộp + regenerate `Packages` → `update_repo.py` → commit → deploy.

## Chạy tay (không dùng CI)
```powershell
python repo/make_repo.py repo/debs out/repo https://apt.iosautos.com
# rồi tự rsync/scp out/repo/ lên VPS:/var/www/apt
```
