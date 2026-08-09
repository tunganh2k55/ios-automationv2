#ifndef IOSAUTO_GRANT_H
#define IOSAUTO_GRANT_H
#include <stddef.h>

// Xác minh "grant" bản quyền do server ký Ed25519 (Nhóm 1).
// Public key + keyId NHÚNG compile-time trong grant.m. Daemon CHỈ tin dữ liệu SAU khi verify
// chữ ký trên đúng byte payload — verify xong mới parse JSON (không parse-rồi-hành-động).

typedef struct {
    long iat;          // issued-at (epoch giây) — dùng làm mốc "lần cuối hợp lệ" (đã ký, không giả được)
    long exp;          // hết hạn grant (epoch) — TTL ngắn
    long gen;          // generation (thông tin; hiệu lực thật ở server)
    long lexp;         // hạn THẬT của license (epoch); -1 = vĩnh viễn
    char plan[40];     // tên gói (hiển thị)
    char dev[64];      // machineId gắn trong grant
} grant_info;

// Self-test Ed25519 bằng vector cố định (server BoringSSL sinh, đã kiểm host). 1=pass, 0=fail.
// Fail => daemon phải fail-CLOSED (coi như không có bản quyền).
int grant_selftest(void);

// Verify grant. payload_b64/sig_b64/keyId: từ response server (hoặc cache).
//   machineId: serial máy hiện tại — grant.dev PHẢI khớp (chống copy file sang máy khác).
//   nonce: nếu != NULL, kiểm nh == base64(sha256(nonce)) (challenge-response cho grant TƯƠI).
//          Truyền NULL khi verify grant từ cache lúc khởi động (không còn nonce gốc).
// Trả 1 nếu chữ ký + toàn bộ field hợp lệ; 0 nếu bất kỳ kiểm tra nào hỏng. out điền khi trả 1.
int grant_verify(const char *payload_b64, const char *sig_b64, const char *keyId,
                 const char *machineId, const char *nonce, grant_info *out);

#endif
