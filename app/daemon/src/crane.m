// crane.m — bảng Lua `crane`: điều khiển tweak Crane (opa334) từ daemon.
//
// Cơ chế (đã dò từ bản Crane 1.3.17 trên máy):
//   - CLI: /var/jb/usr/local/bin/cranectl  --list/--switch/--create/--wipe/--delete
//   - Kho: /var/jb/var/mobile/Library/Preferences/com.opa334.craneprefs.plist
//          appSettings_<bundle> = { Containers:[{identifier,name}], activeContainer }
//   - Container ĐANG ACTIVE nằm ở data-container chuẩn của app (LSApplicationProxy.dataContainerURL)
//     → backup/restore/clearData thao tác trên đó.
// YÊU CẦU: máy phải cài Crane (com.opa334.crane). Không có → các hàm trả lỗi rõ ràng.
#import <Foundation/Foundation.h>
#include "crane.h"
#include "appctl.h"
#include "lslock.h"
#include "log.h"
#include "lua.h"
#include "lauxlib.h"
#include <spawn.h>
#include <sys/wait.h>
#include <dlfcn.h>
#include <string.h>
#include <unistd.h>

extern char **environ;

#define CRANECTL   "/var/jb/usr/local/bin/cranectl"
#define CRANE_PREFS @"/var/jb/var/mobile/Library/Preferences/com.opa334.craneprefs.plist"
#define BACKUP_DIR  @"/var/mobile/Library/IOSControl/Backups"

// Chạy 1 tiến trình (argv, KHÔNG qua shell → không lo inject) + gom stdout/stderr vào out. Trả exit code.
static int run_cmd(char *const argv[], char *out, size_t outcap) {
    int pfd[2];
    if (pipe(pfd) != 0) { if (out && outcap) out[0] = '\0'; return -1; }
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, pfd[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&fa, pfd[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&fa, pfd[0]);
    pid_t pid;
    int rc = posix_spawnp(&pid, argv[0], &fa, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    close(pfd[1]);
    if (rc != 0) { close(pfd[0]); if (out && outcap) out[0] = '\0'; return -1; }
    size_t o = 0;
    char buf[512]; ssize_t n;
    while ((n = read(pfd[0], buf, sizeof(buf))) > 0) {
        if (out && outcap && o < outcap - 1) {
            size_t cp = (size_t)n; if (o + cp > outcap - 1) cp = outcap - 1 - o;
            memcpy(out + o, buf, cp); o += cp;
        }
    }
    if (out && outcap) out[o] = '\0';
    close(pfd[0]);
    int st = 0; waitpid(pid, &st, 0);
    return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

static int crane_installed(void) { return access(CRANECTL, X_OK) == 0; }

// Chuẩn hoá "tên hoặc id" → tham số cranectl. UUID (có '-' và dài) để nguyên; còn lại → "name:<x>".
static void mk_target(const char *x, char *out, size_t cap) {
    if (x && strchr(x, '-') && strlen(x) >= 32) snprintf(out, cap, "%s", x);
    else snprintf(out, cap, "name:%s", x ? x : "");
}

// ---- data-container (thư mục dữ liệu ĐANG DÙNG của app) qua LSApplicationProxy ----
static NSString *data_container(NSString *bundle) {
    static int loaded = 0;
    if (!loaded) {
        loaded = 1;
        dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY);
        dlopen("/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
    }
    Class P = NSClassFromString(@"LSApplicationProxy");
    if (!P || ![P respondsToSelector:@selector(applicationProxyForIdentifier:)]) return nil;
    NSString *result = nil;
    ia_ls_lock();   // serialize LS dùng chung (tránh race với apps_all/openUrl trên luồng khác)
    @try {
        id proxy = [P performSelector:@selector(applicationProxyForIdentifier:) withObject:bundle];
        if (proxy && [proxy respondsToSelector:@selector(dataContainerURL)]) {
            NSURL *u = [proxy performSelector:@selector(dataContainerURL)];
            if ([u isKindOfClass:[NSURL class]]) result = [u path];
        }
    } @catch (NSException *e) { log_msg("crane: proxy exception %s", [[e reason] UTF8String] ?: "?"); }
    ia_ls_unlock();
    return result;
}

// ========================= Hàm Lua =========================

// crane.list([bundle]) → mảng {name=..., id=...}
static int l_list(lua_State *L) {
    if (!crane_installed()) { lua_pushnil(L); lua_pushstring(L, "chưa cài Crane"); return 2; }
    const char *bundle = luaL_optstring(L, 1, NULL);
    char out[16384];
    char *argv[4]; int i = 0;
    argv[i++] = (char *)CRANECTL; argv[i++] = "--list";
    if (bundle) argv[i++] = (char *)bundle;
    argv[i] = NULL;
    run_cmd(argv, out, sizeof(out));
    lua_newtable(L);
    int idx = 1;
    char *save = NULL;
    for (char *line = strtok_r(out, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        char *lp = strrchr(line, '('), *rp = strrchr(line, ')');
        if (!lp || !rp || rp <= lp || lp == line) continue;
        *rp = '\0';
        char *id = lp + 1;
        char *ne = lp; while (ne > line && ne[-1] == ' ') ne--; *ne = '\0';   // trim khoảng trắng trước '('
        lua_newtable(L);
        lua_pushstring(L, line); lua_setfield(L, -2, "name");
        lua_pushstring(L, id);   lua_setfield(L, -2, "id");
        lua_rawseti(L, -2, idx++);
    }
    return 1;
}

// crane.switch(bundle, nameOrId) — TỰ KILL app trước (đổi container khi đang chạy sẽ hỏng dữ liệu),
// rồi cranectl --switch. Sau đó tự launch lại app (tiện dùng). Trả true nếu OK.
static int l_switch(lua_State *L) {
    if (!crane_installed()) { lua_pushboolean(L, 0); lua_pushstring(L, "chưa cài Crane"); return 2; }
    const char *bundle = luaL_checkstring(L, 1);
    const char *target = luaL_checkstring(L, 2);
    char e[256]; appctl_kill(bundle, e, sizeof(e));
    char arg[320]; mk_target(target, arg, sizeof(arg));
    char out[512];
    char *argv[] = { (char *)CRANECTL, "--switch", (char *)bundle, arg, NULL };
    int rc = run_cmd(argv, out, sizeof(out));
    lua_pushboolean(L, rc == 0);
    return 1;
}

// crane.create(bundle, name) → id container mới (chuỗi) hoặc nil,lỗi.
static int l_create(lua_State *L) {
    if (!crane_installed()) { lua_pushnil(L); lua_pushstring(L, "chưa cài Crane"); return 2; }
    const char *bundle = luaL_checkstring(L, 1);
    const char *name = luaL_checkstring(L, 2);
    char out[512];
    char *argv[] = { (char *)CRANECTL, "--create", (char *)bundle, (char *)name, NULL };
    int rc = run_cmd(argv, out, sizeof(out));
    char *nl = strpbrk(out, "\r\n"); if (nl) *nl = '\0';
    if (rc != 0) { lua_pushnil(L); lua_pushstring(L, out[0] ? out : "lỗi tạo container"); return 2; }
    lua_pushstring(L, out);   // cranectl in ra UUID container mới
    return 1;
}

// crane.delete(bundle, nameOrId) → bool
static int l_delete(lua_State *L) {
    if (!crane_installed()) { lua_pushboolean(L, 0); lua_pushstring(L, "chưa cài Crane"); return 2; }
    const char *bundle = luaL_checkstring(L, 1);
    char arg[320]; mk_target(luaL_checkstring(L, 2), arg, sizeof(arg));
    char out[512];
    char *argv[] = { (char *)CRANECTL, "--delete", (char *)bundle, arg, NULL };
    lua_pushboolean(L, run_cmd(argv, out, sizeof(out)) == 0);
    return 1;
}

// crane.wipe(bundle, nameOrId) — xoá SẠCH dữ liệu container (không xoá container). Trả bool.
static int l_wipe(lua_State *L) {
    if (!crane_installed()) { lua_pushboolean(L, 0); lua_pushstring(L, "chưa cài Crane"); return 2; }
    const char *bundle = luaL_checkstring(L, 1);
    char arg[320]; mk_target(luaL_checkstring(L, 2), arg, sizeof(arg));
    char out[512];
    char *argv[] = { (char *)CRANECTL, "--wipe", (char *)bundle, arg, NULL };
    lua_pushboolean(L, run_cmd(argv, out, sizeof(out)) == 0);
    return 1;
}

// crane.rename(bundle, oldName, newName) — cranectl KHÔNG có rename → sửa trực tiếp craneprefs.plist.
// Trả true nếu đổi được. (Container DEFAULT name rỗng "" hiển thị là "Default" — không đổi tên default.)
static int l_rename(lua_State *L) {
    const char *bundle = luaL_checkstring(L, 1);
    const char *oldName = luaL_checkstring(L, 2);
    const char *newName = luaL_checkstring(L, 3);
    @autoreleasepool {
        NSData *d = [NSData dataWithContentsOfFile:CRANE_PREFS];
        if (!d) { lua_pushboolean(L, 0); lua_pushstring(L, "không đọc được craneprefs"); return 2; }
        NSMutableDictionary *root = [NSPropertyListSerialization propertyListWithData:d
            options:NSPropertyListMutableContainersAndLeaves format:NULL error:NULL];
        if (![root isKindOfClass:[NSMutableDictionary class]]) { lua_pushboolean(L, 0); lua_pushstring(L, "craneprefs sai định dạng"); return 2; }
        NSString *key = [@"appSettings_" stringByAppendingString:@(bundle)];
        NSMutableArray *conts = root[key][@"Containers"];
        BOOL done = NO;
        for (NSMutableDictionary *ct in conts) {
            if ([ct[@"name"] isEqualToString:@(oldName)]) { ct[@"name"] = @(newName); done = YES; break; }
        }
        if (!done) { lua_pushboolean(L, 0); lua_pushstring(L, "không thấy container tên đó"); return 2; }
        NSData *ob = [NSPropertyListSerialization dataWithPropertyList:root
            format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
        BOOL ok = ob && [ob writeToFile:CRANE_PREFS atomically:YES];
        lua_pushboolean(L, ok);
        if (!ok) { lua_pushstring(L, "ghi craneprefs lỗi"); return 2; }
        return 1;
    }
}

// crane.clearData(bundle) → true, số_mục_đã_xoá. Xoá cache/tmp của container ĐANG ACTIVE (giảm dung
// lượng, KHÔNG mất đăng nhập). Không đụng Documents/Preferences.
static int l_clearData(lua_State *L) {
    const char *bundle = luaL_checkstring(L, 1);
    @autoreleasepool {
        NSString *base = data_container(@(bundle));
        if (!base) { lua_pushboolean(L, 0); lua_pushstring(L, "không tìm thấy container (app chưa cài?)"); return 2; }
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray *rels = @[@"Library/Caches", @"tmp", @"Library/WebKit"];
        int count = 0;
        for (NSString *rel in rels) {
            NSString *dir = [base stringByAppendingPathComponent:rel];
            for (NSString *sub in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
                if ([fm removeItemAtPath:[dir stringByAppendingPathComponent:sub] error:NULL]) count++;
            }
        }
        lua_pushboolean(L, 1); lua_pushinteger(L, count);
        return 2;
    }
}

// crane.backup(bundle [, container [, name]]) → true, đường_dẫn_.tar.gz. Sao lưu container ĐANG ACTIVE
// (nếu truyền `container` khác active → tự switch sang đó, backup, rồi switch về). name mặc định = bundle.
static int l_backup(lua_State *L) {
    const char *bundle = luaL_checkstring(L, 1);
    const char *container = lua_isstring(L, 2) ? lua_tostring(L, 2) : NULL;   // nil = active
    const char *name = luaL_optstring(L, 3, bundle);
    @autoreleasepool {
        NSString *base = data_container(@(bundle));
        if (!base) { lua_pushboolean(L, 0); lua_pushstring(L, "không tìm thấy container"); return 2; }
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:BACKUP_DIR withIntermediateDirectories:YES attributes:nil error:NULL];
        NSString *tarPath = [BACKUP_DIR stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%s.tar", name]];
        NSString *gzPath = [tarPath stringByAppendingString:@".gz"];
        // (Tuỳ chọn) chuyển sang container cần backup rồi trả về sau — chỉ khi truyền `container`.
        if (container && crane_installed()) {
            char e[256]; appctl_kill(bundle, e, sizeof(e));
            char arg[320]; mk_target(container, arg, sizeof(arg));
            char o[256]; char *sw[] = { (char *)CRANECTL, "--switch", (char *)bundle, arg, NULL };
            run_cmd(sw, o, sizeof(o));
            base = data_container(@(bundle));   // active có thể đổi
        }
        // 2 BƯỚC: tar KHÔNG spawn được gzip con trên rootless ("gzip: Cannot exec") → tạo .tar
        // (không nén) rồi gzip RIÊNG (chạy standalone tốt). rc<=1 cho tar = cảnh báo (file đổi/bỏ
        // socket) vẫn dùng được; chỉ >1 là lỗi thật.
        [fm removeItemAtPath:tarPath error:NULL]; [fm removeItemAtPath:gzPath error:NULL];
        char out[512];
        char *targv[] = { "/var/jb/usr/bin/tar", "-cf", (char *)[tarPath UTF8String],
                          "-C", (char *)[base UTF8String], ".", NULL };
        int rc = run_cmd(targv, out, sizeof(out));
        if (rc > 1) { [fm removeItemAtPath:tarPath error:NULL];
            lua_pushboolean(L, 0); lua_pushstring(L, out[0] ? out : "tar lỗi"); return 2; }
        char *gzargv[] = { "/var/jb/usr/bin/gzip", "-f", (char *)[tarPath UTF8String], NULL };
        int rc2 = run_cmd(gzargv, out, sizeof(out));
        if (rc2 != 0 || ![fm fileExistsAtPath:gzPath]) {
            lua_pushboolean(L, 0); lua_pushstring(L, out[0] ? out : "gzip lỗi"); return 2; }
        lua_pushboolean(L, 1); lua_pushstring(L, [gzPath UTF8String]);
        return 2;
    }
}

// crane.restore(bundle, path) — kill app, XOÁ sạch container active rồi giải nén backup vào đó. Trả bool.
static int l_restore(lua_State *L) {
    const char *bundle = luaL_checkstring(L, 1);
    const char *path = luaL_checkstring(L, 2);
    @autoreleasepool {
        if (![[NSFileManager defaultManager] fileExistsAtPath:@(path)]) {
            lua_pushboolean(L, 0); lua_pushstring(L, "không thấy file backup"); return 2;
        }
        NSString *base = data_container(@(bundle));
        if (!base) { lua_pushboolean(L, 0); lua_pushstring(L, "không tìm thấy container"); return 2; }
        char e[256]; appctl_kill(bundle, e, sizeof(e));
        NSFileManager *fm = [NSFileManager defaultManager];
        // Giải nén 2 bước (tar không spawn được gzip): gzip -dk giữ .gz gốc, tạo .tar rồi tar -xf.
        NSString *p = @(path);
        NSString *tarTmp = [p hasSuffix:@".gz"] ? [p substringToIndex:p.length - 3]
                                               : [p stringByAppendingString:@".unz"];
        [fm removeItemAtPath:tarTmp error:NULL];
        char *gz[] = { "/var/jb/usr/bin/gzip", "-dkf", (char *)path, NULL };   // -d giải nén, -k giữ gốc, -f
        if (run_cmd(gz, NULL, 0) != 0 || ![fm fileExistsAtPath:tarTmp]) {
            lua_pushboolean(L, 0); lua_pushstring(L, "giải nén gzip lỗi"); return 2; }
        // xoá sạch container hiện tại rồi bung
        for (NSString *sub in [fm contentsOfDirectoryAtPath:base error:NULL])
            [fm removeItemAtPath:[base stringByAppendingPathComponent:sub] error:NULL];
        char *tx[] = { "/var/jb/usr/bin/tar", "-xf", (char *)[tarTmp UTF8String],
                       "-C", (char *)[base UTF8String], NULL };
        int rc = run_cmd(tx, NULL, 0);
        [fm removeItemAtPath:tarTmp error:NULL];   // dọn .tar tạm
        lua_pushboolean(L, rc <= 1);
        return 1;
    }
}

void crane_register(struct lua_State *L) {
    static const luaL_Reg fns[] = {
        {"list",      l_list},
        {"switch",    l_switch},
        {"create",    l_create},
        {"delete",    l_delete},
        {"wipe",      l_wipe},
        {"rename",    l_rename},
        {"clearData", l_clearData},
        {"backup",    l_backup},
        {"restore",   l_restore},
        {NULL, NULL},
    };
    luaL_newlib(L, fns);          // tạo bảng
    lua_setglobal(L, "crane");    // → global `crane`
}
