#ifndef IOSAUTO_FBCAP_H
#define IOSAUTO_FBCAP_H
#include <stddef.h>

// Chụp FRAMEBUFFER THẬT (IOMobileFramebuffer + IOSurfaceAccelerator, như TrollVNC) → JPEG.
// Đọc output vật lý đang scan-out → KHÔNG đen khi SpringBoard chuyển trang. Chạy trong daemon
// (cần entitlement iokit-user-client-class + IOSurface.protected-access — xem entitlements.plist).
// *outbuf = malloc buffer (caller free). scale 0<..<=1 (thu nhỏ), quality 1..100. Trả 0 nếu OK.
// IN-PROCESS: dùng cho streaming/screenshot (nhanh, surfaces tĩnh).
int fbcap_jpeg(unsigned char **outbuf, size_t *outlen, double scale, int quality);

// BIỆT LẬP: spawn tiến trình con (iosautod --capture) để chụp. Con bị hệ đồ hoạ kill cứng thì
// DAEMON VẪN SỐNG (chỉ trả !=0 = thất bại, caller thử lại). Dùng cho khớp ảnh tự động (imgmatch).
int fbcap_jpeg_isolated(unsigned char **outbuf, size_t *outlen, double scale, int quality);

// Chụp 1 frame ra FILE — hàm chạy TRONG tiến trình con. pw,ph = kích thước điểm màn. Trả 0 nếu OK.
int fbcap_capture_to_file(const char *path, double scale, int quality, int pw, int ph);

// ===== CỔNG CAPTURE TOÀN CỤC (giới hạn nhịp render-server, tránh bị kill) =====
// Gọi TRƯỚC mỗi lần chụp THẬT: nếu automation đang chạy, chờ tới khi đủ min-interval kể từ lần
// chụp thật gần nhất (áp dụng chung cho mọi đường capture: matching lẫn streaming/screenshot).
void fbcap_gate_enter(void);
// Đặt min-interval (giây) giữa 2 lần chụp thật + TTL (giây) frame còn "mới" để tái dùng.
// Giá trị <0 = giữ nguyên. Mặc định: min 1.2s, ttl 1.0s.
void fbcap_set_capture_interval(double min_sec, double ttl_sec);
// TTL (ms) hiện tại — imgmatch dùng để quyết định tái dùng frame cache.
long fbcap_frame_ttl_ms(void);

// ===== RAW FRAMEBUFFER (cho VNC) =====
// Chụp framebuffer thật → raw BGRA (không encode JPEG). Dùng cho VNC server.
// *outbuf = malloc buffer (caller free), *w/*h = pixel size, *bpr = bytes per row.
// Trả 0 nếu OK.
int fbcap_raw(unsigned char **outbuf, size_t *outlen, int *w, int *h, size_t *bpr);

#endif
