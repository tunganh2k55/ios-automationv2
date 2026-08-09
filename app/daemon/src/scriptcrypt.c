#include "scriptcrypt.h"
#include "chacha20.h"
#include "ed25519.h"
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

// ===== Cặp key NHÚNG compile-time (seed Ed25519 bí mật) =====
// Sinh 1 lần bằng os.urandom(32). Public key + key mã hoá đều DẪN XUẤT từ seed này lúc chạy.
// Thay seed khác = "đổi khoá" toàn bộ: blob cũ sẽ không còn giải mã/verify được.
static const unsigned char ENC_SEED[32] = {
    0xa5, 0xfb, 0xbe, 0xea, 0x04, 0x3b, 0x51, 0xb1, 0x3c, 0x93, 0x66, 0xcb, 0x9a, 0x50, 0xdf, 0xa4,
    0xa7, 0x47, 0x2f, 0xc2, 0x3a, 0xbe, 0xb7, 0x5b, 0x1f, 0x4f, 0x8d, 0xf1, 0x0b, 0x39, 0x95, 0xc3
};

#define SC_MAGIC0 'I'
#define SC_MAGIC1 'O'
#define SC_MAGIC2 'S'
#define SC_MAGIC3 'X'
#define SC_VER    1
#define SC_HDR    17   // magic(4)+ver(1)+nonce(12)
#define SC_SIG    64
#define SC_OVER   (SC_HDR + 4 + SC_SIG)   // phần cố định (không tính ciphertext): hdr+ctlen+sig

// ---- base64 (chuẩn, có padding). Decode bỏ qua ký tự không thuộc bảng (kể cả xuống dòng). ----
static const char B64E[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static size_t b64_encode(const unsigned char *in, size_t n, char *out, size_t cap) {
    size_t o = 0, i = 0;
    while (i + 3 <= n) {
        if (o + 4 >= cap) return 0;
        unsigned v = (in[i] << 16) | (in[i + 1] << 8) | in[i + 2];
        out[o++] = B64E[(v >> 18) & 63];
        out[o++] = B64E[(v >> 12) & 63];
        out[o++] = B64E[(v >> 6) & 63];
        out[o++] = B64E[v & 63];
        i += 3;
    }
    size_t rem = n - i;
    if (rem) {
        if (o + 4 >= cap) return 0;
        unsigned v = in[i] << 16;
        if (rem == 2) v |= in[i + 1] << 8;
        out[o++] = B64E[(v >> 18) & 63];
        out[o++] = B64E[(v >> 12) & 63];
        out[o++] = (rem == 2) ? B64E[(v >> 6) & 63] : '=';
        out[o++] = '=';
    }
    if (o >= cap) return 0;
    out[o] = '\0';
    return o;
}

static int b64_val(char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;   // '=' và mọi ký tự khác (whitespace...) → không phải dữ liệu
}

static long b64_decode(const char *in, size_t n, unsigned char *out, size_t cap) {
    unsigned acc = 0;
    int bits = 0;
    size_t o = 0;
    for (size_t i = 0; i < n; i++) {
        int v = b64_val(in[i]);
        if (v < 0) continue;              // bỏ qua padding/whitespace
        acc = (acc << 6) | (unsigned)v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            if (o >= cap) return -1;
            out[o++] = (unsigned char)((acc >> bits) & 0xFF);
        }
    }
    return (long)o;
}

// key mã hoá = SHA512(SEED || "iosauto-enc-v1")[0:32]
static void derive_enc_key(unsigned char key[32]) {
    static const char TAG[] = "iosauto-enc-v1";
    unsigned char buf[32 + sizeof(TAG)];
    unsigned char h[64];
    memcpy(buf, ENC_SEED, 32);
    memcpy(buf + 32, TAG, sizeof(TAG) - 1);   // không gồm NUL
    ed25519_sha512(buf, 32 + sizeof(TAG) - 1, h);
    memcpy(key, h, 32);
}

int scriptcrypt_looks_encrypted(const char *text, size_t len) {
    // Bỏ qua khoảng trắng đầu, rồi so tiền tố base64 của magic "IOS" = "SU9T".
    size_t i = 0;
    while (i < len && (text[i] == ' ' || text[i] == '\n' ||
                       text[i] == '\r' || text[i] == '\t')) i++;
    return (len - i >= 4 && text[i] == 'S' && text[i+1] == 'U' &&
            text[i+2] == '9' && text[i+3] == 'T') ? 1 : 0;
}

long scriptcrypt_encrypt(const char *plain, size_t plen, char *out_b64, size_t cap) {
    size_t binlen = SC_OVER + plen;
    unsigned char *bin = (unsigned char *)malloc(binlen);
    if (!bin) return -1;

    unsigned char key[32], nonce_full[64];
    derive_enc_key(key);
    ed25519_sha512((const unsigned char *)plain, plen, nonce_full);   // nonce = SHA512(plain)[0:12]

    // header
    bin[0] = SC_MAGIC0; bin[1] = SC_MAGIC1; bin[2] = SC_MAGIC2; bin[3] = SC_MAGIC3;
    bin[4] = SC_VER;
    memcpy(bin + 5, nonce_full, 12);
    uint32_t ctl = (uint32_t)plen;
    bin[17] = (unsigned char)(ctl & 0xFF);
    bin[18] = (unsigned char)((ctl >> 8) & 0xFF);
    bin[19] = (unsigned char)((ctl >> 16) & 0xFF);
    bin[20] = (unsigned char)((ctl >> 24) & 0xFF);

    // ciphertext = ChaCha20(key, nonce, ctr=1) XOR plain
    chacha20_xor(bin + SC_HDR + 4, (const unsigned char *)plain, plen, key, nonce_full, 1);

    // sig = Ed25519_sign(SEED, magic..ciphertext)
    size_t signed_len = SC_HDR + 4 + plen;
    ed25519_sign(ENC_SEED, bin, signed_len, bin + signed_len);

    long r = (long)b64_encode(bin, binlen, out_b64, cap);
    free(bin);
    return r > 0 ? r : -1;
}

long scriptcrypt_decrypt(const char *b64, size_t blen, char *out, size_t cap) {
    // Blob nhị phân không lớn hơn base64 → dùng blen làm cap decode.
    unsigned char *bin = (unsigned char *)malloc(blen + 4);
    if (!bin) return -1;
    long n = b64_decode(b64, blen, bin, blen + 4);
    if (n < (long)SC_OVER) { free(bin); return -1; }

    if (bin[0] != SC_MAGIC0 || bin[1] != SC_MAGIC1 ||
        bin[2] != SC_MAGIC2 || bin[3] != SC_MAGIC3 || bin[4] != SC_VER) {
        free(bin); return -1;
    }
    uint32_t ctl = (uint32_t)bin[17] | ((uint32_t)bin[18] << 8) |
                   ((uint32_t)bin[19] << 16) | ((uint32_t)bin[20] << 24);
    if ((long)(SC_OVER + ctl) != n) { free(bin); return -1; }     // độ dài không khớp
    if (ctl >= cap) { free(bin); return -1; }                     // không đủ chỗ (chừa NUL)

    size_t signed_len = SC_HDR + 4 + ctl;
    const unsigned char *sig = bin + signed_len;

    // VERIFY chữ ký với public key dẫn xuất từ SEED
    unsigned char pub[32];
    ed25519_seed_pubkey(ENC_SEED, pub);
    if (ed25519_verify(sig, bin, signed_len, pub) != 1) { free(bin); return -1; }

    // Giải mã
    unsigned char key[32];
    derive_enc_key(key);
    chacha20_xor((unsigned char *)out, bin + SC_HDR + 4, ctl, key, bin + 5, 1);
    out[ctl] = '\0';

    // Toàn vẹn: nonce phải = SHA512(plaintext)[0:12]
    unsigned char chk[64];
    ed25519_sha512((const unsigned char *)out, ctl, chk);
    if (memcmp(chk, bin + 5, 12) != 0) { free(bin); memset(out, 0, ctl); return -1; }

    free(bin);
    return (long)ctl;
}
