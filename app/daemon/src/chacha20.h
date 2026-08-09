#ifndef IOSAUTO_CHACHA20_H
#define IOSAUTO_CHACHA20_H
#include <stddef.h>
#include <stdint.h>

// ChaCha20 stream cipher (RFC 8439) — tự chứa, không bảng tra, không phụ thuộc ngoài.
// XOR keystream lên `in` (dài `len`) → `out`. Mã hoá & giải mã dùng chung hàm này
// (đối xứng: chạy lại đúng key+nonce+counter sẽ khôi phục plaintext).
//   key   : 32 byte
//   nonce : 12 byte
//   counter: giá trị block counter khởi đầu (RFC 8439 thường bắt đầu tại 1 cho payload)
// out và in có thể trỏ cùng vùng (in-place).
void chacha20_xor(uint8_t *out, const uint8_t *in, size_t len,
                  const uint8_t key[32], const uint8_t nonce[12],
                  uint32_t counter);

#endif
