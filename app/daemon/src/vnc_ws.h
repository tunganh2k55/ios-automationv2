#ifndef IOSAUTO_VNC_WS_H
#define IOSAUTO_VNC_WS_H

// WebSocket-to-VNC proxy cho noVNC.
// noVNC (browser) kết nối WebSocket tới daemon → proxy tới VNC server (TCP 5900).
//
// Flow:
//   Browser --WebSocket--> /vnc (httpd) --TCP--> localhost:5900 (VNC server)
//
// WebSocket frame:
//   0x82 = binary frame (VNC dùng binary)
//   0x88 = close
//   0x89 = ping, 0x8A = pong

// Xử lý WebSocket upgrade request từ httpd.
// headers: raw HTTP headers sau request line.
// Trả 1 nếu upgrade thành công (thread proxy đã chạy), 0 nếu không phải WS request, -1 nếu lỗi.
int vnc_ws_handle_upgrade(int client_fd, const char *headers);

// Kiểm tra xem path có phải /vnc không.
int vnc_ws_is_vnc_path(const char *path);

#endif
