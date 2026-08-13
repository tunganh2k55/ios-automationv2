#ifndef IOSAUTO_TOUCH_H
#define IOSAUTO_TOUCH_H
#include <stddef.h>

// Toạ độ theo POINT (không phải pixel). Trả 0 nếu OK.
//
// Phase 4 — route UIKit user-mode (KIF-MIT) trong app foreground.
// Daemon là SERVER Unix socket; tweak inject vào app là CLIENT thực thi + trả diag.
//   - KHÔNG đụng backboardd (tránh crash JB).
//   - Có timeout đọc trả lời (không block daemon).

// Khởi động socket relay (gọi 1 lần lúc daemon start).
void touch_init(void);

// Kích thước màn thật (lấy từ tweak qua handshake INFO; mặc định 390x844).
void touch_screen_size(int *w, int *h);

int touch_tap(int x, int y, char *err, size_t err_len);
int touch_swipe(int x1, int y1, int x2, int y2, double duration, char *err, size_t err_len);

// Điều khiển realtime: 1 UITouch liên tục. phase 'd'=down, 'm'=move, 'u'=up. Prefer app foreground.
int touch_pointer(char phase, int x, int y, char *err, size_t err_len);

// Gửi verb thô tới tweak (vd "DUMP", "PING") — để debug.
int touch_raw(const char *line, char *err, size_t err_len);

// App Switcher (Home 2 lần) → SpringBoard (prefer_sb=1). 0=OK.
int touch_switcher(char *err, size_t err_len);

// WAKE → SpringBoard (prefer_sb=1): bật màn + mở khoá (nếu không passcode). 0=OK.
// err nhận diag: "OK wake+unlock" (đang khoá) / "OK wake (đã mở khoá)".
int touch_wake(char *err, size_t err_len);

// Gửi SHOT (không ghi log) → reply "OK shot <path>". Dùng cho vòng lặp stream MJPEG.
int touch_shot(char *reply, size_t rlen);

// AIRPLANE on/off → SpringBoard (prefer_sb=1). Bật/tắt sóng THẬT (RadiosPreferences chỉ cắt sóng
// khi chạy trong SpringBoard). Trả 0 nếu OK; diag/lỗi vào err (vd SpringBoard chưa inject tweak).
int touch_airplane(int on, char *err, size_t err_len);

// Đổi Dark Mode TOÀN MÁY (mode: 0=theo hệ thống, 1=sáng, 2=tối). Ưu tiên SpringBoard
// (giống SHOT) vì chỉ SpringBoard đổi được giao diện cả hệ thống. Trả 0 nếu OK.
int touch_appearance(int mode, char *err, size_t err_len);

// DUMP cây UIView của app foreground → reply "OK dump <path>" (đường dẫn file XML). 0=OK.
int touch_dump(char *reply, size_t rlen);

// OCR màn qua Vision → reply "OK ocr <path>" (file JSON mảng {text,x,y,w,h,cx,cy,conf}). 0=OK.
int touch_ocr(char *reply, size_t rlen, const char *lang);
// Như touch_ocr nhưng GIỚI HẠN nhận dạng trong vùng [rx,ry,rw,rh] (point màn; rw/rh<=0 = toàn màn)
// qua Vision regionOfInterest — vùng nhỏ nhanh hơn NHIỀU. Toạ độ kết quả vẫn theo point toàn màn.
int touch_ocr_region(char *reply, size_t rlen, const char *lang, int rx, int ry, int rw, int rh);

// Show a floating notification on the foreground app. duration is seconds.
int touch_toast(const char *text, double duration, char *err, size_t err_len);

// Đặt clipboard hệ thống = text (mã hoá base64 để mang được chuỗi dài/nhiều dòng/ký tự đặc biệt).
// Trả 0 nếu OK. Ưu tiên app foreground (pasteboard chung → app nào cũng ghi được).
int touch_copy(const char *text, char *err, size_t err_len);
// Lấy clipboard hệ thống → reply "OK clip <path>" (file text) để đọc nội dung. Trả 0 nếu OK.
int touch_clip(char *reply, size_t rlen);

// SPIKE VideoToolbox: quay H.264 <seconds> giây qua SpringBoard → reply "OK vtrec <path> ...". 0=OK.
int touch_vtrec(char *reply, size_t rlen, int seconds);

// Bật/tắt stream H.264 liên tục (VTSTART/VTSTOP) tới SpringBoard. Dùng cho WebSocket video. 0=OK.
int touch_video_stream(int on, char *reply, size_t rlen);

// Bật/tắt stream JPEG liên tục (SHOTSTART/SHOTSTOP) tới SpringBoard. Dùng cho MJPEG /api/stream. 0=OK.
int touch_shot_stream(int on, char *reply, size_t rlen);

// safari.fill (ẨN): điền `value` vào ô web (input/textarea/contenteditable) khớp `field` trong
// WKWebView của app foreground (Safari…). field = CSS selector HOẶC chuỗi khớp placeholder/name/
// id/type/aria-label/label (không phân biệt hoa/thường). Đặt value qua native setter + bắn
// input/change (hợp React). reply nhận diag ("OK webfill <tag>" / "ERR ..."). Trả 0 nếu OK.
int touch_safari_fill(const char *field, const char *value, char *reply, size_t rlen);

// safari.type (ẨN): GÕ `value` vào ô web khớp `field` MÔ PHỎNG NGƯỜI GÕ — từng ký tự bắn đủ chuỗi
// event keydown/keypress/beforeinput/input(InputEvent insertText+data)/keyup + set value tăng dần qua
// native setter, thay vì đặt cả chuỗi 1 phát như safari.fill → khó bị anti-bot phát hiện hơn. field
// khớp giống safari.fill. reply nhận diag ("OK webtype <tag>" / "ERR ..."). Trả 0 nếu OK.
int touch_safari_type(const char *field, const char *value, char *reply, size_t rlen);

// safari.swipe (ẨN): cuộn WKWebView của app foreground tới element web khớp `field` (đưa ra giữa
// màn qua scrollIntoView). field khớp giống safari.fill + cả text hiển thị/button/link. reply nhận
// diag ("OK webswipe ok <cx>,<cy>" — tâm element sau khi cuộn / "ERR ..."). Trả 0 nếu OK.
int touch_safari_swipe(const char *field, char *reply, size_t rlen);

// safari.click (ẨN): bấm element web khớp `field` (cuộn tới rồi bắn pointer/mouse + el.click()) trong
// WKWebView app foreground. field khớp giống safari.swipe. reply nhận diag ("OK webclick ok <cx>,<cy>"
// — tâm element đã bấm / "ERR ..."). Trả 0 nếu OK.
int touch_safari_click(const char *field, char *reply, size_t rlen);

// safari.checkbox (ẨN): TICK checkbox/radio web khớp `field` CHO CHẮC. Tweak tự lần ra <input> thật
// (dù field trỏ vào label), tap vào label hiển thị nếu input bị ẩn/quá nhỏ, rồi VERIFY .checked và
// .click() JS bù nếu HID tap trượt. Đã tick sẵn thì bỏ qua. reply nhận diag ("OK webcheck ..." /
// "ERR ..."). Trả 0 nếu ô đã được tick.
int touch_safari_checkbox(const char *field, char *reply, size_t rlen);

// safari.load (ẨN): chờ trang web app foreground load XONG (document.readyState == 'complete').
// Lặp hỏi readyState tới khi 'complete' hoặc hết `timeout_sec` giây (mặc định 60, trần 600). reply
// nhận diag ("OK loaded ..." / "TIMEOUT ..." / "...no-webview..."). Trả 0 nếu trang đã load xong.
int touch_safari_load(int timeout_sec, char *reply, size_t rlen);

// safari.eval (ẨN): chạy JS TUỲ Ý (`js` phải `return` giá trị) trong WKWebView app foreground; tweak
// GHI kết quả ra file (kết quả lớn: outerHTML/JSON) → reply "OK webeval <path>" (daemon đọc file) /
// "ERR ...". Dùng để SOI DOM (viết selector chuẩn). Trả 0 nếu OK.
int touch_safari_eval(const char *js, char *reply, size_t rlen);

#endif
