// Xác minh grant Ed25519 (Nhóm 1). Xem grant.h.
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonCrypto.h>
#include <time.h>
#include <string.h>
#include "grant.h"
#include "ed25519.h"
#include "log.h"

// ===== Public key NHÚNG compile-time (khớp GRANT_ED25519_SEED / GRANT_KEY_ID bên server) =====
// Sinh lại: node -e "require('dotenv').config(); console.log(require('./lib/grant').publicKeyRaw().toString('hex'))"
#define GRANT_KEY_ID "license-2026-01"
static const unsigned char GRANT_PUBKEY[32] = {
  0x1b,0x29,0x27,0x1c,0x41,0x0a,0x23,0x1d,0xc4,0x55,0x57,0x8f,0x1d,0x20,0x62,0x42,
  0x53,0x8b,0x3a,0xaa,0x09,0x43,0x00,0x56,0xa8,0xae,0x55,0x46,0x45,0x16,0x6c,0x20,
};

#define SKEW 120   // dung sai đồng hồ (giây)

// ---- Self-test: vector do server (BoringSSL) sinh, đã kiểm trên host (cl.exe). ----
static const unsigned char ST_PUB[32] = {
  0x1b,0x29,0x27,0x1c,0x41,0x0a,0x23,0x1d,0xc4,0x55,0x57,0x8f,0x1d,0x20,0x62,0x42,
  0x53,0x8b,0x3a,0xaa,0x09,0x43,0x00,0x56,0xa8,0xae,0x55,0x46,0x45,0x16,0x6c,0x20,
};
static const unsigned char ST_MSG[27] = {
  0x69,0x6f,0x73,0x61,0x75,0x74,0x6f,0x2d,0x65,0x64,0x32,0x35,0x35,0x31,0x39,0x2d,
  0x73,0x65,0x6c,0x66,0x74,0x65,0x73,0x74,0x2d,0x76,0x31,
};
static const unsigned char ST_SIG[64] = {
  0x14,0x07,0x89,0x96,0x28,0xb2,0x09,0x23,0xf9,0x53,0xd7,0x3e,0x65,0x43,0x25,0xea,
  0xe0,0x05,0x02,0x49,0x7a,0x7a,0x8e,0x3c,0xca,0x0e,0x00,0x11,0xb0,0xef,0x48,0x42,
  0x75,0xa5,0x8c,0x3a,0x88,0x4a,0x33,0x5a,0xfd,0xa5,0x01,0xb1,0x2d,0x44,0x19,0x29,
  0x30,0xb0,0x45,0x6f,0x0d,0x96,0x64,0xab,0xeb,0x93,0x66,0x03,0x5d,0x5f,0xf0,0x04,
};

int grant_selftest(void) {
    // 1) vector đúng phải PASS.
    if (ed25519_verify(ST_SIG, ST_MSG, sizeof(ST_MSG), ST_PUB) != 1) return 0;
    // 2) sửa 1 byte chữ ký → phải FAIL.
    unsigned char bad[64]; memcpy(bad, ST_SIG, 64); bad[0] ^= 0x01;
    if (ed25519_verify(bad, ST_MSG, sizeof(ST_MSG), ST_PUB) != 0) return 0;
    // 3) sửa 1 byte message → phải FAIL.
    unsigned char bm[27]; memcpy(bm, ST_MSG, 27); bm[3] ^= 0x01;
    if (ed25519_verify(ST_SIG, bm, sizeof(bm), ST_PUB) != 0) return 0;
    return 1;
}

static NSData *b64dec(const char *s) {
    if (!s) return nil;
    NSString *str = [NSString stringWithUTF8String:s];
    if (!str) return nil;
    return [[NSData alloc] initWithBase64EncodedString:str
             options:NSDataBase64DecodingIgnoreUnknownCharacters];
}

// base64(sha256(utf8(nonce))) — khớp cách server tính nh.
static NSString *sha256_b64(const char *s) {
    NSData *in = [[NSString stringWithUTF8String:(s ? s : "")] dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char h[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(in.bytes, (CC_LONG)in.length, h);
    return [[NSData dataWithBytes:h length:sizeof(h)] base64EncodedStringWithOptions:0];
}

static long json_long(NSDictionary *d, NSString *k, long dflt) {
    id v = d[k];
    return [v isKindOfClass:NSNumber.class] ? [v longValue] : dflt;
}

int grant_verify(const char *payload_b64, const char *sig_b64, const char *keyId,
                 const char *machineId, const char *nonce, grant_info *out) {
    @autoreleasepool {
        // keyId phải khớp (để sau này xoay khóa; hiện chỉ 1 khóa).
        if (!keyId || strcmp(keyId, GRANT_KEY_ID) != 0) return 0;

        NSData *payload = b64dec(payload_b64);
        NSData *sig = b64dec(sig_b64);
        if (!payload || payload.length == 0 || !sig || sig.length != 64) return 0;

        // (1) VERIFY chữ ký trên ĐÚNG byte payload — TRƯỚC khi parse.
        if (ed25519_verify(sig.bytes, payload.bytes, payload.length, GRANT_PUBKEY) != 1) return 0;

        // (2) verify xong mới parse JSON.
        NSDictionary *p = [NSJSONSerialization JSONObjectWithData:payload options:0 error:nil];
        if (![p isKindOfClass:NSDictionary.class]) return 0;

        // (3) kiểm schema/claims.
        if (json_long(p, @"v", 0) != 1) return 0;
        if (![p[@"iss"] isEqual:@"iosautos"]) return 0;
        if (![p[@"aud"] isEqual:@"com.iosautos.daemon"]) return 0;

        NSString *dev = [p[@"dev"] isKindOfClass:NSString.class] ? p[@"dev"] : nil;
        if (!dev || !machineId || strcmp(dev.UTF8String, machineId) != 0) return 0; // bind thiết bị

        long now = (long)time(NULL);
        long iat = json_long(p, @"iat", 0);
        long exp = json_long(p, @"exp", 0);
        if (iat <= 0 || iat > now + SKEW) return 0;         // phát hành ở tương lai → từ chối

        if (nonce) {
            // grant TƯƠI: chống replay + chưa hết hạn.
            NSString *nh = [p[@"nh"] isKindOfClass:NSString.class] ? p[@"nh"] : nil;
            if (!nh || ![nh isEqualToString:sha256_b64(nonce)]) return 0;
            if (exp <= now - SKEW) return 0;                 // đã hết hạn
        }
        // grant từ cache (nonce==NULL): KHÔNG ép exp — độ cũ do lớp phân tầng (now - iat) quyết định.

        if (out) {
            memset(out, 0, sizeof(*out));
            out->iat = iat; out->exp = exp;
            out->gen = json_long(p, @"gen", 0);
            id lexp = p[@"lexp"];
            out->lexp = [lexp isKindOfClass:NSNumber.class] ? [lexp longValue] : -1;
            NSString *plan = [p[@"plan"] isKindOfClass:NSString.class] ? p[@"plan"] : @"";
            snprintf(out->plan, sizeof(out->plan), "%s", plan.UTF8String ?: "");
            snprintf(out->dev, sizeof(out->dev), "%s", dev.UTF8String ?: "");
        }
        return 1;
    }
}
