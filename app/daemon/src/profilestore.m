// profilestore.m — kho gán "device profile → app" (xem profilestore.h).
// Daemon ghi plist; Tweak.mm đọc lại từ trong app đích để spoof định danh.
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <stdlib.h>
#include <stdint.h>
#include "profilestore.h"
#include "log.h"

// Cùng base với craneprefs (đã xác nhận đọc được từ trong app sandbox trên rootless JB).
#define PROFILES_PATH @"/var/jb/var/mobile/Library/Preferences/com.iosauto.deviceprofiles.plist"

static NSMutableDictionary *load_root(void) {
    NSData *d = [NSData dataWithContentsOfFile:PROFILES_PATH];
    if (d) {
        id root = [NSPropertyListSerialization propertyListWithData:d
            options:NSPropertyListMutableContainersAndLeaves format:NULL error:NULL];
        if ([root isKindOfClass:[NSMutableDictionary class]]) return root;
    }
    return [NSMutableDictionary dictionary];
}

// Ghi nguyên tử dạng binary plist. Trả YES nếu OK.
static BOOL save_root(NSDictionary *root) {
    NSData *ob = [NSPropertyListSerialization dataWithPropertyList:root
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    return ob && [ob writeToFile:PROFILES_PATH atomically:YES];
}

static NSString *S(const char *s) { return s ? [NSString stringWithUTF8String:s] : @""; }

// Reserved keys (bundleId thật không bắt đầu bằng '_').
static NSMutableArray *targets_of(NSMutableDictionary *root) {
    NSMutableArray *t = root[@"_targets"];
    if (![t isKindOfClass:NSMutableArray.class]) { t = [NSMutableArray array]; root[@"_targets"] = t; }
    return t;
}
static void add_target(NSMutableDictionary *root, NSString *bundle) {
    NSMutableArray *t = targets_of(root);
    if (bundle.length && ![t containsObject:bundle]) [t addObject:bundle];
}
static NSMutableDictionary *global_of(NSMutableDictionary *root) {
    NSMutableDictionary *g = root[@"_global"];
    if (![g isKindOfClass:NSMutableDictionary.class]) { g = [NSMutableDictionary dictionary]; root[@"_global"] = g; }
    return g;
}

int profilestore_apply(const char *bundle_id,
                       const char *device_model, const char *hardware_id,
                       const char *system_name, const char *system_version,
                       const char *device_name, const char *locale_id,
                       const char *language_code, const char *timezone_id,
                       int screen_w, int screen_h, double screen_scale,
                       char *err, size_t err_len) {
    @autoreleasepool {
        if (!bundle_id || !bundle_id[0]) {
            if (err && err_len) snprintf(err, err_len, "thiếu bundleId");
            return 1;
        }
        NSMutableDictionary *root = load_root();
        NSDictionary *prof = @{
            @"deviceModel":        S(device_model),
            @"hardwareIdentifier": S(hardware_id),
            @"systemName":         S(system_name),
            @"systemVersion":      S(system_version),
            @"deviceName":         S(device_name),
            @"localeIdentifier":   S(locale_id),
            @"languageCode":       S(language_code),
            @"timezoneIdentifier": S(timezone_id),
            @"screenWidth":        @(screen_w),
            @"screenHeight":       @(screen_h),
            @"screenScale":        @(screen_scale),
        };
        root[S(bundle_id)] = prof;
        add_target(root, S(bundle_id));   // per-app profile → tự đưa vào target list
        if (!save_root(root)) {
            if (err && err_len) snprintf(err, err_len, "ghi %s lỗi", [PROFILES_PATH UTF8String]);
            return 2;
        }
        log_msg("profilestore: gán %s → %s / iOS %s", bundle_id, device_model ?: "?", system_version ?: "?");
        return 0;
    }
}

// Catalog profile HỢP LỆ nhúng sẵn (model/hwid/iOS/locale khớp nhau) để random không cần app.
typedef struct { const char *model, *hwid, *ios, *locale, *lang, *tz; int w, h; double scale; } ia_prof_t;
static const ia_prof_t IA_CATALOG[] = {
    {"iPhone 11",         "iPhone12,1", "15.7", "en_US", "en", "America/New_York",    414, 896, 2},
    {"iPhone 11 Pro",     "iPhone12,3", "16.5", "en_GB", "en", "Europe/London",       375, 812, 3},
    {"iPhone 12",         "iPhone13,2", "16.6", "en_US", "en", "America/New_York",    390, 844, 3},
    {"iPhone 12",         "iPhone13,2", "15.6", "vi_VN", "vi", "Asia/Ho_Chi_Minh",    390, 844, 3},
    {"iPhone 12 Pro Max", "iPhone13,4", "16.4", "ja_JP", "ja", "Asia/Tokyo",          428, 926, 3},
    {"iPhone 13",         "iPhone14,5", "16.6", "en_US", "en", "America/Los_Angeles", 390, 844, 3},
    {"iPhone 13 Pro",     "iPhone14,2", "16.3", "vi_VN", "vi", "Asia/Ho_Chi_Minh",    390, 844, 3},
    {"iPhone 14",         "iPhone14,7", "16.6", "en_US", "en", "America/Chicago",     390, 844, 3},
    {"iPhone 14 Pro",     "iPhone15,2", "16.5", "vi_VN", "vi", "Asia/Ho_Chi_Minh",    393, 852, 3},
    {"iPhone 14 Pro Max", "iPhone15,3", "16.6", "ja_JP", "ja", "Asia/Tokyo",          430, 932, 3},
};
#define IA_CATALOG_N (sizeof(IA_CATALOG) / sizeof(IA_CATALOG[0]))

int profilestore_random_apply(const char *bundle_id, char *out_json, size_t out_json_len,
                              char *err, size_t err_len) {
    if (!bundle_id || !bundle_id[0]) {
        if (err && err_len) snprintf(err, err_len, "thiếu bundleId");
        return 1;
    }
    const ia_prof_t *p = &IA_CATALOG[arc4random_uniform((uint32_t)IA_CATALOG_N)];
    int rc = profilestore_apply(bundle_id, p->model, p->hwid, "iOS", p->ios, "iPhone",
                                p->locale, p->lang, p->tz, p->w, p->h, p->scale, err, err_len);
    if (rc == 0 && out_json && out_json_len) {
        snprintf(out_json, out_json_len,
            "{\"deviceModel\":\"%s\",\"hardwareIdentifier\":\"%s\",\"systemName\":\"iOS\","
            "\"systemVersion\":\"%s\",\"localeIdentifier\":\"%s\",\"timezoneIdentifier\":\"%s\","
            "\"screenWidth\":%d,\"screenHeight\":%d,\"screenScale\":%g}",
            p->model, p->hwid, p->ios, p->locale, p->tz, p->w, p->h, p->scale);
    }
    return rc;
}

// Catalog MODEL (name → hardware/màn) cho spoof.app(bundle, ios, model).
typedef struct { const char *model, *hwid; int w, h; double scale; } ia_model_t;
static const ia_model_t IA_MODELS[] = {
    {"iPhone 11",         "iPhone12,1", 414, 896, 2},
    {"iPhone 11 Pro",     "iPhone12,3", 375, 812, 3},
    {"iPhone 11 Pro Max", "iPhone12,5", 414, 896, 3},
    {"iPhone 12 mini",    "iPhone13,1", 375, 812, 3},
    {"iPhone 12",         "iPhone13,2", 390, 844, 3},
    {"iPhone 12 Pro",     "iPhone13,3", 390, 844, 3},
    {"iPhone 12 Pro Max", "iPhone13,4", 428, 926, 3},
    {"iPhone 13 mini",    "iPhone14,4", 375, 812, 3},
    {"iPhone 13",         "iPhone14,5", 390, 844, 3},
    {"iPhone 13 Pro",     "iPhone14,2", 390, 844, 3},
    {"iPhone 13 Pro Max", "iPhone14,3", 428, 926, 3},
    {"iPhone 14",         "iPhone14,7", 390, 844, 3},
    {"iPhone 14 Plus",    "iPhone14,8", 428, 926, 3},
    {"iPhone 14 Pro",     "iPhone15,2", 393, 852, 3},
    {"iPhone 14 Pro Max", "iPhone15,3", 430, 932, 3},
};
#define IA_MODELS_N (sizeof(IA_MODELS) / sizeof(IA_MODELS[0]))

int profilestore_apply_spec(const char *bundle_id, const char *ios, const char *model,
                            char *out_json, size_t out_json_len, char *err, size_t err_len) {
    if (!bundle_id || !bundle_id[0]) { if (err) snprintf(err, err_len, "thiếu bundleId"); return 1; }
    if (!ios || !ios[0])            { if (err) snprintf(err, err_len, "thiếu iOS"); return 1; }
    if (!model || !model[0])        { if (err) snprintf(err, err_len, "thiếu model"); return 1; }
    const ia_model_t *m = NULL;
    for (size_t i = 0; i < IA_MODELS_N; i++)
        if (strcasecmp(model, IA_MODELS[i].model) == 0) { m = &IA_MODELS[i]; break; }
    if (!m) { if (err) snprintf(err, err_len, "model không nhận diện: %s", model); return 1; }
    // locale/timezone mặc định neutral; global (spoof.region/timezone) sẽ đè ở tweak nếu có.
    int rc = profilestore_apply(bundle_id, m->model, m->hwid, "iOS", ios, "iPhone",
                                "en_US", "en", "America/New_York", m->w, m->h, m->scale, err, err_len);
    if (rc == 0 && out_json && out_json_len)
        snprintf(out_json, out_json_len,
            "{\"deviceModel\":\"%s\",\"hardwareIdentifier\":\"%s\",\"systemVersion\":\"%s\"}",
            m->model, m->hwid, ios);
    return rc;
}

int profilestore_global_set(const char *key, const char *value) {
    if (!key || !key[0]) return 1;
    @autoreleasepool {
        NSMutableDictionary *root = load_root();
        global_of(root)[S(key)] = S(value);
        return save_root(root) ? 0 : 2;
    }
}

int profilestore_global_set_carrier(const char *name, const char *mcc, const char *mnc) {
    @autoreleasepool {
        NSMutableDictionary *root = load_root();
        NSMutableDictionary *g = global_of(root);
        if (name) g[@"carrierName"] = S(name);
        if (mcc)  g[@"carrierMCC"]  = S(mcc);
        if (mnc)  g[@"carrierMNC"]  = S(mnc);
        return save_root(root) ? 0 : 2;
    }
}

int profilestore_target_add(const char *bundle_id) {
    if (!bundle_id || !bundle_id[0]) return 1;
    @autoreleasepool {
        NSMutableDictionary *root = load_root();
        add_target(root, S(bundle_id));
        return save_root(root) ? 0 : 2;
    }
}

int profilestore_reset(void) {
    @autoreleasepool {
        [[NSFileManager defaultManager] removeItemAtPath:PROFILES_PATH error:NULL];
        log_msg("profilestore: reset toàn bộ spoof config");
        return 0;
    }
}

// Nhà mạng theo vùng (cho random). mcc/mnc thực tế.
typedef struct { const char *region, *name, *mcc, *mnc; } ia_carrier_t;
static const ia_carrier_t IA_CARRIERS[] = {
    {"US", "AT&T",       "310", "410"}, {"US", "T-Mobile",  "310", "260"}, {"US", "Verizon", "311", "480"},
    {"GB", "EE",         "234", "30"},  {"GB", "Vodafone",  "234", "15"},
    {"JP", "NTT DOCOMO", "440", "10"},  {"JP", "SoftBank",  "440", "20"},
    {"VN", "Viettel",    "452", "04"},  {"VN", "Vinaphone", "452", "02"},
};
#define IA_CARRIERS_N (sizeof(IA_CARRIERS) / sizeof(IA_CARRIERS[0]))

int profilestore_random_global(char *out_json, size_t out_json_len) {
    @autoreleasepool {
        const ia_prof_t *p = &IA_CATALOG[arc4random_uniform((uint32_t)IA_CATALOG_N)];
        // Region từ locale ("en_US" → "US"); fallback "US".
        NSString *region = @"US";
        NSArray *lp = [[@(p->locale) stringByReplacingOccurrencesOfString:@"-" withString:@"_"] componentsSeparatedByString:@"_"];
        if (lp.count >= 2 && [lp[1] length]) region = [lp[1] uppercaseString];
        // Carrier khớp region (random trong nhóm); không có → carrier bất kỳ.
        const ia_carrier_t *cands[IA_CARRIERS_N]; int nc = 0;
        for (size_t i = 0; i < IA_CARRIERS_N; i++)
            if ([region isEqualToString:@(IA_CARRIERS[i].region)]) cands[nc++] = &IA_CARRIERS[i];
        const ia_carrier_t *car = nc ? cands[arc4random_uniform((uint32_t)nc)]
                                     : &IA_CARRIERS[arc4random_uniform((uint32_t)IA_CARRIERS_N)];

        NSMutableDictionary *root = load_root();
        NSMutableDictionary *g = global_of(root);
        g[@"deviceModel"]        = @(p->model);
        g[@"hardwareIdentifier"] = @(p->hwid);
        g[@"systemName"]         = @"iOS";
        g[@"systemVersion"]      = @(p->ios);
        g[@"deviceName"]         = @"iPhone";
        g[@"localeIdentifier"]   = @(p->locale);
        g[@"timezoneIdentifier"] = @(p->tz);
        g[@"regionCode"]         = region;
        g[@"carrierName"]        = @(car->name);
        g[@"carrierMCC"]         = @(car->mcc);
        g[@"carrierMNC"]         = @(car->mnc);
        if (!save_root(root)) return 2;
        log_msg("profilestore: random global → %s / iOS %s / %s / %s", p->model, p->ios, [region UTF8String], car->name);
        if (out_json && out_json_len)
            snprintf(out_json, out_json_len,
                "{\"deviceModel\":\"%s\",\"hardwareIdentifier\":\"%s\",\"systemVersion\":\"%s\","
                "\"timezoneIdentifier\":\"%s\",\"regionCode\":\"%s\",\"carrierName\":\"%s\"}",
                p->model, p->hwid, p->ios, p->tz, [region UTF8String], car->name);
        return 0;
    }
}

int profilestore_clear(const char *bundle_id) {
    @autoreleasepool {
        if (!bundle_id || !bundle_id[0]) { return profilestore_reset(); }
        NSMutableDictionary *root = load_root();
        [root removeObjectForKey:S(bundle_id)];
        NSMutableArray *t = root[@"_targets"];
        if ([t isKindOfClass:NSMutableArray.class]) [t removeObject:S(bundle_id)];
        return save_root(root) ? 0 : 2;
    }
}

size_t profilestore_list_json(char *out, size_t out_len) {
    @autoreleasepool {
        if (!out || out_len == 0) return 0;
        NSDictionary *root = load_root();
        // BẪY: dataWithJSONObject THROW NSException nếu dict chứa giá trị JSON-không-hợp-lệ
        // (NaN/Inf, kiểu lạ do file plist cũ/hỏng) → uncaught → SIGABRT giết daemon. Vì app gọi
        // route này SONG SONG với apps_all, crash cắt luôn apps_all → danh sách app rỗng. Chặn bằng
        // isValidJSONObject + @try/@catch: file xấu chỉ trả "{}", KHÔNG bao giờ crash.
        NSData *j = nil;
        @try {
            if ([NSJSONSerialization isValidJSONObject:root])
                j = [NSJSONSerialization dataWithJSONObject:root options:0 error:NULL];
        } @catch (NSException *e) {
            log_msg("profilestore_list: bỏ file gán hỏng (%s)", [[e reason] UTF8String] ?: "?");
            j = nil;
        }
        if (!j) { snprintf(out, out_len, "{}"); return strlen(out); }
        size_t n = j.length < out_len - 1 ? j.length : out_len - 1;
        memcpy(out, j.bytes, n);
        out[n] = '\0';
        return n;
    }
}
