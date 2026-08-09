#import <Foundation/Foundation.h>
#include "license.h"
#include "grant.h"
#include "log.h"
#include <pthread.h>
#include <time.h>
#include <string.h>
#include <stdlib.h>

// ===== Cấu hình =====
#define LICENSE_FILE  "/var/jb/usr/local/iosauto/license.json"
#define APP_SLUG      "iosauto"

// Build flag: bản PHÁT HÀNH (mặc định) khoá cứng server + KHÔNG cho đổi server lúc chạy.
// Bản DEV/staging: biên dịch với -DIOSAUTO_LICENSE_STAGING để trỏ server test + cho phép đổi.
#ifdef IOSAUTO_LICENSE_STAGING
  #define DEFAULT_SERVER        "https://staging.iosautos.com"
  #define ALLOW_SERVER_OVERRIDE 1
#else
  #define DEFAULT_SERVER        "https://iosautos.com"
  #define ALLOW_SERVER_OVERRIDE 0
#endif

#define REVERIFY_SEC   600          // Nhóm 1: refresh grant nền mỗi 10 phút (grant TTL 20').
#define HTTP_TIMEOUT   8.0

// Ngưỡng phân tầng offline theo ĐỘ CŨ của grant (now - iat; iat đã-ký nên không giả được).
#define TIER_FULL_SEC     1800      // <30'  → FULL
#define TIER_CONTINUE_SEC 21600     // <6h   → CONTINUE
#define TIER_VIEW_SEC     86400     // <24h  → VIEW ; ≥24h → LOCKED

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static NSMutableDictionary *g_state = nil;    // nội dung license.json (giữ trong RAM)
static volatile int g_tier = LIC_LOCKED;      // bậc quyền hiện tại (đọc không khoá)
static volatile int g_app_valid = 0;          // = (g_tier > LOCKED) — giữ để tương thích
static volatile int g_crypto_ok = 0;          // Ed25519 self-test pass? (0 → fail-closed)

// ---- tiện ích file ----
static void save_state_locked(void) {
    @try {
        NSData *d = [NSJSONSerialization dataWithJSONObject:g_state options:NSJSONWritingPrettyPrinted error:nil];
        if (d) [d writeToFile:@LICENSE_FILE atomically:YES];
    } @catch (__unused NSException *e) {}
}

static NSString *norm_machine(NSString *raw) {
    NSMutableString *o = [NSMutableString string];
    for (NSUInteger i = 0; i < raw.length && o.length < 32; i++) {
        unichar c = [raw characterAtIndex:i];
        if ((c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z')) [o appendFormat:@"%C", c];
        else if (c >= 'a' && c <= 'z') [o appendFormat:@"%C", (unichar)(c - 32)];
    }
    return o;
}

static void ensure_machine_id_locked(void) {
    NSString *mid = g_state[@"machineId"];
    if ([mid isKindOfClass:NSString.class] && mid.length >= 8) return;
    NSString *gen = norm_machine([[NSUUID UUID] UUIDString]);
    if (gen.length < 8) gen = norm_machine([NSString stringWithFormat:@"IA%ld", (long)time(NULL)]);
    g_state[@"machineId"] = gen;
    save_state_locked();
    log_msg("license: sinh machineId mới (%.6s…)", [gen UTF8String]);   // chỉ log tiền tố, không lộ full ID
}

static NSMutableDictionary *cache_locked(void) {
    NSMutableDictionary *c = g_state[@"cache"];
    if (![c isKindOfClass:NSMutableDictionary.class]) {
        c = [NSMutableDictionary dictionary];
        if ([g_state[@"cache"] isKindOfClass:NSDictionary.class]) [c addEntriesFromDictionary:g_state[@"cache"]];
        g_state[@"cache"] = c;
    }
    return c;
}

// ---- HTTP POST JSON (đồng bộ, timeout ngắn). Trả dict hoặc nil (mạng lỗi).
//      out_status (tuỳ chọn) = HTTP status code; 0 nếu không có phản hồi. Dùng để phân biệt
//      "license thật sự hỏng" (2xx + reason) vs "lỗi tạm thời" (429/503/5xx) — tránh khoá oan. ----
static NSDictionary *http_post_json(NSString *url, NSDictionary *bodyDict, long *out_status) {
    if (out_status) *out_status = 0;
    @try {
        NSData *body = [NSJSONSerialization dataWithJSONObject:bodyDict options:0 error:nil];
        if (!body) return nil;
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
        req.HTTPMethod = @"POST";
        req.timeoutInterval = HTTP_TIMEOUT;
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        req.HTTPBody = body;
        __block NSData *outData = nil;
        __block long httpStatus = 0;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
            completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                if (!err && data) outData = data;
                if ([resp isKindOfClass:NSHTTPURLResponse.class]) httpStatus = (long)[(NSHTTPURLResponse *)resp statusCode];
                dispatch_semaphore_signal(sem);
            }];
        [task resume];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((HTTP_TIMEOUT + 2) * NSEC_PER_SEC)));
        if (out_status) *out_status = httpStatus;
        if (!outData) return nil;
        id j = [NSJSONSerialization JSONObjectWithData:outData options:0 error:nil];
        return [j isKindOfClass:NSDictionary.class] ? j : nil;
    } @catch (__unused NSException *e) { return nil; }
}

// Đọc server/appKey/machineId dưới lock (copy ra để gọi mạng ngoài lock).
static void snapshot_locked(NSString **server, NSString **appKey, NSString **mid) {
#if ALLOW_SERVER_OVERRIDE
    *server = g_state[@"server"] ?: @DEFAULT_SERVER;
#else
    *server = @DEFAULT_SERVER;   // production: khoá cứng compile-time, bỏ qua mọi override trong file
#endif
    *appKey = g_state[@"appKey"] ?: @"";
    *mid = g_state[@"machineId"] ?: @"";
}

// ---- helper Nhóm 1 ----
// Nonce ngẫu nhiên client TỰ SINH trước mỗi request (challenge-response).
static NSString *gen_nonce(void) {
    unsigned char b[16];
    arc4random_buf(b, sizeof(b));
    NSMutableString *s = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < 16; i++) [s appendFormat:@"%02x", b[i]];
    return s;
}

// Bậc quyền theo độ cũ grant (iat đã-ký) + hạn thật license (lexp).
static int tier_from_grant(long iat, long lexp, long now) {
    if (lexp > 0 && now > lexp) return LIC_LOCKED;   // license THẬT đã hết hạn
    long age = now - iat;
    if (age < 0) age = 0;                            // lệch đồng hồ nhẹ
    if (age < TIER_FULL_SEC)     return LIC_FULL;
    if (age < TIER_CONTINUE_SEC) return LIC_CONTINUE;
    if (age < TIER_VIEW_SEC)     return LIC_VIEW;
    return LIC_LOCKED;
}

static void set_display_locked(NSMutableDictionary *c, int tier, NSString *reason, grant_info *gi) {
    g_tier = tier;
    g_app_valid = (tier > LIC_LOCKED) ? 1 : 0;
    c[@"tier"] = @(tier);
    c[@"reason"] = reason ?: @"?";
    if (gi) {
        c[@"plan"] = gi->plan[0] ? [NSString stringWithUTF8String:gi->plan] : (id)[NSNull null];
        c[@"lexp"] = @(gi->lexp);
        c[@"gen"]  = @(gi->gen);
        c[@"iat"]  = @(gi->iat);
    }
}

static void clear_grant_locked(NSMutableDictionary *c) {
    [c removeObjectForKey:@"payload"];
    [c removeObjectForKey:@"signature"];
    [c removeObjectForKey:@"keyId"];
}

// ---- Anti-rollback đồng hồ (chống lùi giờ để gian lận tier offline) ----
// Máy jailbreak: root chỉnh được đồng hồ tường; tier offline dựa trên (now - iat) nên lùi giờ =
// kéo dài quyền. Ta giữ 'hwm' (mốc CAO NHẤT từng thấy, epoch giây) persist trong cache và kẹp
// now KHÔNG nhỏ hơn hwm. hwm chỉ TIẾN theo đồng hồ; khi có grant TƯƠI (server ký) thì ĐẶT LẠI
// đúng iat — chân lý server — để tự sửa nếu đồng hồ từng nhảy tương lai (poison) và không tự trôi.
// LƯU Ý (trung thực): đây là RÀO CẢN, không phải bảo chứng — offline + root vẫn có thể "đóng băng"
// đồng hồ tại thời điểm online cuối. Nó chặn đòn phổ biến: lùi giờ để GỠ hết-hạn / phục hồi bậc.
static long hwm_get_locked(NSMutableDictionary *c) {
    return [c[@"hwm"] isKindOfClass:NSNumber.class] ? [c[@"hwm"] longValue] : 0;
}
// Trả "now" chống-lùi = max(đồng hồ, hwm); đồng thời nâng hwm theo đồng hồ (chỉ tiến).
static long mono_now_locked(NSMutableDictionary *c) {
    long now = (long)time(NULL);
    long hwm = hwm_get_locked(c);
    if (now > hwm) { hwm = now; c[@"hwm"] = @(hwm); }
    return hwm;
}

// Các lý do server coi là license THẬT SỰ hỏng → mới được khoá cứng + xoá grant. Mọi phản hồi
// khác (429 rate-limit, 503 server_no_key, 5xx, bad_nonce, reason lạ) = lỗi TẠM THỜI → giữ ân
// hạn offline (không xoá grant), tránh bắt khách đang hợp lệ kích hoạt lại oan.
static int reason_is_terminal(NSString *r) {
    if (![r isKindOfClass:NSString.class]) return 0;
    NSArray *terminal = @[@"not_found", @"tool_mismatch", @"revoked",
                          @"expired", @"machine_mismatch", @"not_activated", @"bad_machine"];
    return [terminal containsObject:r] ? 1 : 0;
}

// Mạng lỗi HOẶC khởi động: tính tier từ grant trong cache (không có nonce tươi).
static void apply_offline(long now) {
    pthread_mutex_lock(&g_mu);
    NSMutableDictionary *c = cache_locked();
    if (!g_crypto_ok) { set_display_locked(c, LIC_LOCKED, @"crypto_selftest_failed", NULL); save_state_locked(); pthread_mutex_unlock(&g_mu); return; }
    now = mono_now_locked(c);                        // chống lùi đồng hồ (thay đồng hồ tường thô)
    NSString *mid = g_state[@"machineId"] ?: @"";
    const char *pl  = [c[@"payload"] isKindOfClass:NSString.class]   ? [c[@"payload"] UTF8String]   : NULL;
    const char *sg  = [c[@"signature"] isKindOfClass:NSString.class] ? [c[@"signature"] UTF8String] : NULL;
    const char *kid = [c[@"keyId"] isKindOfClass:NSString.class]     ? [c[@"keyId"] UTF8String]     : NULL;
    grant_info gi;
    int ok = (pl && sg && kid) ? grant_verify(pl, sg, kid, mid.UTF8String, NULL, &gi) : 0;
    if (ok) set_display_locked(c, tier_from_grant(gi.iat, gi.lexp, now), @"offline", &gi);
    else    { clear_grant_locked(c); set_display_locked(c, LIC_LOCKED, @"offline_nogrant", NULL); }
    save_state_locked();
    pthread_mutex_unlock(&g_mu);
}

// Lấy grant TƯƠI từ server → verify → cập nhật tier. Gọi nền mỗi REVERIFY_SEC + khi kích hoạt.
static void grant_now(void) {
    if (!g_crypto_ok) {   // self-test hỏng → khoá tuyệt đối
        pthread_mutex_lock(&g_mu);
        set_display_locked(cache_locked(), LIC_LOCKED, @"crypto_selftest_failed", NULL);
        save_state_locked();
        pthread_mutex_unlock(&g_mu);
        return;
    }
    NSString *server, *appKey, *mid;
    pthread_mutex_lock(&g_mu);
    snapshot_locked(&server, &appKey, &mid);
    pthread_mutex_unlock(&g_mu);
    long now = (long)time(NULL);

    if (appKey.length == 0) {   // chưa kích hoạt
        pthread_mutex_lock(&g_mu);
        NSMutableDictionary *c = cache_locked();
        clear_grant_locked(c);
        set_display_locked(c, LIC_LOCKED, @"no_key", NULL);
        save_state_locked();
        pthread_mutex_unlock(&g_mu);
        return;
    }

    NSString *nonce = gen_nonce();
    long status = 0;
    NSDictionary *res = http_post_json([server stringByAppendingString:@"/api/grant"],
        @{ @"app": @APP_SLUG, @"appKey": appKey, @"machineId": mid, @"nonce": nonce }, &status);

    if (!res) { apply_offline(now); return; }   // mạng lỗi → ân hạn phân tầng theo cache

    if (![res[@"ok"] boolValue]) {
        NSString *reason = [res[@"reason"] isKindOfClass:NSString.class] ? res[@"reason"] : @"?";
        // CHỈ khoá cứng khi HTTP 2xx VÀ reason là lý do license thật sự hỏng. 429 (rate-limit),
        // 503 (server chưa cấu hình khóa), 5xx, hay reason lạ = lỗi TẠM THỜI → giữ grant + ân hạn
        // offline, KHÔNG bắt khách đang hợp lệ kích hoạt lại oan (bug cũ: mọi ok:false đều khoá).
        if (status >= 200 && status < 300 && reason_is_terminal(reason)) {
            pthread_mutex_lock(&g_mu);
            NSMutableDictionary *c = cache_locked();
            clear_grant_locked(c);
            set_display_locked(c, LIC_LOCKED, reason, NULL);
            save_state_locked();
            pthread_mutex_unlock(&g_mu);
        } else {
            log_msg("license: grant lỗi tạm thời (http=%ld reason=%s) → giữ ân hạn offline",
                    status, [reason UTF8String] ?: "?");
            apply_offline(now);
        }
        return;
    }

    NSDictionary *g = [res[@"grant"] isKindOfClass:NSDictionary.class] ? res[@"grant"] : nil;
    NSString *plS = [g[@"payload"] isKindOfClass:NSString.class]   ? g[@"payload"]   : nil;
    NSString *sgS = [g[@"signature"] isKindOfClass:NSString.class] ? g[@"signature"] : nil;
    NSString *kiS = [g[@"keyId"] isKindOfClass:NSString.class]     ? g[@"keyId"]     : nil;
    grant_info gi;
    int ok = (plS && sgS && kiS) &&
             grant_verify(plS.UTF8String, sgS.UTF8String, kiS.UTF8String, mid.UTF8String, nonce.UTF8String, &gi);

    pthread_mutex_lock(&g_mu);
    NSMutableDictionary *c = cache_locked();
    if (ok) {
        c[@"payload"] = plS; c[@"signature"] = sgS; c[@"keyId"] = kiS;   // cache CHỈ lưu grant đã ký
        c[@"hwm"] = @(gi.iat);                       // grant tươi = chân lý server → đặt lại mốc chống-lùi
        int tier = tier_from_grant(gi.iat, gi.lexp, mono_now_locked(c));
        set_display_locked(c, tier, (tier == LIC_FULL) ? @"ok" : @"grant_stale", &gi);
    } else {
        clear_grant_locked(c);
        set_display_locked(c, LIC_LOCKED, @"bad_grant", NULL);   // chữ ký/nonce/dev sai → nghi ngờ, khoá
    }
    save_state_locked();
    pthread_mutex_unlock(&g_mu);
}

// ---- API công khai ----
void license_machine_id(char *out, size_t len) {
    if (!out || !len) return;
    pthread_mutex_lock(&g_mu);
    const char *m = [(g_state[@"machineId"] ?: @"") UTF8String] ?: "";
    snprintf(out, len, "%s", m);
    pthread_mutex_unlock(&g_mu);
}

int license_app_active(void) { return g_tier > LIC_LOCKED ? 1 : 0; }
int license_tier(void) { return g_tier; }

static void *refresh_thread(void *arg) {
    (void)arg;
    grant_now();                        // lần đầu ngay khi khởi động
    for (;;) { sleep(REVERIFY_SEC); grant_now(); }
    return NULL;
}

void license_init(void) {
    g_crypto_ok = grant_selftest();     // KIỂM crypto TRƯỚC — hỏng thì fail-closed

    pthread_mutex_lock(&g_mu);
    g_state = [NSMutableDictionary dictionary];
    @try {
        NSData *d = [NSData dataWithContentsOfFile:@LICENSE_FILE];
        if (d) {
            id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
            if ([j isKindOfClass:NSDictionary.class]) [g_state addEntriesFromDictionary:j];
        }
    } @catch (__unused NSException *e) {}

    // Migration Nhóm 0→1: strip backdoor + cache-boolean cũ khỏi state (không thể vô tình dùng lại).
    [g_state removeObjectForKey:@"manualActive"];
#if !ALLOW_SERVER_OVERRIDE
    [g_state removeObjectForKey:@"server"];
#endif
    if (![g_state[@"server"] isKindOfClass:NSString.class] || [g_state[@"server"] length] == 0)
        g_state[@"server"] = @DEFAULT_SERVER;
    ensure_machine_id_locked();
    NSMutableDictionary *c = cache_locked();
    for (NSString *k in @[@"appValid", @"lastOk", @"lastCheck", @"expiresAt"]) [c removeObjectForKey:k];
    save_state_locked();
    pthread_mutex_unlock(&g_mu);

    if (!g_crypto_ok)
        log_msg("license: ⚠️ Ed25519 SELF-TEST HỎNG → fail-closed (khoá bản quyền). KHÔNG deploy bản này!");

    // Tier ban đầu tính từ grant trong cache (khởi động có thể đang offline); thread sẽ lấy grant tươi.
    apply_offline((long)time(NULL));

    pthread_t th;
    if (pthread_create(&th, NULL, refresh_thread, NULL) == 0) pthread_detach(th);
    log_msg("license: init (server=%s, tier=%d, crypto=%d)",
            [(g_state[@"server"]) UTF8String], g_tier, g_crypto_ok);
}

int license_set_server(const char *url) {
#if !ALLOW_SERVER_OVERRIDE
    (void)url;
    log_msg("license: đổi server bị khoá trong bản phát hành");
    return 0;   // production: server khoá cứng compile-time, không cho đổi lúc chạy
#else
    if (!url || !url[0]) return 0;
    NSString *u = [NSString stringWithUTF8String:url];
    if (![u hasPrefix:@"http://"] && ![u hasPrefix:@"https://"]) return 0;
    while ([u hasSuffix:@"/"]) u = [u substringToIndex:u.length - 1];
    pthread_mutex_lock(&g_mu);
    g_state[@"server"] = u; save_state_locked();
    pthread_mutex_unlock(&g_mu);
    grant_now();
    return 1;
#endif
}

void license_clear(void) {
    pthread_mutex_lock(&g_mu);
    [g_state removeObjectForKey:@"appKey"];
    [g_state removeObjectForKey:@"cache"];
    g_tier = LIC_LOCKED; g_app_valid = 0;
    save_state_locked();
    pthread_mutex_unlock(&g_mu);
}

int license_activate(const char *key, char *msg, size_t msg_len) {
    NSString *k = key ? [[NSString stringWithUTF8String:key] stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]] : @"";
    if (k.length < 4) { if (msg) snprintf(msg, msg_len, "Thiếu license key"); return 0; }

    NSString *server, *appKey, *mid, *oldKey;
    pthread_mutex_lock(&g_mu);
    oldKey = [g_state[@"appKey"] isKindOfClass:NSString.class] ? g_state[@"appKey"] : nil;  // giữ để khôi phục nếu lỗi
    g_state[@"appKey"] = k;               // đặt tạm để grant nền dùng key mới
    save_state_locked();
    snapshot_locked(&server, &appKey, &mid);
    pthread_mutex_unlock(&g_mu);

    // 1) activate/device: bind máy này vào key (idempotent nếu đã bind đúng máy).
    //    Gửi kèm currentKey = key cũ đang chạy → server CỘNG DỒN hạn (gia hạn) nếu còn hạn.
    NSDictionary *act = http_post_json([server stringByAppendingString:@"/api/activate/device"],
        @{ @"tool": @APP_SLUG, @"key": k, @"machineId": mid, @"currentKey": (oldKey ?: @"") }, NULL);
    const char *emsg = NULL;
    if (!act) {
        emsg = "Không kết nối được máy chủ license";
    } else if (![act[@"ok"] boolValue]) {
        NSString *r = act[@"reason"] ?: @"?";
        if ([r isEqualToString:@"not_found"]) emsg = "Key không tồn tại";
        else if ([r isEqualToString:@"machine_mismatch"]) emsg = "Key đã kích hoạt trên máy khác";
        else if ([r isEqualToString:@"expired"]) emsg = "Key đã hết hạn";
        else if ([r isEqualToString:@"revoked"]) emsg = "Key đã bị thu hồi";
        else if ([r isEqualToString:@"tool_mismatch"]) emsg = "Key không dành cho app này";
        else emsg = "Kích hoạt thất bại";
    }

    // 2) lấy grant để cập nhật trạng thái.
    grant_now();

    if (license_app_active()) {
        pthread_mutex_lock(&g_mu);
        NSString *plan = ([cache_locked()[@"plan"] isKindOfClass:NSString.class]) ? cache_locked()[@"plan"] : nil;
        pthread_mutex_unlock(&g_mu);
        if (msg) snprintf(msg, msg_len, "Đã kích hoạt%s%s",
                          plan ? " · gói " : "", plan ? [plan UTF8String] : "");
        return 1;
    }

    // THẤT BẠI → KHÔI PHỤC key cũ (nếu có), không để rớt license vì gõ nhầm key mới.
    pthread_mutex_lock(&g_mu);
    if (oldKey) g_state[@"appKey"] = oldKey; else [g_state removeObjectForKey:@"appKey"];
    save_state_locked();
    pthread_mutex_unlock(&g_mu);
    if (oldKey) grant_now();              // xác thực lại key cũ để phục hồi trạng thái
    else {
        pthread_mutex_lock(&g_mu);
        NSMutableDictionary *c = cache_locked();
        clear_grant_locked(c);
        set_display_locked(c, LIC_LOCKED, @"no_key", NULL);
        save_state_locked();
        pthread_mutex_unlock(&g_mu);
    }
    if (msg) snprintf(msg, msg_len, "%s", emsg ? emsg : "Chưa kích hoạt được");
    return 0;
}

static const char *tier_name(int t) {
    switch (t) { case LIC_FULL: return "full"; case LIC_CONTINUE: return "continue";
                 case LIC_VIEW: return "view"; default: return "locked"; }
}

size_t license_status_json(char *out, size_t cap) {
    pthread_mutex_lock(&g_mu);
    NSMutableDictionary *c = cache_locked();
    NSString *mid = g_state[@"machineId"] ?: @"";
    NSString *server = g_state[@"server"] ?: @DEFAULT_SERVER;
    BOOL hasKey = [g_state[@"appKey"] isKindOfClass:NSString.class] && [g_state[@"appKey"] length] > 0;
    int tier = g_tier;

    id expISO = [NSNull null];
    long lexp = [c[@"lexp"] isKindOfClass:NSNumber.class] ? [c[@"lexp"] longValue] : -1;
    if (lexp > 0) {
        NSISO8601DateFormatter *f = [[NSISO8601DateFormatter alloc] init];
        expISO = [f stringFromDate:[NSDate dateWithTimeIntervalSince1970:lexp]];
    }
    NSDictionary *appOut = @{
        @"valid": @(tier > LIC_LOCKED ? YES : NO),
        @"plan": c[@"plan"] ?: [NSNull null],
        @"expiresAt": expISO,
        @"tier": @(tier),
        @"tierName": @(tier_name(tier)),
    };
    NSDictionary *root = @{
        @"ok": @YES,
        @"activated": @(tier > LIC_LOCKED ? YES : NO),
        @"reason": c[@"reason"] ?: @"unknown",
        @"machineId": mid,
        @"server": server,
        @"hasKey": @(hasKey),
        @"tier": @(tier),
        @"tierName": @(tier_name(tier)),
        @"gen": c[@"gen"] ?: @(0),
        @"app": appOut,
    };
    pthread_mutex_unlock(&g_mu);
    NSData *d = [NSJSONSerialization dataWithJSONObject:root options:0 error:nil];
    size_t n = d ? d.length : 0;
    if (n >= cap) n = cap - 1;
    if (d) memcpy(out, d.bytes, n);
    out[n] = '\0';
    return n;
}
