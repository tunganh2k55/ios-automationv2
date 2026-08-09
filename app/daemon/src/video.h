#ifndef IOSAUTO_VIDEO_H
#define IOSAUTO_VIDEO_H
#include <stdint.h>
#include <stddef.h>

// Pipeline video H.264 low-latency cho IOScontrol.
//   Tweak (SpringBoard) encode → push framed H.264 tới daemon:8398 (ingest)
//   Daemon fan-out cho các WebSocket client (/ws/video) → browser WebCodecs.

// Khởi động ingest listener (127.0.0.1:8398) + state. Gọi 1 lần lúc daemon start.
void video_init(void);

// 1 nếu path là endpoint WebSocket video.
int video_is_ws_path(const char *path);

// Nâng cấp kết nối HTTP thành WebSocket rồi phục vụ 1 client video (BLOCK tới khi client rớt).
// req = toàn bộ text request (để lấy Sec-WebSocket-Key). Không đóng fd (caller đóng).
void video_handle_ws(int fd, const char *req);

// WebSocket điều khiển realtime (/ws/control): nhận "phase x y" → touch liên tục. BLOCK.
int video_is_control_path(const char *path);
void control_handle_ws(int fd, const char *req);

// MJPEG tách kênh: copy khung JPEG mới nhất (nếu version khác *ver). Trả độ dài, 0 nếu trùng/chưa có.
int video_copy_jpeg(uint8_t *dst, size_t cap, uint32_t *ver);
void video_shotstream_join(void);   // client /api/stream vào → bật SHOTSTART (refcount)
void video_shotstream_leave(void);  // client ra → tắt SHOTSTOP khi hết

#endif
