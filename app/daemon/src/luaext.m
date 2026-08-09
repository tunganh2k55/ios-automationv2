// luaext.m — nhóm hàm Lua "mở rộng" chạy phía DAEMON (root), dựa trên Foundation:
//   base64 · JSON · HTTP(S) · proxy hệ thống · mở URL · thông tin thiết bị/mạng.
// Tách khỏi lua_bind.c (thuần C) vì cần Objective-C (NSJSONSerialization/NSURLSession/
// SystemConfiguration/LSApplicationWorkspace). Makefile tự biên dịch mọi src/*.m và link
// Foundation + SystemConfiguration → chỉ cần đăng ký hàm qua luaext_register().
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include <objc/message.h>
#include <dlfcn.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <arpa/inet.h>
#include <string.h>

#include "luaext.h"
#include "appctl.h"
#include "lslock.h"
#include "touch.h"
#include "lua.h"
#include "lauxlib.h"

// ============================================================================
//  base64
// ============================================================================
// convertBase64(chuỗi [, giải_mã=false]) → mã hoá base64 (mặc định), hoặc GIẢI mã nếu tham số 2 true.
// Trả chuỗi kết quả; khi giải mã lỗi → nil, thông báo.
static int l_convertBase64(lua_State *L) {
    size_t len; const char *s = luaL_checklstring(L, 1, &len);
    int decode = lua_toboolean(L, 2);
    @autoreleasepool {
        if (decode) {
            NSString *in = [[NSString alloc] initWithBytes:s length:len encoding:NSUTF8StringEncoding];
            NSData *d = in ? [[NSData alloc] initWithBase64EncodedString:in
                              options:NSDataBase64DecodingIgnoreUnknownCharacters] : nil;
            if (!d) { lua_pushnil(L); lua_pushstring(L, "base64 không hợp lệ"); return 2; }
            lua_pushlstring(L, (const char *)d.bytes, d.length);
            return 1;
        }
        NSData *d = [NSData dataWithBytes:s length:len];
        NSString *enc = [d base64EncodedStringWithOptions:0];
        lua_pushstring(L, enc.UTF8String ? enc.UTF8String : "");
        return 1;
    }
}

// ============================================================================
//  JSON  ⇄  bảng Lua  (qua NSJSONSerialization)
// ============================================================================
// Đẩy 1 object Foundation (từ NSJSON) lên stack Lua dưới dạng giá trị Lua tương ứng.
static void ns_to_lua(lua_State *L, id obj) {
    if (!obj || obj == (id)[NSNull null]) { lua_pushnil(L); return; }
    if ([obj isKindOfClass:[NSString class]]) { lua_pushstring(L, [obj UTF8String] ?: ""); return; }
    if ([obj isKindOfClass:[NSNumber class]]) {
        // true/false của JSON là CFBoolean (một dạng NSNumber) → đẩy thành boolean Lua.
        if (CFGetTypeID((__bridge CFTypeRef)obj) == CFBooleanGetTypeID()) { lua_pushboolean(L, [obj boolValue]); return; }
        double v = [obj doubleValue];
        if (v == (double)(long long)v) lua_pushinteger(L, (lua_Integer)(long long)v);
        else lua_pushnumber(L, v);
        return;
    }
    if ([obj isKindOfClass:[NSArray class]]) {
        lua_newtable(L);
        lua_Integer i = 1;
        for (id e in obj) { ns_to_lua(L, e); lua_rawseti(L, -2, i++); }
        return;
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        lua_newtable(L);
        for (id k in obj) {
            lua_pushstring(L, [[k description] UTF8String] ?: "");
            ns_to_lua(L, obj[k]);
            lua_settable(L, -3);
        }
        return;
    }
    lua_pushnil(L);
}

// Chuyển 1 giá trị Lua tại idx → object Foundation (để NSJSON mã hoá). Bảng có key 1..n liên tục
// → NSArray; ngược lại → NSDictionary (key ép về chuỗi). Trả nil-object là [NSNull null].
static id lua_to_ns(lua_State *L, int idx) {
    idx = lua_absindex(L, idx);
    switch (lua_type(L, idx)) {
        case LUA_TNIL:     return [NSNull null];
        case LUA_TBOOLEAN: return lua_toboolean(L, idx) ? @YES : @NO;
        case LUA_TNUMBER:
            if (lua_isinteger(L, idx)) return [NSNumber numberWithLongLong:(long long)lua_tointeger(L, idx)];
            return [NSNumber numberWithDouble:lua_tonumber(L, idx)];
        case LUA_TSTRING: {
            size_t l; const char *s = lua_tolstring(L, idx, &l);
            NSString *str = [[NSString alloc] initWithBytes:s length:l encoding:NSUTF8StringEncoding];
            return str ?: @"";
        }
        case LUA_TTABLE: {
            lua_len(L, idx);
            lua_Integer n = lua_tointeger(L, -1);
            lua_pop(L, 1);
            // Coi là MẢNG nếu số cặp = n và mọi key là số nguyên (1..n).
            BOOL isArray = (n > 0);
            if (isArray) {
                lua_Integer count = 0;
                lua_pushnil(L);
                while (lua_next(L, idx)) {
                    count++;
                    if (!lua_isinteger(L, -2)) isArray = NO;
                    lua_pop(L, 1);
                }
                if (count != n) isArray = NO;
            }
            if (isArray) {
                NSMutableArray *arr = [NSMutableArray arrayWithCapacity:(NSUInteger)n];
                for (lua_Integer i = 1; i <= n; i++) {
                    lua_rawgeti(L, idx, i);
                    id v = lua_to_ns(L, -1);
                    [arr addObject:(v ?: [NSNull null])];
                    lua_pop(L, 1);
                }
                return arr;
            }
            NSMutableDictionary *dict = [NSMutableDictionary dictionary];
            lua_pushnil(L);
            while (lua_next(L, idx)) {          // key ở -2, value ở -1
                NSString *key = nil;
                if (lua_type(L, -2) == LUA_TSTRING) {
                    size_t kl; const char *ks = lua_tolstring(L, -2, &kl);
                    key = [[NSString alloc] initWithBytes:ks length:kl encoding:NSUTF8StringEncoding];
                } else {
                    lua_pushvalue(L, -2);       // COPY key rồi mới tostring (tránh sửa key gốc → hỏng lua_next)
                    key = [NSString stringWithUTF8String:(lua_tostring(L, -1) ?: "")];
                    lua_pop(L, 1);
                }
                id v = lua_to_ns(L, -1);
                if (key) dict[key] = (v ?: [NSNull null]);
                lua_pop(L, 1);                  // bỏ value, giữ key cho lua_next
            }
            return dict;
        }
        default: return [NSNull null];
    }
}

// jsonDecode(chuỗi) → bảng/giá trị Lua (nil, lỗi nếu JSON sai).
static int l_jsonDecode(lua_State *L) {
    size_t len; const char *s = luaL_checklstring(L, 1, &len);
    @autoreleasepool {
        NSData *d = [NSData dataWithBytes:s length:len];
        NSError *err = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:d
                    options:NSJSONReadingAllowFragments error:&err];
        if (!obj) { lua_pushnil(L); lua_pushstring(L, err.localizedDescription.UTF8String ?: "JSON lỗi"); return 2; }
        ns_to_lua(L, obj);
        return 1;
    }
}

// jsonEncode(bảng [, đẹp=false]) → chuỗi JSON (nil, lỗi nếu không mã hoá được).
static int l_jsonEncode(lua_State *L) {
    luaL_checkany(L, 1);
    int pretty = lua_toboolean(L, 2);
    @autoreleasepool {
        id obj = lua_to_ns(L, 1);
        if (![NSJSONSerialization isValidJSONObject:obj]) {
            lua_pushnil(L); lua_pushstring(L, "giá trị không mã hoá JSON được (cần bảng/mảng)"); return 2;
        }
        NSError *err = nil;
        NSData *d = [NSJSONSerialization dataWithJSONObject:obj
                      options:(pretty ? NSJSONWritingPrettyPrinted : 0) error:&err];
        if (!d) { lua_pushnil(L); lua_pushstring(L, err.localizedDescription.UTF8String ?: "lỗi"); return 2; }
        lua_pushlstring(L, (const char *)d.bytes, d.length);
        return 1;
    }
}

// ============================================================================
//  HTTP(S)  (NSURLSession — đồng bộ trên luồng script)
// ============================================================================
// Proxy hiện đặt (setProxySystem) — httpGet/httpPost đi qua đây. nil = không proxy.
static NSString *g_proxy_host = nil;
static int g_proxy_port = 0;

// Thực hiện request ĐỒNG BỘ (chặn tới khi xong/timeout 30s). Trả nil nếu OK (điền *statusOut,*dataOut),
// hoặc NSString mô tả lỗi.
static NSString *http_do(NSString *method, NSString *url, NSData *body,
                         NSDictionary *headers, NSString *contentType,
                         int *statusOut, NSData **dataOut) {
    NSURL *u = [NSURL URLWithString:url];
    if (!u) return @"URL không hợp lệ";
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u
                                cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                timeoutInterval:30];
    req.HTTPMethod = method;
    if (body) req.HTTPBody = body;
    if (contentType) [req setValue:contentType forHTTPHeaderField:@"Content-Type"];
    if ([headers isKindOfClass:[NSDictionary class]])
        for (id k in headers) [req setValue:[headers[k] description] forHTTPHeaderField:[k description]];

    // Session RIÊNG mỗi request (KHÔNG sharedSession — nó cache proxy lúc tạo → proxy đặt runtime bị bỏ
    // qua). Đặt connectionProxyDictionary tường minh theo proxy đang set → httpGet đi ĐÚNG qua proxy.
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = 30;
    if (g_proxy_host.length && g_proxy_port > 0) {
        cfg.connectionProxyDictionary = @{
            @"HTTPEnable":  @1, @"HTTPProxy":  g_proxy_host, @"HTTPPort":  @(g_proxy_port),
            @"HTTPSEnable": @1, @"HTTPSProxy": g_proxy_host, @"HTTPSPort": @(g_proxy_port),
        };
    }
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSData *rdata = nil; __block NSHTTPURLResponse *resp = nil; __block NSError *rerr = nil;
    NSURLSessionDataTask *task = [session dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
            rdata = data;
            if ([r isKindOfClass:[NSHTTPURLResponse class]]) resp = (NSHTTPURLResponse *)r;
            rerr = e;
            dispatch_semaphore_signal(sem);
        }];
    [task resume];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    [session finishTasksAndInvalidate];

    if (rerr) return rerr.localizedDescription ?: @"lỗi mạng";
    if (statusOut) *statusOut = resp ? (int)resp.statusCode : 0;
    if (dataOut) *dataOut = rdata;
    return nil;
}

// httpGet(url [, headers]) → nội_dung, mã_trạng_thái  ·  hoặc nil, lỗi.
static int l_httpGet(lua_State *L) {
    const char *url = luaL_checkstring(L, 1);
    @autoreleasepool {
        id h = lua_istable(L, 2) ? lua_to_ns(L, 2) : nil;
        int status = 0; NSData *data = nil;
        NSString *err = http_do(@"GET", @(url), nil, h, nil, &status, &data);
        if (err) { lua_pushnil(L); lua_pushstring(L, err.UTF8String ?: "lỗi"); return 2; }
        lua_pushlstring(L, data ? (const char *)data.bytes : "", data ? data.length : 0);
        lua_pushinteger(L, status);
        return 2;
    }
}

// httpPost(url [, body [, contentType [, headers]]]) → nội_dung, mã_trạng_thái  ·  hoặc nil, lỗi.
static int l_httpPost(lua_State *L) {
    const char *url = luaL_checkstring(L, 1);
    size_t blen; const char *bdy = luaL_optlstring(L, 2, "", &blen);
    const char *ctype = luaL_optstring(L, 3, "application/x-www-form-urlencoded");
    @autoreleasepool {
        id h = lua_istable(L, 4) ? lua_to_ns(L, 4) : nil;
        NSData *body = [NSData dataWithBytes:bdy length:blen];
        int status = 0; NSData *data = nil;
        NSString *err = http_do(@"POST", @(url), body, h, @(ctype), &status, &data);
        if (err) { lua_pushnil(L); lua_pushstring(L, err.UTF8String ?: "lỗi"); return 2; }
        lua_pushlstring(L, data ? (const char *)data.bytes : "", data ? data.length : 0);
        lua_pushinteger(L, status);
        return 2;
    }
}

// ============================================================================
//  Proxy hệ thống  (SystemConfiguration — nạp động vì header iOS đánh dấu "prohibited")
// ============================================================================
// SystemConfiguration CÓ trên máy nhưng SDK iOS chặn gọi trực tiếp (__IOS_PROHIBITED) → dlopen/dlsym
// như các private framework khác. Tên key proxy dùng chuỗi cố định (giá trị thật của các hằng SC).
typedef const void *IASCPrefRef;
typedef const void *IASCStoreRef;
typedef IASCPrefRef  (*fn_pref_create)(CFAllocatorRef, CFStringRef, CFStringRef);
typedef Boolean      (*fn_pref_pathset)(IASCPrefRef, CFStringRef, CFDictionaryRef);
typedef Boolean      (*fn_pref_bool)(IASCPrefRef);
typedef IASCStoreRef (*fn_store_create)(CFAllocatorRef, CFStringRef, void *, void *);
typedef CFPropertyListRef (*fn_store_copy)(IASCStoreRef, CFStringRef);

static void *sc_handle(void) {
    static void *h = NULL; static int tried = 0;
    if (!tried) {
        tried = 1;
        h = dlopen("/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration", RTLD_LAZY);
    }
    return h;
}

// serviceID của service mạng ĐANG hoạt động (primary) — để đặt proxy đúng interface (Wi‑Fi/di động).
static NSString *primary_service_id(void) {
    void *h = sc_handle(); if (!h) return nil;
    fn_store_create create = (fn_store_create)dlsym(h, "SCDynamicStoreCreate");
    fn_store_copy  copyval = (fn_store_copy)dlsym(h, "SCDynamicStoreCopyValue");
    if (!create || !copyval) return nil;
    IASCStoreRef ds = create(NULL, CFSTR("iosauto"), NULL, NULL);
    if (!ds) return nil;
    NSDictionary *g = (__bridge_transfer NSDictionary *)copyval(ds, CFSTR("State:/Network/Global/IPv4"));
    CFRelease(ds);
    return [g[@"PrimaryService"] isKindOfClass:[NSString class]] ? g[@"PrimaryService"] : nil;
}

// Bật/tắt proxy HTTP+HTTPS trên service mạng primary. Trả true (1 giá trị) hoặc false + lỗi (2).
static int set_proxy(lua_State *L, BOOL enable, const char *host, int port) {
    @autoreleasepool {
        void *h = sc_handle();
        fn_pref_create  create  = h ? (fn_pref_create)dlsym(h,  "SCPreferencesCreate") : NULL;
        fn_pref_pathset pathset = h ? (fn_pref_pathset)dlsym(h, "SCPreferencesPathSetValue") : NULL;
        fn_pref_bool    commit  = h ? (fn_pref_bool)dlsym(h,    "SCPreferencesCommitChanges") : NULL;
        fn_pref_bool    apply   = h ? (fn_pref_bool)dlsym(h,    "SCPreferencesApplyChanges") : NULL;
        if (!create || !pathset || !commit || !apply) {
            lua_pushboolean(L, 0); lua_pushstring(L, "SystemConfiguration không khả dụng"); return 2;
        }
        IASCPrefRef prefs = create(NULL, CFSTR("iosauto-proxy"), NULL);
        if (!prefs) { lua_pushboolean(L, 0); lua_pushstring(L, "không mở được cấu hình mạng (cần root)"); return 2; }
        NSString *sid = primary_service_id();
        if (!sid) { CFRelease(prefs); lua_pushboolean(L, 0); lua_pushstring(L, "không tìm thấy service mạng đang hoạt động"); return 2; }

        NSMutableDictionary *px = [NSMutableDictionary dictionary];
        if (enable) {
            px[@"HTTPEnable"]  = @1;  px[@"HTTPProxy"]  = @(host);  px[@"HTTPPort"]  = @(port);
            px[@"HTTPSEnable"] = @1;  px[@"HTTPSProxy"] = @(host);  px[@"HTTPSPort"] = @(port);
        } else {
            px[@"HTTPEnable"] = @0;   px[@"HTTPSEnable"] = @0;
        }
        NSString *path = [NSString stringWithFormat:@"/NetworkServices/%@/Proxies", sid];
        Boolean ok  = pathset(prefs, (__bridge CFStringRef)path, (__bridge CFDictionaryRef)px);
        Boolean okc = ok  && commit(prefs);
        Boolean oka = okc && apply(prefs);
        CFRelease(prefs);
        if (!oka) { lua_pushboolean(L, 0); lua_pushstring(L, "áp dụng proxy thất bại"); return 2; }
        // Lưu để httpGet/httpPost của daemon cũng đi qua proxy này (đặt connectionProxyDictionary).
        if (enable) { g_proxy_host = @(host); g_proxy_port = port; }
        else        { g_proxy_host = nil;     g_proxy_port = 0; }
        lua_pushboolean(L, 1);
        return 1;
    }
}

// setProxySystem(host, port) — đặt proxy HTTP/HTTPS toàn máy (mọi app đi qua host:port).
static int l_setProxySystem(lua_State *L) {
    const char *host = luaL_checkstring(L, 1);
    int port = (int)luaL_checkinteger(L, 2);
    return set_proxy(L, YES, host, port);
}
// clearProxySystem() — tắt proxy hệ thống (về "Tắt").
static int l_clearProxySystem(lua_State *L) {
    return set_proxy(L, NO, NULL, 0);
}

// ============================================================================
//  Mở URL / thông tin thiết bị & mạng
// ============================================================================
// openUrl(url) → true nếu gửi mở được (qua LSApplicationWorkspace, không cần app foreground).
static int l_openUrl(lua_State *L) {
    const char *url = luaL_checkstring(L, 1);
    @autoreleasepool {
        // Nạp LaunchServices để có LSApplicationWorkspace (giống appctl.m).
        dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY);
        dlopen("/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
        NSURL *u = [NSURL URLWithString:@(url)];
        if (!u) { lua_pushboolean(L, 0); return 1; }
        Class WS = NSClassFromString(@"LSApplicationWorkspace");
        BOOL ok = NO;
        // LSApplicationWorkspace KHÔNG thread-safe — openURL: chạy trên luồng Lua có thể ĐỒNG THỜI với
        // /api/apps_all (list_json trên luồng HTTP) → race LS/XPC → daemon SIGKILL. Serialize bằng khoá
        // LS DÙNG CHUNG (ia_ls_lock, cùng mutex với appctl.m/crane.m).
        ia_ls_lock();
        @try {
            id ws = (WS && [WS respondsToSelector:@selector(defaultWorkspace)])
                    ? [WS performSelector:@selector(defaultWorkspace)] : nil;
            if (ws && [ws respondsToSelector:@selector(openURL:)])
                ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, @selector(openURL:), u);
        } @catch (__unused NSException *e) { ok = NO; }
        ia_ls_unlock();
        lua_pushboolean(L, ok);
        return 1;
    }
}

// getDeviceInfo() → bảng {name, model, ios, screenW, screenH}.
static int l_getDeviceInfo(lua_State *L) {
    char name[128] = {0}, model[64] = {0}, ios[32] = {0};
    appctl_device_info(name, sizeof(name), model, sizeof(model), ios, sizeof(ios));
    int w = 0, h = 0; touch_screen_size(&w, &h);
    lua_newtable(L);
    lua_pushstring(L, name);   lua_setfield(L, -2, "name");
    lua_pushstring(L, model);  lua_setfield(L, -2, "model");
    lua_pushstring(L, ios);    lua_setfield(L, -2, "ios");
    lua_pushinteger(L, w);     lua_setfield(L, -2, "screenW");
    lua_pushinteger(L, h);     lua_setfield(L, -2, "screenH");
    return 1;
}

// getLocalIp() → IPv4 nội bộ (ưu tiên en0/Wi‑Fi) · nil, lỗi nếu không có.
static int l_getLocalIp(lua_State *L) {
    struct ifaddrs *ifs = NULL;
    char best[64] = "";
    if (getifaddrs(&ifs) == 0) {
        for (struct ifaddrs *ifa = ifs; ifa; ifa = ifa->ifa_next) {
            if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) continue;
            if (!(ifa->ifa_flags & IFF_UP) || (ifa->ifa_flags & IFF_LOOPBACK)) continue;
            char ip[64];
            struct sockaddr_in *sa = (struct sockaddr_in *)ifa->ifa_addr;
            if (!inet_ntop(AF_INET, &sa->sin_addr, ip, sizeof(ip))) continue;
            if (strcmp(ifa->ifa_name, "en0") == 0) { snprintf(best, sizeof(best), "%s", ip); break; }
            if (!best[0]) snprintf(best, sizeof(best), "%s", ip);   // dự phòng interface khác
        }
        freeifaddrs(ifs);
    }
    if (best[0]) { lua_pushstring(L, best); return 1; }
    lua_pushnil(L); lua_pushstring(L, "không tìm thấy IP nội bộ"); return 2;
}

// getPublicIp() → IP công cộng (gọi https://api.ipify.org) · nil, lỗi.
static int l_getPublicIp(lua_State *L) {
    @autoreleasepool {
        int status = 0; NSData *data = nil;
        NSString *err = http_do(@"GET", @"https://api.ipify.org", nil, nil, nil, &status, &data);
        if (err || !data) { lua_pushnil(L); lua_pushstring(L, err.UTF8String ?: "lỗi"); return 2; }
        NSString *ip = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        lua_pushstring(L, ip.UTF8String ?: "");
        return 1;
    }
}

void luaext_register(struct lua_State *L) {
    lua_register(L, "convertBase64",    l_convertBase64);
    lua_register(L, "jsonDecode",       l_jsonDecode);
    lua_register(L, "jsonEncode",       l_jsonEncode);
    lua_register(L, "httpGet",          l_httpGet);
    lua_register(L, "httpPost",         l_httpPost);
    lua_register(L, "setProxySystem",   l_setProxySystem);
    lua_register(L, "clearProxySystem", l_clearProxySystem);
    lua_register(L, "openUrl",          l_openUrl);
    lua_register(L, "getDeviceInfo",    l_getDeviceInfo);
    lua_register(L, "getLocalIp",       l_getLocalIp);
    lua_register(L, "getPublicIp",      l_getPublicIp);
}
