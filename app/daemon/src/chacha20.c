// ChaCha20 (RFC 8439) — public-domain style reference implementation, tự chứa.
#include "chacha20.h"
#include <string.h>

#define ROTL32(x, n) (((x) << (n)) | ((x) >> (32 - (n))))

static uint32_t load32_le(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static void store32_le(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24);
}

#define QR(a, b, c, d)                       \
    a += b; d ^= a; d = ROTL32(d, 16);       \
    c += d; b ^= c; b = ROTL32(b, 12);       \
    a += b; d ^= a; d = ROTL32(d, 8);        \
    c += d; b ^= c; b = ROTL32(b, 7)

static void chacha20_block(uint32_t out[16], const uint32_t in[16]) {
    uint32_t x[16];
    int i;
    for (i = 0; i < 16; i++) x[i] = in[i];
    for (i = 0; i < 10; i++) {           // 20 vòng = 10 lần (cột + chéo)
        QR(x[0], x[4], x[8],  x[12]);
        QR(x[1], x[5], x[9],  x[13]);
        QR(x[2], x[6], x[10], x[14]);
        QR(x[3], x[7], x[11], x[15]);
        QR(x[0], x[5], x[10], x[15]);
        QR(x[1], x[6], x[11], x[12]);
        QR(x[2], x[7], x[8],  x[13]);
        QR(x[3], x[4], x[9],  x[14]);
    }
    for (i = 0; i < 16; i++) out[i] = x[i] + in[i];
}

void chacha20_xor(uint8_t *out, const uint8_t *in, size_t len,
                  const uint8_t key[32], const uint8_t nonce[12],
                  uint32_t counter) {
    static const uint8_t sigma[16] = "expand 32-byte k";
    uint32_t state[16], ks[16];
    uint8_t block[64];
    size_t i;
    int j;

    state[0] = load32_le(sigma + 0);
    state[1] = load32_le(sigma + 4);
    state[2] = load32_le(sigma + 8);
    state[3] = load32_le(sigma + 12);
    for (j = 0; j < 8; j++) state[4 + j] = load32_le(key + 4 * j);
    state[12] = counter;
    state[13] = load32_le(nonce + 0);
    state[14] = load32_le(nonce + 4);
    state[15] = load32_le(nonce + 8);

    while (len > 0) {
        chacha20_block(ks, state);
        for (j = 0; j < 16; j++) store32_le(block + 4 * j, ks[j]);
        size_t n = len < 64 ? len : 64;
        for (i = 0; i < n; i++) out[i] = in[i] ^ block[i];
        out += n; in += n; len -= n;
        state[12]++;                     // tăng block counter
    }
}
