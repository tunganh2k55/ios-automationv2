# PokémonTool 🔴

Tool desktop (Electron) quản lý & điều khiển reg Pokémon trên nhiều iPhone chạy daemon iOSAuto.
Giao diện chủ đề **Pokéball đỏ**. Người dùng chỉ cần mở `.exe` là dùng được.

## Tính năng

- **2 chế độ kết nối (toggle)** — chuyển mode nào thì tự quét mode đó:
  - **WiFi**: quét subnet LAN, tìm iPhone mở daemon cổng `8080`.
  - **USB**: forwarder **usbmux thuần Node** (nhúng sẵn, không cần Python/iproxy) forward cổng `8081` của từng máy về localhost qua usbmuxd của Apple, không cần WiFi (chạy cả khi bật máy bay).
- **Tab Thiết bị** — bảng liệt kê:
  - **Tên thiết bị** (đúng tên trong Cài đặt → General → About → *Name*, không phải Model).
  - **IP local**.
  - **Serial number**.
  - **Trạng thái** — máy đã *active* tool `pokemontool` chưa (hỏi `iosautos.com/api/verify/device` theo serial, không cần key).
  - **Thao tác**: `🖥 Mở view` (mở web UI daemon để chạy/điều khiển), `📜 Đọc log` (xem log reg realtime, có nút Dừng).
- **Tab Cấu hình** — sửa `config.txt` (`apikey` imapicloud, `licensekey`), lưu trên máy tính và **đẩy xuống** mọi thiết bị đang kết nối.

## Chạy thử (dev)

```bash
npm install
npm start
```

## Build ra .exe

```bash
npm run icon        # (tuỳ chọn) sinh lại icon Pokéball — cần Python + Pillow
npm run dist        # tạo installer NSIS + bản portable trong thư mục release/
```

Kết quả trong `release/`:
- `PokemonTool-1.0.0-x64.exe` — trình cài đặt (NSIS, chọn được thư mục cài).
- `PokemonTool-1.0.0-portable.exe` — bản chạy thẳng không cần cài.

## Yêu cầu phía máy dùng

- **WiFi mode**: iPhone cùng mạng LAN, daemon iOSAuto bật cổng 8080.
- **USB mode**: cắm cáp iPhone + có **usbmuxd** (Apple Mobile Device Support). usbmuxd đi kèm bất
  kỳ cái nào: **3uTools** / **iTunes** / **Apple Devices** (Microsoft Store) / iMazing. Không cần
  Python, không cần cài iproxy — forwarder usbmux đã nhúng trong app.

> Trên Windows KHÔNG thể "bật là chạy USB không cài gì": OS không có sẵn cách nói chuyện iPhone qua
> cáp, luôn cần driver usbmuxd của Apple (một trong các app trên). Không cài gì thì dùng **WiFi**.
