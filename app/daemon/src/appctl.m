#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <Security/Security.h>   // SecItem* — xoá keychain của app (clearAppData #1)
#import <objc/runtime.h>
#include <notify.h>
#include "appctl.h"
#include "touch.h"   // touch_airplane — bật/tắt sóng thật qua tweak SpringBoard
#include "log.h"
#include <dlfcn.h>
#include <spawn.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include "lslock.h"   // ia_ls_lock/unlock — serialize MỌI truy cập LaunchServices toàn daemon

// Tên thiết bị tuỳ chỉnh do người dùng đặt (từ app/web). Rỗng/không có → dùng hostname (bỏ .local).
#define DEVNAME_FILE "/var/jb/usr/local/iosauto/device_name"
static int devname_read_custom(char *out, size_t len) {
    if (!out || len == 0) return 0;
    FILE *f = fopen(DEVNAME_FILE, "rb");
    if (!f) return 0;
    size_t n = fread(out, 1, len - 1, f);
    fclose(f);
    out[n] = '\0';
    while (n > 0 && (unsigned char)out[n - 1] <= ' ') out[--n] = '\0';   // trim đuôi
    return n > 0;
}

// Tên do người dùng đặt trong Cài đặt → Cài đặt chung → Giới thiệu → Tên.
// Đọc THẲNG từ MobileGestalt (key "UserAssignedDeviceName") — phản ánh tên hiện tại ngay khi đổi,
// KHÔNG bị kẹt như NSProcessInfo.hostName (bị iOS cache, chỉ đổi sau respring). Trả 1 nếu lấy được.
static int devname_read_assigned(char *out, size_t len) {
    if (!out || len == 0) return 0;
    out[0] = '\0';
    @autoreleasepool {
        typedef CFTypeRef (*MGCopyAnswerFn)(CFStringRef);
        static MGCopyAnswerFn mg = NULL;
        static int tried = 0;
        if (!tried) {
            tried = 1;
            void *h = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
            if (h) mg = (MGCopyAnswerFn)dlsym(h, "MGCopyAnswer");
            if (!mg) log_msg("devname_read_assigned: không nạp được MGCopyAnswer");
        }
        if (!mg) return 0;
        int ok = 0;
        CFTypeRef v = mg(CFSTR("UserAssignedDeviceName"));
        if (v) {
            if (CFGetTypeID(v) == CFStringGetTypeID())
                ok = CFStringGetCString((CFStringRef)v, out, len, kCFStringEncodingUTF8);
            CFRelease(v);
        }
        size_t n = strlen(out);
        while (n > 0 && (unsigned char)out[n - 1] <= ' ') out[--n] = '\0';   // trim đuôi
        return ok && n > 0;
    }
}

// ---- SpringBoardServices: mở app ----
// int SBSLaunchApplicationWithIdentifier(CFStringRef id, Boolean suspended)
typedef int (*sbs_launch_fn)(CFStringRef, Boolean);

static void *sbs_handle(void) {
    static void *h = NULL;
    static int tried = 0;
    if (!tried) {
        tried = 1;
        h = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
    }
    return h;
}

int appctl_launch(const char *bundle_id, char *err, size_t err_len) {
    if (!bundle_id || !bundle_id[0]) { snprintf(err, err_len, "thiếu bundleId"); return 1; }
    void *h = sbs_handle();
    if (!h) { snprintf(err, err_len, "không nạp được SpringBoardServices"); return 2; }
    sbs_launch_fn f = (sbs_launch_fn)dlsym(h, "SBSLaunchApplicationWithIdentifier");
    if (!f) { snprintf(err, err_len, "không tìm thấy SBSLaunchApplicationWithIdentifier"); return 3; }

    @autoreleasepool {
        CFStringRef cid = CFStringCreateWithCString(NULL, bundle_id, kCFStringEncodingUTF8);
        // Serialize cùng khoá LS: launch (SBS) hay chạy đồng thời openUrl (LS)/apps_all lúc reg
        // (ensureSafari gọi launch) → tránh race framework mở-app.
        ia_ls_lock();
        int rc = f(cid, false);
        ia_ls_unlock();
        if (cid) CFRelease(cid);
        // rc==0 khi màn hình mở; rc==3 thường do màn hình đang khoá.
        if (rc == 0) { snprintf(err, err_len, "ok"); return 0; }
        if (rc == 3) { snprintf(err, err_len, "màn hình đang khoá (mở khoá rồi thử lại)"); return 0; }
        snprintf(err, err_len, "SBS rc=%d", rc);
        return rc ? 10 : 0;
    }
}

// ---- LSApplicationProxy: đóng app + liệt kê ----
static void ensure_ls_loaded(void) {
    static int done = 0;
    if (done) return;
    done = 1;
    // Nạp framework để có class LSApplicationProxy / LSApplicationWorkspace.
    dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY);
    dlopen("/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
}

// Lấy tên file thực thi của app (để killall). Trả nil nếu không có. Khoá g_ls_mu (LS không thread-safe).
static NSString *executable_name_for(NSString *bundleId) {
    ensure_ls_loaded();
    Class LSApplicationProxy = NSClassFromString(@"LSApplicationProxy");
    if (!LSApplicationProxy) return nil;
    if (![LSApplicationProxy respondsToSelector:@selector(applicationProxyForIdentifier:)]) return nil;

    NSString *result = nil;
    ia_ls_lock();
    @try {
        id proxy = [LSApplicationProxy performSelector:@selector(applicationProxyForIdentifier:)
                                            withObject:bundleId];
        // QUAN TRỌNG: selector đúng là executableURL (KHÔNG phải executablePath —
        // sai selector → doesNotRecognizeSelector → SIGABRT crash daemon).
        if (proxy && [proxy respondsToSelector:@selector(executableURL)]) {
            NSURL *url = [proxy performSelector:@selector(executableURL)];
            if ([url isKindOfClass:[NSURL class]]) result = [[url path] lastPathComponent];
        }
    } @catch (NSException *e) {
        log_msg("kill: exception %s", [[e reason] UTF8String] ?: "?");
    }
    ia_ls_unlock();
    return result;
}

// Gửi 1 tín hiệu (sig, vd "-9" hoặc "-0") tới mọi tiến trình tên `exe` qua killall.
// Trả EXIT của killall: 0 = có tiến trình khớp (đã signal / còn sống với -0); !=0 = không có.
// -1 = không chạy được killall.
static int killall_signal(const char *exe, const char *sig) {
    const char *paths[] = { "/var/jb/usr/bin/killall", "/usr/bin/killall", "killall" };
    for (size_t i = 0; i < sizeof(paths)/sizeof(paths[0]); i++) {
        char *const argv[] = { (char *)paths[i], (char *)sig, (char *)exe, NULL };
        pid_t pid;
        if (posix_spawnp(&pid, paths[i], NULL, NULL, argv, NULL) == 0) {
            int st = 0; waitpid(pid, &st, 0);
            return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
        }
    }
    return -1;
}

// Kill CỨNG (SIGKILL) + ĐỢI tiến trình chết hẳn (tối đa ~2s) trước khi ta xoá dữ liệu.
// Vì sao KHÔNG dùng SIGTERM: app (nhất là Safari) bắt SIGTERM → chạy applicationWillTerminate
// → GHI LẠI trạng thái (BrowserState.db = tab+lịch sử) NGAY lúc thoát → ghi đè lên phần ta vừa
// xoá → tab/lịch sử "sống lại". SIGKILL không cho app chạy handler nên không ghi lại. Đợi chết
// hẳn để chắc không còn tiến trình giữ file/ghi thêm khi ta bắt đầu removeItem.
static void kill_hard_wait(NSString *bundleId) {
    NSString *exe = executable_name_for(bundleId);
    if (!exe.length) return;
    const char *e = exe.UTF8String;
    killall_signal(e, "-9");
    for (int i = 0; i < 20; i++) {              // ~2s: 20 × 100ms
        if (killall_signal(e, "-0") != 0) return;   // !=0 → không còn tiến trình → xong
        usleep(100 * 1000);
        killall_signal(e, "-9");                // còn sống → nện tiếp
    }
}

int appctl_kill(const char *bundle_id, char *err, size_t err_len) {
    if (!bundle_id || !bundle_id[0]) { snprintf(err, err_len, "thiếu bundleId"); return 1; }
    @autoreleasepool {
        NSString *bid = [NSString stringWithUTF8String:bundle_id];
        NSString *exe = executable_name_for(bid);
        if (!exe || exe.length == 0) { snprintf(err, err_len, "không tìm thấy executable của app"); return 2; }

        const char *killall_paths[] = {
            "/var/jb/usr/bin/killall", "/usr/bin/killall", "killall"
        };
        char exe_c[256];
        strncpy(exe_c, [exe UTF8String], sizeof(exe_c) - 1);
        exe_c[sizeof(exe_c) - 1] = '\0';

        for (size_t i = 0; i < sizeof(killall_paths) / sizeof(killall_paths[0]); i++) {
            char *const argv[] = { (char *)killall_paths[i], exe_c, NULL };
            pid_t pid;
            int rc = posix_spawnp(&pid, killall_paths[i], NULL, NULL, argv, NULL);
            if (rc == 0) {
                int st;
                waitpid(pid, &st, 0);
                snprintf(err, err_len, "killall %s", exe_c);
                return 0;
            }
        }
        snprintf(err, err_len, "không chạy được killall");
        return 3;
    }
}

// Đường dẫn data-container (thư mục dữ liệu ĐANG DÙNG của app) qua LSApplicationProxy.dataContainerURL.
static NSString *data_container_for(NSString *bundleId) {
    ensure_ls_loaded();
    Class P = NSClassFromString(@"LSApplicationProxy");
    if (!P || ![P respondsToSelector:@selector(applicationProxyForIdentifier:)]) return nil;
    NSString *result = nil;
    ia_ls_lock();
    @try {
        id proxy = [P performSelector:@selector(applicationProxyForIdentifier:) withObject:bundleId];
        if (proxy && [proxy respondsToSelector:@selector(dataContainerURL)]) {
            NSURL *u = [proxy performSelector:@selector(dataContainerURL)];
            if ([u isKindOfClass:[NSURL class]]) result = [u path];
        }
    } @catch (NSException *e) { log_msg("cleardata: proxy exception %s", [[e reason] UTF8String] ?: "?"); }
    ia_ls_unlock();
    return result;
}

// Safari (system app) KHÔNG lưu tab/lịch sử/cookie trong data-container mà ở HOME user "mobile".
// clearAppData chỉ xoá container → tab CŨ còn nguyên (BrowserState.db). Hàm này xoá tận gốc các nơi
// thật: Library/Safari (tab đang mở, lịch sử, thumbnail…), Caches, WebKit, và cookie dùng chung.
// XOÁ NỘI DUNG thư mục (giữ lại thư mục cha, thuộc mobile) để Safari mở lại tự dựng mới, tránh lệch
// quyền (daemon chạy root: nếu tự tạo lại thư mục sẽ thành root, Safari-mobile ghi không được).
static int clear_safari_system_data(char *diag, size_t dlen) {
    NSFileManager *fm = [NSFileManager defaultManager];
    int n = 0;
    size_t o = 0;
    if (diag && dlen) diag[0] = '\0';
    NSArray *dirs = @[
        @"/var/mobile/Library/Safari",                          // BrowserState.db = tab đang mở + lịch sử, bookmark, thumbnails
        @"/var/mobile/Library/Caches/com.apple.mobilesafari",
        @"/var/mobile/Library/Caches/com.apple.WebKit.WebContent",
        @"/var/mobile/Library/Caches/com.apple.WebKit.Networking",
        @"/var/mobile/Library/WebKit/com.apple.mobilesafari",
    ];
    for (NSString *dir in dirs) {
        BOOL isdir = NO;
        BOOL exists = [fm fileExistsAtPath:dir isDirectory:&isdir];
        NSError *lerr = nil;
        NSArray *subs = exists ? [fm contentsOfDirectoryAtPath:dir error:&lerr] : nil;
        int got = (int)subs.count, del = 0;
        NSString *firstErr = lerr ? [lerr localizedDescription] : nil;
        for (NSString *sub in subs) {
            NSError *rerr = nil;
            if ([fm removeItemAtPath:[dir stringByAppendingPathComponent:sub] error:&rerr]) del++;
            else if (!firstErr) firstErr = [rerr localizedDescription] ?: @"?";
        }
        n += del;
        // breakdown gọn cho panel: <tên>:del/got[!lỗi]  hoặc  <tên>:X (thiếu thư mục)
        const char *tag = [[dir lastPathComponent] UTF8String];
        if (diag && o < dlen) {
            if (!exists)
                o += snprintf(diag + o, dlen - o, "%s%s:X", o ? " " : "", tag);
            else
                o += snprintf(diag + o, dlen - o, "%s%s:%d/%d%s%s", o ? " " : "", tag, del, got,
                              firstErr ? "!" : "", firstErr ? [firstErr UTF8String] : "");
        }
        log_msg("cleardata safari %s: exists=%d got=%d del=%d err=%s",
                [dir UTF8String], exists, got, del, firstErr ? [firstErr UTF8String] : "-");
    }
    // Cookie/HSTS dùng chung — xoá đúng FILE (không xoá cả thư mục Cookies để không đụng app khác).
    NSArray *files = @[
        @"/var/mobile/Library/Cookies/Cookies.binarycookies",
        @"/var/mobile/Library/Cookies/com.apple.mobilesafari.binarycookies",
        @"/var/mobile/Library/Cookies/HSTS.plist",
    ];
    for (NSString *f in files) {
        if (![fm fileExistsAtPath:f]) continue;
        NSError *rerr = nil;
        if ([fm removeItemAtPath:f error:&rerr]) n++;
        else log_msg("cleardata safari file %s err=%s", [f UTF8String],
                     [[rerr localizedDescription] UTF8String] ?: "?");
    }
    log_msg("cleardata safari: xoá thêm %d mục ngoài container (tab/lịch sử/cookie)", n);
    return n;
}

// clearAppData #1: xoá KEYCHAIN của app. Token đăng nhập (OAuth, session) lưu ở keychain —
// NẰM NGOÀI data-container nên xoá container xong app native vẫn còn login. Duyệt mọi lớp item,
// so khớp access-group với bundleId rồi xoá theo persistent-ref.
// Cần entitlement keychain-access-groups="*" (xem entitlements.plist) để securityd cho daemon
// nhìn thấy item của app khác; không có thì SecItemCopyMatching chỉ trả item của chính daemon.
// KHÔNG xoá item ở group DÙNG CHUNG (vd "<Team>.com.apple.token"): chỉ khớp access-group ==
// bundleId hoặc kết thúc bằng ".<bundleId>" (group riêng "<TeamID>.<bundleId>") → không đụng app khác.
static int clear_app_keychain(NSString *bundleId) {
    int n = 0;
    CFTypeRef classes[] = { kSecClassGenericPassword, kSecClassInternetPassword,
                            kSecClassCertificate, kSecClassKey, kSecClassIdentity };
    NSString *dotBid = [@"." stringByAppendingString:bundleId];
    for (int i = 0; i < 5; i++) {
        NSDictionary *q = @{
            (__bridge id)kSecClass:               (__bridge id)classes[i],
            (__bridge id)kSecReturnAttributes:    @YES,
            (__bridge id)kSecReturnPersistentRef: @YES,
            (__bridge id)kSecMatchLimit:          (__bridge id)kSecMatchLimitAll,
            (__bridge id)kSecAttrSynchronizable:  (__bridge id)kSecAttrSynchronizableAny, // cả item iCloud
        };
        CFTypeRef res = NULL;
        OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)q, &res);
        if (st != errSecSuccess || !res) { if (res) CFRelease(res); continue; }
        NSArray *items = (__bridge_transfer NSArray *)res;
        for (NSDictionary *it in items) {
            NSString *ag = it[(__bridge id)kSecAttrAccessGroup];
            if (![ag isKindOfClass:[NSString class]]) continue;
            if (!([ag isEqualToString:bundleId] || [ag hasSuffix:dotBid])) continue; // chỉ group RIÊNG của app
            id pref = it[(__bridge id)kSecValuePersistentRef];
            if (!pref) continue;
            NSDictionary *del = @{ (__bridge id)kSecValuePersistentRef: pref };
            if (SecItemDelete((__bridge CFDictionaryRef)del) == errSecSuccess) n++;
        }
    }
    log_msg("cleardata keychain %s: xoá %d item", [bundleId UTF8String], n);
    return n;
}

// clearAppData #2: xoá nội dung các APP-GROUP / SHARED container của app
// (/var/mobile/Containers/Shared/AppGroup/<uuid>). App dùng extension/widget/app-group share
// login-data qua đây → container riêng sạch mà group còn thì vẫn dính. Lấy danh sách group ĐÚNG
// của app qua LSApplicationProxy.groupContainerURLs (map groupId→URL). GIỮ thư mục group (thuộc
// mobile) + metadata plist, chỉ xoá nội dung — tránh lệch quyền như phần Safari.
static int clear_app_group_data(NSString *bundleId, int *cleared_groups) {
    ensure_ls_loaded();
    Class P = NSClassFromString(@"LSApplicationProxy");
    if (!P || ![P respondsToSelector:@selector(applicationProxyForIdentifier:)]) return 0;
    NSFileManager *fm = [NSFileManager defaultManager];
    int n = 0, g = 0;
    ia_ls_lock();
    @try {
        id proxy = [P performSelector:@selector(applicationProxyForIdentifier:) withObject:bundleId];
        if (proxy && [proxy respondsToSelector:@selector(groupContainerURLs)]) {
            NSDictionary *groups = [proxy performSelector:@selector(groupContainerURLs)];
            if ([groups isKindOfClass:[NSDictionary class]]) {
                for (id key in groups) {
                    NSURL *u = groups[key];
                    NSString *gdir = [u isKindOfClass:[NSURL class]] ? [u path] : nil;
                    if (!gdir.length) continue;
                    g++;
                    for (NSString *sub in [fm contentsOfDirectoryAtPath:gdir error:NULL]) {
                        if ([sub isEqualToString:@".com.apple.mobile_container_manager.metadata.plist"]) continue;
                        if ([fm removeItemAtPath:[gdir stringByAppendingPathComponent:sub] error:NULL]) n++;
                    }
                }
            }
        }
    } @catch (NSException *e) { log_msg("cleardata appgroup: exception %s", [[e reason] UTF8String] ?: "?"); }
    ia_ls_unlock();
    if (cleared_groups) *cleared_groups = g;
    if (g) log_msg("cleardata appgroup %s: xoá %d mục trong %d group", [bundleId UTF8String], n, g);
    return n;
}

int appctl_clear_data(const char *bundle_id, int *removed, char *err, size_t err_len) {
    if (removed) *removed = 0;
    if (!bundle_id || !bundle_id[0]) { snprintf(err, err_len, "thiếu bundleId"); return 1; }
    @autoreleasepool {
        NSString *bid = [NSString stringWithUTF8String:bundle_id];
        NSString *dir = data_container_for(bid);
        if (!dir || dir.length == 0) { snprintf(err, err_len, "app chưa cài hoặc không lấy được data-container"); return 2; }

        // Kill CỨNG (SIGKILL) + đợi chết hẳn — tránh app bắt SIGTERM rồi GHI LẠI trạng thái
        // (Safari: BrowserState.db tab/lịch sử) ĐÈ lên phần ta vừa xoá. Xem kill_hard_wait.
        kill_hard_wait(bid);

        NSFileManager *fm = [NSFileManager defaultManager];
        NSError *e = nil;
        NSArray *items = [fm contentsOfDirectoryAtPath:dir error:&e];
        if (!items) { snprintf(err, err_len, "đọc container lỗi: %s", [[e localizedDescription] UTF8String] ?: "?"); return 3; }
        int n = 0;
        for (NSString *name in items) {
            // GIỮ metadata container (định danh) — xoá là hỏng đăng ký container.
            if ([name isEqualToString:@".com.apple.mobile_container_manager.metadata.plist"]) continue;
            NSString *full = [dir stringByAppendingPathComponent:name];
            if ([fm removeItemAtPath:full error:NULL]) n++;
        }
        // Safari: tab/lịch sử/cookie nằm NGOÀI container (ở HOME mobile) → xoá thêm mới sạch tab cũ.
        char sdiag[512] = {0};
        BOOL isSafari = [bid isEqualToString:@"com.apple.mobilesafari"];
        if (isSafari)
            n += clear_safari_system_data(sdiag, sizeof(sdiag));
        // #1 keychain + #2 app-group: token/login của app native nằm NGOÀI data-container → xoá thêm
        // để reset sạch như mới cài (Safari reg web không dính nhưng vô hại).
        n += clear_app_keychain(bid);
        n += clear_app_group_data(bid, NULL);
        // Tạo lại thư mục chuẩn để app mở lại không bơ vơ.
        for (NSString *s in @[@"Documents", @"Library", @"Library/Caches", @"Library/Preferences", @"tmp"])
            [fm createDirectoryAtPath:[dir stringByAppendingPathComponent:s] withIntermediateDirectories:YES attributes:nil error:NULL];

        if (removed) *removed = n;
        log_msg("cleardata %s: đã xoá %d mục trong %s", bundle_id, n, [dir UTF8String]);
        if (isSafari) snprintf(err, err_len, "%d mục [%s]", n, sdiag);   // breakdown ra panel để chẩn đoán
        else          snprintf(err, err_len, "đã xoá %d mục", n);
        return 0;
    }
}

// include_system=0: CHỈ app "User" (do người dùng cài). include_system=1: thêm app "System"
// (Safari, App Store, Cài đặt…). Bỏ Internal/Hidden/PluginKit (không phải app mở được, gây nhiễu).
static size_t list_json_impl(char *out, size_t out_len, int include_system) {
    ensure_ls_loaded();
    size_t o = 0;
    out[o++] = '[';
    // Serialize toàn bộ đợt duyệt LS — nhiều /api/apps_all song song mà đọc LS đồng thời → race → SIGSEGV.
    ia_ls_lock();
    @autoreleasepool {
        Class WS = NSClassFromString(@"LSApplicationWorkspace");
        id ws = nil;
        if (WS && [WS respondsToSelector:@selector(defaultWorkspace)])
            ws = [WS performSelector:@selector(defaultWorkspace)];
        if (ws && [ws respondsToSelector:@selector(allApplications)]) {
            @try {
                NSArray *apps = [ws performSelector:@selector(allApplications)];
                int n = 0;
                for (id proxy in apps) {
                    NSString *bid = [proxy respondsToSelector:@selector(applicationIdentifier)]
                                    ? [proxy performSelector:@selector(applicationIdentifier)] : nil;
                    NSString *name = [proxy respondsToSelector:@selector(localizedName)]
                                     ? [proxy performSelector:@selector(localizedName)] : bid;
                    if (!bid) continue;
                    NSString *atype = [proxy respondsToSelector:@selector(applicationType)]
                                      ? [proxy performSelector:@selector(applicationType)] : nil;
                    if (include_system) {
                        // Lấy MỌI app trừ plugin/ẩn (không mở được). KHÔNG lệ thuộc applicationType
                        // trả đúng "User"/"System" — trên vài máy type trả nil → nếu lọc cứng sẽ RỖNG.
                        if ([atype isEqualToString:@"PluginKit"] || [atype isEqualToString:@"Hidden"]) continue;
                        if (!name.length) continue;
                    } else {
                        // /api/apps (web launcher): giữ hành vi cũ — chỉ app User.
                        if (![atype isEqualToString:@"User"]) continue;
                    }
                    char item[600];
                    int m = snprintf(item, sizeof(item), "%s{\"bundleId\":\"%s\",\"name\":\"%s\",\"type\":\"%s\"}",
                                     n ? "," : "",
                                     [bid UTF8String] ?: "",
                                     [(name ?: bid) UTF8String] ?: "",
                                     [(atype ?: @"") UTF8String] ?: "");
                    if (o + (size_t)m + 2 >= out_len) break;
                    memcpy(out + o, item, (size_t)m); o += (size_t)m;
                    n++;
                }
            } @catch (NSException *e) {
                log_msg("list apps: exception %s", [[e reason] UTF8String] ?: "?");
            }
        }
    }
    ia_ls_unlock();
    if (o + 1 < out_len) out[o++] = ']';
    out[o] = '\0';
    return o;
}

// CHỈ app "User" — dùng cho web UI launcher (giữ payload nhỏ). Xem list_json_impl.
size_t appctl_list_json(char *out, size_t out_len) {
    return list_json_impl(out, out_len, 0);
}

// User + System — dùng cho tab Profiles (chọn app để spoof, gồm Safari…).
size_t appctl_list_all_json(char *out, size_t out_len) {
    return list_json_impl(out, out_len, 1);
}

void appctl_device_info(char *name, size_t name_len,
                        char *model, size_t model_len,
                        char *ios, size_t ios_len) {
    // model: hw.machine
    if (model && model_len) {
        size_t sz = model_len;
        if (sysctlbyname("hw.machine", model, &sz, NULL, 0) != 0)
            snprintf(model, model_len, "iPhone");
    }
    @autoreleasepool {
        NSProcessInfo *pi = [NSProcessInfo processInfo];
        if (ios && ios_len) {
            NSOperatingSystemVersion v = pi.operatingSystemVersion;
            snprintf(ios, ios_len, "%ld.%ld.%ld",
                     (long)v.majorVersion, (long)v.minorVersion, (long)v.patchVersion);
        }
        if (name && name_len) {
            char custom[128];
            if (devname_read_custom(custom, sizeof(custom))) {
                snprintf(name, name_len, "%s", custom);       // 1) override thủ công đặt trong app iOSAuto
            } else if (devname_read_assigned(name, name_len)) {
                // 2) tên thật ở Cài đặt → Giới thiệu → Tên (MobileGestalt) — đã ghi thẳng vào name
            } else {
                const char *hn = [[pi hostName] UTF8String];   // 3) fallback hostname
                snprintf(name, name_len, "%s", hn ? hn : "iPhone");
                size_t l = strlen(name);                       // bỏ đuôi ".local" (vd "SE2.local" → "SE2")
                if (l > 6 && strcmp(name + l - 6, ".local") == 0) name[l - 6] = '\0';
            }
        }
    }
}

// Serial number thiết bị. Lấy qua MobileGestalt MGCopyAnswer("SerialNumber") — API riêng,
// nạp động bằng dlopen/dlsym (daemon chạy root + có platform-application nên đọc được).
// Ghi vào out (rỗng nếu không lấy được, ví dụ bị sandbox chặn).
void appctl_serial(char *out, size_t out_len) {
    if (!out || out_len == 0) return;
    out[0] = '\0';
    @autoreleasepool {
        typedef CFTypeRef (*MGCopyAnswerFn)(CFStringRef);
        static MGCopyAnswerFn mg = NULL;
        static int tried = 0;
        if (!tried) {
            tried = 1;
            void *h = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
            if (h) mg = (MGCopyAnswerFn)dlsym(h, "MGCopyAnswer");
            if (!mg) log_msg("appctl_serial: không nạp được MGCopyAnswer");
        }
        if (mg) {
            CFTypeRef v = mg(CFSTR("SerialNumber"));
            if (v) {
                if (CFGetTypeID(v) == CFStringGetTypeID())
                    CFStringGetCString((CFStringRef)v, out, out_len, kCFStringEncodingUTF8);
                CFRelease(v);
            }
        }
    }
}

// Bật/tắt Airplane Mode. on != 0 = BẬT airplane (ngắt 4G); on == 0 = TẮT (bật lại 4G). Trả 0 = OK.
//
// FIX TRIỆT ĐỂ (0.7.83): 0.7.82 gọi RadiosPreferences + ghi CFPreferences + notify_post NGAY TRONG
// daemon ROOT — chỉ GHI PLIST, KHÔNG cắt sóng thật (RadiosPreferences chỉ là chủ radio KHI chạy trong
// tiến trình SpringBoard; notify name cũng không phải cái SpringBoard nghe). Triệu chứng: "máy bay vẫn
// chưa bật", IP 4G không đổi. Cách đúng: NHỜ tweak đã inject trong SpringBoard gọi setAirplaneMode:
// (đúng đường Cài đặt dùng) qua verb AIRPLANE — cắt/bật sóng THẬT. CFPreferences chỉ giữ lại như lớp
// bọc best-effort (đồng bộ hiển thị) nếu tweak SpringBoard không có mặt.
int appctl_set_airplane(int on, char *err, size_t err_len) {
    @autoreleasepool {
        // (1) ĐƯỜNG CHÍNH: nhờ tweak SpringBoard bật/tắt sóng thật. Trả 0 nếu tweak "OK …".
        char t_err[256] = {0};
        int rc = touch_airplane(on, t_err, sizeof(t_err));
        if (rc == 0) {
            log_msg("appctl_set_airplane: %s qua SpringBoard OK (%s)", on ? "ON" : "OFF", t_err);
            if (err && err_len) snprintf(err, err_len, "%s", t_err);
            return 0;
        }
        // (2) DỰ PHÒNG: SpringBoard chưa inject tweak → ghi plist best-effort (không cắt sóng nhưng
        //     đồng bộ hiển thị) rồi báo lỗi để script biết đường chính thất bại.
        log_msg("appctl_set_airplane: SpringBoard route lỗi (%s) → fallback CFPreferences", t_err);
        CFPreferencesSetValue(CFSTR("AirplaneMode"), on ? kCFBooleanTrue : kCFBooleanFalse,
            CFSTR("com.apple.preferences.radios"), kCFPreferencesAnyUser, kCFPreferencesCurrentHost);
        CFPreferencesSynchronize(CFSTR("com.apple.preferences.radios"),
            kCFPreferencesAnyUser, kCFPreferencesCurrentHost);
        notify_post("com.apple.radios.prefschanged");
        if (err && err_len)
            snprintf(err, err_len, "SpringBoard chưa sẵn sàng (%s) — chỉ ghi plist, sóng CHƯA đổi", t_err);
        return -1;
    }
}

// Đặt tên thiết bị tuỳ chỉnh. name rỗng/NULL → xoá file (về mặc định hostname). Lọc ký tự an
// toàn (bỏ điều khiển + " \ để không phá JSON status), cắt tối đa 40 ký tự. Trả 0 nếu OK.
int appctl_set_device_name(const char *name) {
    char clean[64]; size_t o = 0;
    if (name) {
        for (const char *p = name; *p && o < 40; p++) {
            unsigned char c = (unsigned char)*p;
            if (c < 0x20 || c == '"' || c == '\\') continue;
            clean[o++] = (char)c;
        }
    }
    clean[o] = '\0';
    char *s = clean; while (*s == ' ') s++;                    // trim 2 đầu
    size_t e = strlen(s); while (e > 0 && s[e - 1] == ' ') s[--e] = '\0';
    if (e == 0) { unlink(DEVNAME_FILE); return 0; }            // rỗng → về mặc định hostname
    FILE *f = fopen(DEVNAME_FILE, "wb");
    if (!f) return -1;
    fwrite(s, 1, e, f);
    fclose(f);
    return 0;
}
