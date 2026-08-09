#ifndef IOSAUTO_ED25519_H
#define IOSAUTO_ED25519_H
#include <stddef.h>

// Ed25519 VERIFY-ONLY, tự chứa (không cần thư viện ngoài) — iOS SDK không có API Ed25519
// công khai nên phải vendor. Thuật toán theo TweetNaCl (public domain, D. J. Bernstein et al.),
// các HẰNG SỐ (SHA-512 K/IV, trường D/D2/X/Y/I, order L) được SINH & KIỂM bằng script BigInt
// lúc build để loại rủi ro chép tay. CHỈ giữ nhánh verify (không sign/keygen → không cần RNG).
//
// Trả 1 nếu chữ ký detached (64 byte) hợp lệ với public key (32 byte) trên message; 0 nếu sai.
int ed25519_verify(const unsigned char *sig64,
                   const unsigned char *msg, size_t mlen,
                   const unsigned char *pub32);

// KÝ TẤT ĐỊNH (không cần RNG — Ed25519 tất định theo RFC 8032). seed32 = 32 byte bí mật.
// Xuất chữ ký detached 64 byte vào sig64. Dùng để mã hoá/ký script .luax (scriptcrypt.c).
void ed25519_sign(const unsigned char *seed32,
                  const unsigned char *msg, size_t mlen,
                  unsigned char *sig64);

// Dẫn xuất public key (32 byte) từ seed (32 byte). Không cần nhúng pubkey riêng.
void ed25519_seed_pubkey(const unsigned char *seed32, unsigned char *pub32);

// SHA-512 (FIPS 180-4) — tái dùng cài đặt sẵn có trong ed25519.c. out = 64 byte.
void ed25519_sha512(const unsigned char *msg, size_t mlen, unsigned char out64[64]);

#endif
