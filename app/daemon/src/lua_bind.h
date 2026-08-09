#ifndef IOSAUTO_LUA_BIND_H
#define IOSAUTO_LUA_BIND_H
#include <stddef.h>

// Bắt đầu chạy script Lua ở LUỒNG NỀN (1 script/lần). Trả runid (>0) nếu bắt đầu; 0 nếu đang bận.
int lua_run_start(const char *code);
// Yêu cầu dừng script đang chạy (cờ hợp tác: hook Lua + sleep chia nhỏ + vòng lặp tapText/tapImage).
void lua_run_stop(void);
// Ảnh chụp trạng thái + output. Tham số ra có thể NULL. Nếu out!=NULL copy output kể từ `offset`
// (để theo dõi/đọc log tăng dần). Trả TỔNG độ dài output hiện có (đọc offset lần sau).
size_t lua_run_snapshot(int *busy, int *runid, long *elapsed, int *done,
                        char *out, size_t cap, size_t offset);

// Có đang chạy script (automation) không? Dùng để cổng capture chỉ giới hạn nhịp khi cần.
int lua_run_is_busy(void);

#endif
