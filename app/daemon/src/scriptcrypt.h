#ifndef IOSAUTO_SCRIPTCRYPT_H
#define IOSAUTO_SCRIPTCRYPT_H
#include <stddef.h>

// Bảo vệ mã nguồn script Lua (.luax): mã hoá bí mật + ký chống sửa, khoá NHÚNG trong app.
//
// MỤC TIÊU CHÍNH: giấu mã nguồn (confidentiality). PHỤ TRỢ: product-lock (chỉ app mang
// đúng cặp key mới giải mã) + chống sửa đổi (chữ ký Ed25519 tất định).
//
// Định dạng khối nhị phân (rồi base64):
//   magic "IOSX"(4) | ver(1)=1 | nonce(12) | ct_len(4, little-endian) | ciphertext(ct_len) | sig(64)
//   - key_enc = SHA512(SEED || "iosauto-enc-v1")[0:32]
//   - nonce   = SHA512(plaintext)[0:12]            (dẫn xuất nội dung — tất định, không cần RNG)
//   - ct      = ChaCha20(key_enc, nonce, ctr=1) XOR plaintext
//   - sig     = Ed25519_sign(SEED, magic..ciphertext)
//
// CẢNH BÁO: SEED nằm trong binary phân phối → obfuscation + product-lock mạnh, KHÔNG phải
// DRM bất khả phá. Muốn "chỉ tác giả tạo được" thật sự: giữ SEED offline, ký ngoài app
// (format không đổi, chỉ cần bỏ SEED khỏi build và cấp /api/script_encrypt).

// Nhận biết nhanh một chuỗi có phải blob .luax đã mã hoá không (tiền tố base64 của magic).
// Trả 1 nếu trông giống blob mã hoá, 0 nếu không.
int scriptcrypt_looks_encrypted(const char *text, size_t len);

// Mã hoá + ký `plain` (dài `plen`) → chuỗi base64 (kết NUL) vào out_b64 (cap byte).
// Trả độ dài chuỗi (>0) nếu OK; -1 nếu lỗi (thiếu bộ nhớ / cap không đủ).
long scriptcrypt_encrypt(const char *plain, size_t plen, char *out_b64, size_t cap);

// Giải mã + VERIFY blob base64 `b64` (dài `blen`) → plaintext (kết NUL) vào out (cap byte).
// Trả độ dài plaintext (>=0) nếu hợp lệ; -1 nếu base64/format sai, chữ ký sai,
// hoặc kiểm tra toàn vẹn nonce thất bại (đã bị sửa / không phải script của app).
long scriptcrypt_decrypt(const char *b64, size_t blen, char *out, size_t cap);

#endif
