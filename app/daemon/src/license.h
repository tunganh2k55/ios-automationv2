#ifndef IOSAUTO_LICENSE_H
#define IOSAUTO_LICENSE_H
#include <stddef.h>

// Quản lý bản quyền THIẾT BỊ (nguồn sự thật duy nhất cho app / web UI / script).
// Lưu license.json ở /var/jb/usr/local/iosauto/. machineId = UUID daemon tự sinh (ổn định).
// Verify online tới server (mặc định https://iosautos.com) qua POST /api/verify/app;
// kích hoạt qua POST /api/activate/device. Có cache + ân hạn offline + thread refresh nền.

void license_init(void);

// machineId (serial) đã chuẩn hoá [A-Z0-9] — dùng đăng ký & verify.
void license_machine_id(char *out, size_t len);

// Ghi JSON trạng thái vào out (không malloc). Trả độ dài.
// {"ok":true,"activated":bool,"reason":"...","machineId":"..","server":"..",
//  "app":{"valid":bool,"plan":..,"expiresAt":..},"hasKey":bool}
size_t license_status_json(char *out, size_t cap);

// Bậc quyền theo grant + độ cũ offline (Nhóm 1).
//   LOCKED   : không có quyền trả phí (chưa kích hoạt / hết hạn / offline >24h / grant hỏng).
//   VIEW     : offline 6–24h — chỉ xem trạng thái.
//   CONTINUE : offline 30'–6h — task đang chạy tiếp tục, KHÔNG tạo task mới.
//   FULL     : online (hoặc offline <30') — đầy đủ.
enum { LIC_LOCKED = 0, LIC_VIEW = 1, LIC_CONTINUE = 2, LIC_FULL = 3 };

// App đã kích hoạt hợp lệ? (tier > LOCKED). Dùng để gate — rẻ, thread-safe.
int license_app_active(void);

// Bậc quyền hiện tại (LIC_*). Rẻ, thread-safe (đọc không khoá).
int license_tier(void);

// Kích hoạt bằng key (lưu làm appKey, activate/device + verify). msg = thông báo tiếng Việt.
// Trả 1 nếu sau đó app hợp lệ.
int license_activate(const char *key, char *msg, size_t msg_len);

// Đổi URL server (lưu file). Trả 1 nếu hợp lệ.
int license_set_server(const char *url);

// Xoá license đã lưu (appKey + cache) — về trạng thái chưa kích hoạt.
void license_clear(void);

#endif
