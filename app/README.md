# iOSAuto — iPhone automation cho jailbreak iOS 15–16

Mỗi iPhone **tự host** một web server trên chính nó. Mở `http://<ip-iphone>:8080`
từ bất kỳ thiết bị nào trong LAN để điều khiển + viết script cho chiếc máy đó.
PC không tham gia lúc chạy.

Ví dụ: iPhone có IP `192.168.1.157` → mở `http://192.168.1.157:8080`.

## Mục tiêu (theo `promt.md`)
- iPhone jailbreak **rootless Dopamine**, iOS 15–16, cài `/var/jb`.
- Chức năng: mở/đóng app, tap, vuốt (swipe), … + editor script trên web.
- Cài qua **Sileo** (add source).

## Kiến trúc

```
┌─────────────┐  HTTP :8080   ┌──────────────────────────────┐
│  Trình duyệt │ ────────────► │  iosautod (daemon native C)   │
│  (LAN)       │               │  httpd.c  → api.c             │
└─────────────┘               │  appctl.m (mở/đóng app)       │
                              │  touch.m  (tap/swipe — P4)    │
                              │  serve web/ tĩnh              │
                              └──────────────────────────────┘
```

- **`daemon/`** — daemon thật (C/ObjC), build bằng **Theos rootless** trên **GitHub Actions**.
  HTTP server tự viết (không dùng lib GPL). Route: `/api/status|launch|kill|tap|swipe|script|log`.
- **`web/`** — UI điều khiển + editor script. Dùng chung cho daemon thật và mock.
- **`control/`** — **mock server Python** (stdlib) để dev/test web + API **ngay trên Windows**.
  KHÔNG phải server thật, chỉ giả lập để làm UI.
- **`app/`** — app GUI trên iPhone (hiện IP/QR, bật/tắt daemon).
- **`.github/workflows/build.yml`** — CI build `.deb`.

## Trạng thái

| Phần | Trạng thái |
|---|---|
| Web UI + mock (Windows) | Đang dựng |
| Daemon HTTP + mở/đóng app | Đã chứng minh chạy ở bản trước (dựng lại) |
| App GUI + CI `.deb` | Dựng lại |
| **Tap/Swipe (touch)** | **CHƯA giải** — xem phần dưới |

## ⚠️ Ghi chú về Touch (phần khó, chưa giải)

Các hướng đã thử ở bản trước và kết quả:
- **Daemon đứng riêng** dispatch `IOHIDEvent`: **OS chặn** trên iOS 15–16 dù entitlement đúng.
- **Tweak tạo `IOHIDEventSystemClient` trong backboardd**: xung đột HID server →
  **backboardd crash-loop → hỏng jailbreak**. TUYỆT ĐỐI không lặp lại.
- **UIKit user-mode (kiểu KIF, MIT)**: tweak nạp được + IPC chạy, nhưng `UITouch`
  **không tới được UI** (chưa rõ selector nào fail — cần đọc syslog qua USB).

→ Touch để **Phase 4**, làm riêng, thận trọng. MVP không phụ thuộc vào nó.

## Chạy thử ngay trên Windows (mock)

```powershell
python control/mock_server.py
# mở http://127.0.0.1:8080
```

## License
Closed-source (sản phẩm cho thuê). Chỉ tái dùng mã **MIT** (KIF cho touch, tham chiếu
iolate/SimulateTouch). KHÔNG dùng AGPL/GPL (XXTouch, ZXTouch, mongoose).
