#ifndef IOSAUTO_VNC_H
#define IOSAUTO_VNC_H
#include <stddef.h>

// VNC server tích hợp trực tiếp vào daemon, dùng libvncserver.
// Port: 5900 (RFB protocol). WebSocket proxy tại /vnc (cho noVNC).
//
// Luồng framebuffer:
//   CARenderServerRenderDisplay → IOSurface → fbcap (JPEG cho stream) + rfbScreen (raw BGRA cho VNC)
// Luồng input: VNC pointer/key events → map sang touch.h (touch_pointer, touch_tap) + HID key.

// Khởi động VNC server (gọi 1 lần sau daemon start).
// port: cổng RFB (mặc định 5900), password: NULL = không mật khẩu.
// Trả 0 nếu OK.
int vnc_init(int port, const char *password);

// Dừng VNC server.
void vnc_stop(void);

// Đang chạy?
int vnc_running(void);

// Cập nhật framebuffer từ IOSurface (gọi từ capture loop).
// data: con trỏ BGRA buffer, w/h: kích thước pixel, bpr: bytes per row.
// Trả 0 nếu OK.
int vnc_update_fb(const void *data, int w, int h, size_t bpr);

// Đánh dấu toàn màn đã thay đổi (sau mỗi capture).
void vnc_mark_modified(void);

// Số client đang kết nối.
int vnc_client_count(void);

// WebSocket proxy: xử lý request từ httpd.
// Trả 1 nếu đây là request WebSocket VNC, 0 nếu không.
int vnc_websocket_upgrade(int client_fd, const char *headers);

#endif
