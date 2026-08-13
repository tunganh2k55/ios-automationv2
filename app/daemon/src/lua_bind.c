#include "lua_bind.h"
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "touch.h"
#include "appctl.h"
#include "imgmatch.h"
#include "fbcap.h"
#include "luaext.h"
#include "crane.h"
#include "profilestore.h"
#include "log.h"
#include "crashlog.h"
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <pthread.h>
#include <time.h>

// ===== Quản lý 1 lần chạy script (nền) =====
// 1 script chạy 1 lúc. Output gom vào buffer tăng dần (đọc được qua API để theo dõi log).
#define RUN_OUT_MAX (256 * 1024)
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static char *g_out = NULL;              // buffer output (malloc, tăng dần)
static size_t g_out_len = 0, g_out_cap = 0;
static volatile int g_busy = 0;         // đang chạy script?
static volatile int g_cancel = 0;       // yêu cầu dừng
static int g_runid = 0;                 // id lần chạy hiện tại/gần nhất
// Delay GIỮA mỗi lần chụp+so khớp trong các vòng tìm ảnh/chữ (waitForImage/tapImage/tapText/...).
// Giãn nhịp chụp framebuffer để giảm tải GPU (tránh bị hệ đồ hoạ kill khi chụp lúc app render nặng).
// Chỉnh bằng setCaptureDelay(giây). Mặc định 1s (chụp thưa cho an toàn; máy khoẻ có thể giảm).
static volatile long g_scan_delay_us = 1000 * 1000;
static time_t g_start = 0;              // thời điểm bắt đầu
static int g_done = 0;                  // lần chạy gần nhất đã kết thúc?

// Ghi thêm vào buffer output (thread-safe, tự nới tới trần RUN_OUT_MAX).
static void out_append_raw(const char *s) {
    if (!s || !*s) return;
    size_t n = strlen(s);
    pthread_mutex_lock(&g_mu);
    if (g_out_len + n + 1 > g_out_cap) {
        size_t ncap = g_out_cap ? g_out_cap : 4096;
        while (ncap < g_out_len + n + 1) ncap <<= 1;
        if (ncap > RUN_OUT_MAX) ncap = RUN_OUT_MAX;
        if (g_out_len + n + 1 > ncap) n = (ncap > g_out_len + 1) ? ncap - g_out_len - 1 : 0;
        if (ncap != g_out_cap) { char *nb = realloc(g_out, ncap); if (nb) { g_out = nb; g_out_cap = ncap; } }
    }
    if (n > 0 && g_out && g_out_len + n + 1 <= g_out_cap) {
        memcpy(g_out + g_out_len, s, n); g_out_len += n; g_out[g_out_len] = '\0';
    }
    pthread_mutex_unlock(&g_mu);
}

// Gắn giờ "HH:MM:SS " vào ĐẦU MỖI DÒNG log (ví dụ "11:48:22 Click done").
// Chỉ 1 script chạy 1 lúc nên cờ đầu-dòng không cần khoá riêng.
static int g_out_at_bol = 1;   // con trỏ ghi đang ở đầu dòng?

static void out_append(const char *s) {
    if (!s || !*s) return;
    char ts[16];
    time_t t = time(NULL);
    struct tm tmv;
    localtime_r(&t, &tmv);
    int tslen = snprintf(ts, sizeof(ts), "%02d:%02d:%02d ", tmv.tm_hour, tmv.tm_min, tmv.tm_sec);
    size_t n = strlen(s), lines = 1;
    for (size_t i = 0; i < n; i++) if (s[i] == '\n') lines++;
    char *buf = malloc(n + lines * (size_t)tslen + 1);
    if (!buf) { out_append_raw(s); return; }   // hết RAM → ghi thô, khỏi gắn giờ
    size_t o = 0;
    for (size_t i = 0; i < n; i++) {
        if (g_out_at_bol && s[i] != '\n') { memcpy(buf + o, ts, (size_t)tslen); o += (size_t)tslen; }
        g_out_at_bol = (s[i] == '\n');
        buf[o++] = s[i];
    }
    buf[o] = '\0';
    out_append_raw(buf);
    free(buf);
}

// print(...) → gom vào output
static int l_print(lua_State *L) {
    int n = lua_gettop(L);
    for (int i = 1; i <= n; i++) {
        size_t len;
        const char *s = luaL_tolstring(L, i, &len);
        if (i > 1) out_append("\t");
        out_append(s ? s : "");
        lua_pop(L, 1);
    }
    out_append("\n");
    return 0;
}

// tap(x, y)
static int l_tap(lua_State *L) {
    char e[128];
    touch_tap((int)luaL_checknumber(L, 1), (int)luaL_checknumber(L, 2), e, sizeof(e));
    return 0;
}
// swipe(x1, y1, x2, y2 [, duration])
static int l_swipe(lua_State *L) {
    char e[128];
    double dur = (lua_gettop(L) >= 5) ? luaL_checknumber(L, 5) : 0.3;
    touch_swipe((int)luaL_checknumber(L, 1), (int)luaL_checknumber(L, 2),
                (int)luaL_checknumber(L, 3), (int)luaL_checknumber(L, 4), dur, e, sizeof(e));
    return 0;
}
// input(text) — gõ vào ô nhập đang focus
static int l_input(lua_State *L) {
    const char *t = luaL_checkstring(L, 1);
    char verb[520], e[256];
    snprintf(verb, sizeof(verb), "TYPE %s", t);
    touch_raw(verb, e, sizeof(e));
    return 0;
}
// launch(bundleId) → bool
static int l_launch(lua_State *L) {
    const char *bid = luaL_checkstring(L, 1);
    char e[256];
    log_msg("lua: appRun/launch \"%s\" …", bid);          // TRACE: bước nặng, hay ngay trước crash
    int rc = appctl_launch(bid, e, sizeof(e));
    log_msg("lua: appRun/launch \"%s\" -> %s", bid, rc == 0 ? "OK" : e);
    iosauto_mem_log("after-launch");                      // bộ nhớ sau khi mở app (đỉnh áp lực)
    lua_pushboolean(L, rc == 0);
    return 1;
}
// kill(bundleId) → bool
static int l_kill(lua_State *L) {
    const char *bid = luaL_checkstring(L, 1);
    char e[256];
    log_msg("lua: kill \"%s\" …", bid);
    int rc = appctl_kill(bid, e, sizeof(e));
    lua_pushboolean(L, rc == 0);
    return 1;
}
// clearAppData(bundleId) → true, số_mục_đã_xoá  ·  hoặc false, lỗi.
// Xoá TOÀN BỘ dữ liệu app (reset về như mới cài — mất đăng nhập). Tự kill app trước.
static int l_clearAppData(lua_State *L) {
    const char *bid = luaL_checkstring(L, 1);
    char e[256]; int removed = 0;
    log_msg("lua: clearAppData \"%s\" …", bid);
    int rc = appctl_clear_data(bid, &removed, e, sizeof(e));
    log_msg("lua: clearAppData \"%s\" -> %s (%s)", bid, rc == 0 ? "OK" : "lỗi", e);
    lua_pushboolean(L, rc == 0);
    if (rc == 0) lua_pushinteger(L, removed); else lua_pushstring(L, e);
    return 2;
}
// sleep(seconds) — hỗ trợ số thực. Ngủ theo bước nhỏ để kịp DỪNG giữa chừng.
static int l_sleep(lua_State *L) {
    double s = luaL_checknumber(L, 1);
    if (s < 0) s = 0; if (s > 3600) s = 3600;
    long steps = (long)(s / 0.05);
    for (long i = 0; i < steps; i++) {
        if (g_cancel) return luaL_error(L, "đã dừng");
        // Nhịp bộ nhớ mỗi 2s trong lúc ngủ (chỉ sleep dài) — bắt "vực" RAM ngay trước khi bị kill.
        if (steps >= 40 && i > 0 && (i % 40) == 0) iosauto_mem_log("sleep");
        usleep(50 * 1000);
    }
    if (g_cancel) return luaL_error(L, "đã dừng");
    return 0;
}
// home() — về màn hình chính
static int l_home(lua_State *L) {
    (void)L; char e[128]; touch_raw("HOME", e, sizeof(e)); return 0;
}
// wake() — bật màn hình + mở khoá (nếu không passcode); ưu tiên SpringBoard
static int l_wake(lua_State *L) {
    (void)L; char e[128]; touch_wake(e, sizeof(e)); return 0;
}
// setAirplane(on [, offDelay]) — BẬT/TẮT Airplane Mode (tắt/bật sóng 4G để xin IP mới).
//   on true/1 = BẬT airplane; false/0 = TẮT.
//   offDelay (giây, tuỳ chọn): CHỈ khi on=true → BẬT airplane rồi tự động TẮT lại sau offDelay giây.
//     Ví dụ setAirplane(true, 5) = bật máy bay, 5s sau tắt (dừng được khi người dùng ấn Dừng).
// Trả true nếu OK; false + chuỗi lỗi nếu không (daemon vẫn chạy tiếp, script tự xử lý).
static int l_setAirplane(lua_State *L) {
    int on = lua_toboolean(L, 1);
    double delay = luaL_optnumber(L, 2, 0);        // giây; 0 = không tự tắt
    char e[128]; e[0] = '\0';
    int rc = appctl_set_airplane(on, e, sizeof(e));
    if (rc != 0) { lua_pushboolean(L, 0); lua_pushstring(L, e[0] ? e : "lỗi"); return 2; }

    if (on && delay > 0) {                          // bật rồi tự tắt sau `delay` giây
        if (delay > 3600) delay = 3600;
        long steps = (long)(delay / 0.05);
        for (long i = 0; i < steps; i++) {
            if (g_cancel) return luaL_error(L, "đã dừng");   // ấn Dừng giữa chừng → thoát ngay
            usleep(50 * 1000);
        }
        e[0] = '\0';
        int rc2 = appctl_set_airplane(0, e, sizeof(e));      // TẮT airplane (bật lại sóng)
        lua_pushboolean(L, rc2 == 0);
        if (rc2 != 0) { lua_pushstring(L, e[0] ? e : "lỗi"); return 2; }
        return 1;
    }
    lua_pushboolean(L, 1);
    return 1;
}
// log(msg)
static int l_log(lua_State *L) {
    const char *s = luaL_tolstring(L, 1, NULL);   // nhận MỌI kiểu (chuỗi/số/boolean/nil) → chuỗi
    log_msg("lua: %s", s ? s : "nil");
    out_append(s ? s : "nil"); out_append("\n");  // hiện trong output script (panel web) + log daemon
    lua_pop(L, 1);                                 // luaL_tolstring đẩy chuỗi lên stack → pop
    return 0;
}
// toast(msg [, duration]) -> true if the command reached the tweak.
static int l_toast(lua_State *L) {
    double duration = luaL_optnumber(L, 2, 2.0);
    const char *s = luaL_tolstring(L, 1, NULL);
    char e[256] = {0};
    int rc = touch_toast(s ? s : "", duration, e, sizeof(e));
    lua_pop(L, 1);
    lua_pushboolean(L, rc == 0);
    return 1;
}

// Đọc file kết quả (dump/ocr) mà tweak vừa ghi → đẩy nội dung lên stack Lua.
// reply dạng "OK <marker> <path>". Trả 1 (chuỗi) nếu OK, hoặc nil+lỗi (2 giá trị).
static int push_result_file(lua_State *L, const char *reply, const char *marker) {
    const char *p = strstr(reply, marker);
    if (!p) { lua_pushnil(L); lua_pushstring(L, reply[0] ? reply : "lỗi"); return 2; }
    p += strlen(marker);
    char path[512];
    snprintf(path, sizeof(path), "%s", p);
    char *nl = strpbrk(path, "\r\n"); if (nl) *nl = '\0';
    FILE *f = fopen(path, "rb");
    if (!f) { lua_pushnil(L); lua_pushstring(L, "không đọc được kết quả"); return 2; }
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    if (sz < 0) sz = 0;
    char *buf = malloc((size_t)sz + 1);
    size_t rd = buf ? fread(buf, 1, (size_t)sz, f) : 0;
    fclose(f);
    if (!buf) { lua_pushnil(L); lua_pushstring(L, "oom"); return 2; }
    lua_pushlstring(L, buf, rd);
    free(buf);
    return 1;
}
// dump() → chuỗi XML cây UIView của app foreground (hoặc nil, lỗi).
static int l_dump(lua_State *L) {
    char reply[800] = {0};
    touch_dump(reply, sizeof(reply));
    return push_result_file(L, reply, "dump ");
}

// ---- tapDump: tap theo TEXT lấy từ cây dump() (hàm ẨN — không có trong gợi ý docs) ----
// Đọc số nguyên thuộc tính `key` trong 1 tag <node ...> (dùng khoảng trắng đầu để khỏi khớp nhầm).
static int dumptag_int(const char *tag, const char *key) {
    char pat[24]; snprintf(pat, sizeof(pat), " %s=\"", key);
    const char *a = strstr(tag, pat);
    return a ? atoi(a + strlen(pat)) : -999999;
}
// Giá trị thuộc tính `key` có CHỨA needle (không phân biệt hoa/thường) không?
static int dumptag_has(const char *tag, const char *key, const char *needle) {
    char pat[24]; snprintf(pat, sizeof(pat), " %s=\"", key);
    const char *a = strstr(tag, pat); if (!a) return 0;
    a += strlen(pat);
    const char *e = strchr(a, '"'); if (!e) return 0;
    char val[512]; size_t n = (size_t)(e - a); if (n >= sizeof(val)) n = sizeof(val) - 1;
    memcpy(val, a, n); val[n] = '\0';
    return strcasestr(val, needle) != NULL;
}
// tapDump("text" [, index=1]) → tìm node có text/label/value/id CHỨA "text" (visible, có kích thước),
// tap vào TÂM node thứ `index`. Trả true,cx,cy nếu tap; false nếu không thấy.
// LƯU Ý: chỉ thấy phần tử NATIVE (UILabel/UIButton/accessibilityLabel…). App WebView thuần
// (nội dung HTML) KHÔNG nằm trong dump → dùng tapText/OCR cho loại đó.
static int l_tapDump(lua_State *L) {
    const char *needle = luaL_checkstring(L, 1);
    int want = (int)luaL_optinteger(L, 2, 1); if (want < 1) want = 1;

    char reply[800] = {0};
    if (touch_dump(reply, sizeof(reply)) != 0) { lua_pushboolean(L, 0); return 1; }
    const char *mk = strstr(reply, "dump "); if (!mk) { lua_pushboolean(L, 0); return 1; }
    char path[512]; snprintf(path, sizeof(path), "%s", mk + 5);
    char *nl = strpbrk(path, "\r\n"); if (nl) *nl = '\0';
    FILE *f = fopen(path, "rb"); if (!f) { lua_pushboolean(L, 0); return 1; }
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET); if (sz < 0) sz = 0;
    char *xml = malloc((size_t)sz + 1);
    size_t rd = xml ? fread(xml, 1, (size_t)sz, f) : 0; fclose(f);
    if (!xml) { lua_pushboolean(L, 0); return 1; }
    xml[rd] = '\0';

    int found = 0, cx = 0, cy = 0, cnt = 0;
    char *p = xml;
    while (p && *p) {
        char *lt = strchr(p, '<'); if (!lt) break;
        // Chỉ xét tag mở <node ...> (view native) và <ax ...> (accessibility/WebView). Bỏ </...>, <?xml, <screen.
        int isNode = (strncmp(lt, "<node", 5) == 0);
        int isAx   = (strncmp(lt, "<ax", 3) == 0);
        if (!isNode && !isAx) { p = lt + 1; continue; }
        char *end = strchr(lt, '>'); if (!end) break;
        size_t tl = (size_t)(end - lt);
        char tag[2048]; if (tl >= sizeof(tag)) tl = sizeof(tag) - 1;
        memcpy(tag, lt, tl); tag[tl] = '\0';
        p = end + 1;
        if (dumptag_int(tag, "visible") == 0) continue;    // <node visible="0" → bỏ; <ax không có → giữ
        int w = dumptag_int(tag, "w"), h = dumptag_int(tag, "h");
        if (w <= 0 || h <= 0) continue;
        if (dumptag_has(tag, "text", needle) || dumptag_has(tag, "label", needle) ||
            dumptag_has(tag, "value", needle) || dumptag_has(tag, "id", needle)) {
            if (++cnt == want) {
                int x = dumptag_int(tag, "x"), y = dumptag_int(tag, "y");
                cx = x + w / 2; cy = y + h / 2; found = 1; break;
            }
        }
    }
    free(xml);
    if (!found) { log_msg("lua: tapDump \"%s\" #%d — không thấy trong dump", needle, want);
                  lua_pushboolean(L, 0); return 1; }
    char err[128] = {0};
    log_msg("lua: tapDump \"%s\" #%d → tap (%d,%d)", needle, want, cx, cy);
    touch_tap(cx, cy, err, sizeof(err));
    lua_pushboolean(L, 1); lua_pushinteger(L, cx); lua_pushinteger(L, cy);
    return 3;
}
// ocr() → chuỗi JSON mảng {text,x,y,w,h,cx,cy,conf} (hoặc nil, lỗi).
static int l_ocr(lua_State *L) {
    char reply[900] = {0};
    const char *lang = lua_isstring(L, 1) ? lua_tostring(L, 1) : NULL;   // ocr("ja,en-US") tuỳ chọn
    touch_ocr(reply, sizeof(reply), lang);
    return push_result_file(L, reply, "ocr ");
}

// ---- OCR + tap theo CHỮ ----
// Giải mã chuỗi JSON tại *pp (con trỏ đứng SAU dấu " mở) → out (NUL-terminated); đẩy *pp qua dấu "
// đóng. Xử lý escape cơ bản (\n \t \r \uXXXX→'?'). Dùng chung cho ocr_find_once & l_ocrTextRegion.
static void json_str_decode(char **pp, char *out, size_t outcap) {
    char *q = *pp; size_t ti = 0;
    while (*q && *q != '"' && ti + 1 < outcap) {
        if (*q == '\\' && q[1]) {
            q++;
            switch (*q) {
                case 'n': out[ti++] = '\n'; q++; break; case 't': out[ti++] = '\t'; q++; break;
                case 'r': out[ti++] = '\r'; q++; break;
                // \uXXXX: bỏ 4 hex → '?'. Bound theo NUL (đừng nhảy q+=4 mù → vượt buffer → OOB read crash).
                case 'u': { out[ti++] = '?'; q++; for (int k = 0; k < 4 && *q; k++) q++; break; }
                default: out[ti++] = *q++; break;
            }
        } else out[ti++] = *q++;
    }
    out[ti] = '\0';
    *pp = q;
}

// Chụp + OCR 1 lần (giới hạn vùng nếu rw/rh>0 — Vision chỉ nhận dạng trong vùng, nhanh hơn nhiều)
// → nội dung file JSON (malloc, NUL-terminated) hoặc NULL nếu lỗi. Caller free.
static char *ocr_run_json(const char *lang, int rx, int ry, int rw, int rh) {
    char reply[900] = {0};
    if (touch_ocr_region(reply, sizeof(reply), lang, rx, ry, rw, rh) != 0) return NULL;
    const char *mk = strstr(reply, "ocr "); if (!mk) return NULL;
    char path[512]; snprintf(path, sizeof(path), "%s", mk + 4);
    char *nl = strpbrk(path, "\r\n"); if (nl) *nl = '\0';
    FILE *f = fopen(path, "rb"); if (!f) return NULL;
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    if (sz < 0) sz = 0;
    char *buf = malloc((size_t)sz + 1);
    size_t rd = buf ? fread(buf, 1, (size_t)sz, f) : 0;
    fclose(f);
    if (!buf) return NULL;
    buf[rd] = '\0';
    return buf;
}

// Chụp+OCR 1 lần, tìm occurrence thứ wantIdx (1-based) của dòng CHỨA needle (không phân biệt hoa/thường
// với ASCII; tiếng Nhật/… so khớp byte UTF-8). Trả 1 + set cx,cy nếu thấy; 0 nếu không.
static int ocr_find_once(const char *needle, int wantIdx, int *cx, int *cy, const char *lang,
                         int rx, int ry, int rw, int rh) {
    char *buf = ocr_run_json(lang, rx, ry, rw, rh);
    if (!buf) return 0;

    int matchCount = 0, found = 0;
    char *q = buf;
    while ((q = strstr(q, "\"text\":\"")) != NULL) {
        q += 8;
        char text[512];
        json_str_decode(&q, text, sizeof(text));
        char *cxp = strstr(q, "\"cx\":"), *cyp = strstr(q, "\"cy\":");
        char *nextObj = strstr(q, "\"text\":\"");
        if (cxp && cyp && (!nextObj || cxp < nextObj)) {
            int bx = atoi(cxp + 5), by = atoi(cyp + 5);
            int inRegion = (rw <= 0 || rh <= 0) || (bx >= rx && bx <= rx + rw && by >= ry && by <= ry + rh);
            if (inRegion && strcasestr(text, needle) != NULL) {
                if (++matchCount == wantIdx) { *cx = bx; *cy = by; found = 1; break; }
            }
        }
    }
    free(buf);
    return found;
}

// ocrTextRegion(x, y, w, h [, lang]) → chuỗi các dòng chữ (nối bằng '\n') mà TÂM nằm trong vùng
// [x,y,w,h] (điểm màn). w<=0||h<=0 → toàn màn. Trả chuỗi (rỗng nếu không có chữ) hoặc nil, lỗi.
static int l_ocrTextRegion(lua_State *L) {
    int rx = (int)luaL_checkinteger(L, 1), ry = (int)luaL_checkinteger(L, 2);
    int rw = (int)luaL_checkinteger(L, 3), rh = (int)luaL_checkinteger(L, 4);
    const char *lang = lua_isstring(L, 5) ? lua_tostring(L, 5) : NULL;
    log_msg("lua: ocrTextRegion [%d,%d,%d,%d]…", rx, ry, rw, rh);
    char *buf = ocr_run_json(lang, rx, ry, rw, rh);
    if (!buf) { lua_pushnil(L); lua_pushstring(L, "OCR lỗi (chưa có app foreground?)"); return 2; }

    luaL_Buffer b; luaL_buffinit(L, &b);
    int n = 0;
    char *q = buf;
    while ((q = strstr(q, "\"text\":\"")) != NULL) {
        q += 8;
        char text[512];
        json_str_decode(&q, text, sizeof(text));
        char *cxp = strstr(q, "\"cx\":"), *cyp = strstr(q, "\"cy\":");
        char *nextObj = strstr(q, "\"text\":\"");
        if (cxp && cyp && (!nextObj || cxp < nextObj)) {
            int bx = atoi(cxp + 5), by = atoi(cyp + 5);
            int inRegion = (rw <= 0 || rh <= 0) || (bx >= rx && bx <= rx + rw && by >= ry && by <= ry + rh);
            if (inRegion) { if (n++) luaL_addchar(&b, '\n'); luaL_addstring(&b, text); }
        }
    }
    free(buf);
    luaL_pushresult(&b);
    return 1;
}

// ============================================================================
//  MÔ HÌNH MỚI (chống crash): MỖI lần khớp = CHỤP 1 LẦN rồi so sánh 1 lần.
//  Số lần chụp = `tries` (mặc định 1), nghỉ giữa các lần = `delay` giây (mặc định
//  = setCaptureDelay). Không còn vòng chụp liên tục theo timeout → không hammer GPU.
//  Delay mặc định lấy từ g_scan_delay_us; script có thể truyền delay riêng.
// ============================================================================

// Ngủ NGẮT-ĐƯỢC giữa hai lần chụp. Trả 1 nếu bị yêu cầu dừng (g_cancel), 0 nếu ngủ xong.
static int scan_sleep(double sec) {
    if (sec <= 0) return g_cancel ? 1 : 0;
    long steps = (long)(sec / 0.05);
    for (long i = 0; i < steps; i++) { if (g_cancel) return 1; usleep(50 * 1000); }
    return g_cancel ? 1 : 0;
}
// Delay mặc định (giây) khi script không truyền — theo setCaptureDelay.
static double scan_default_delay(void) { return (double)g_scan_delay_us / 1e6; }

// ---- Khớp CHỮ (OCR) + tap: chụp `tries` lần, nghỉ `delay` giây sau mỗi lần ----
static int tap_text_common(lua_State *L, const char *needle, int tries, double delay,
                           int index, const char *lang, int rx, int ry, int rw, int rh) {
    if (tries < 1) tries = 1;
    if (delay < 0) delay = 0;
    if (index < 1) index = 1;
    log_msg("lua: text-match \"%s\" (tries=%d delay=%.2f)…", needle, tries, delay);
    int cx = 0, cy = 0;
    for (int t = 0; t < tries; t++) {
        if (g_cancel) break;
        if (ocr_find_once(needle, index, &cx, &cy, lang, rx, ry, rw, rh)) {
            char err[128] = {0};
            touch_tap(cx, cy, err, sizeof(err));
            lua_pushboolean(L, 1); lua_pushinteger(L, cx); lua_pushinteger(L, cy);
            return 3;
        }
        if (t < tries - 1 && scan_sleep(delay)) break;   // nghỉ sau mỗi lần chụp (trừ lần cuối)
    }
    lua_pushboolean(L, 0);
    return 1;
}
// tapText("chữ" [, tries=1 [, delay [, lang]]]) → true,cx,cy nếu tap được; false nếu hết tries.
static int l_tapText(lua_State *L) {
    const char *needle = luaL_checkstring(L, 1);
    int tries = (int)luaL_optinteger(L, 2, 1);
    double delay = luaL_optnumber(L, 3, scan_default_delay());
    const char *lang = lua_isstring(L, 4) ? lua_tostring(L, 4) : NULL;
    return tap_text_common(L, needle, tries, delay, 1, lang, 0, 0, 0, 0);
}
// tapTextIndex("chữ" [, tries=1 [, index=1 [, delay [, lang]]]]) → tap occurrence thứ `index`.
static int l_tapTextIndex(lua_State *L) {
    const char *needle = luaL_checkstring(L, 1);
    int tries = (int)luaL_optinteger(L, 2, 1);
    int index = (int)luaL_optinteger(L, 3, 1);
    double delay = luaL_optnumber(L, 4, scan_default_delay());
    const char *lang = lua_isstring(L, 5) ? lua_tostring(L, 5) : NULL;
    return tap_text_common(L, needle, tries, delay, index, lang, 0, 0, 0, 0);
}
// tapTextRegion("chữ", x, y, w, h [, tries=1 [, delay [, index=1 [, lang]]]]) → tìm chữ TRONG vùng rồi tap.
static int l_tapTextRegion(lua_State *L) {
    const char *needle = luaL_checkstring(L, 1);
    int rx = (int)luaL_checkinteger(L, 2), ry = (int)luaL_checkinteger(L, 3);
    int rw = (int)luaL_checkinteger(L, 4), rh = (int)luaL_checkinteger(L, 5);
    int tries = (int)luaL_optinteger(L, 6, 1);
    double delay = luaL_optnumber(L, 7, scan_default_delay());
    int index = (int)luaL_optinteger(L, 8, 1);
    const char *lang = lua_isstring(L, 9) ? lua_tostring(L, 9) : NULL;
    return tap_text_common(L, needle, tries, delay, index, lang, rx, ry, rw, rh);
}

// ---- Khớp ẢNH MẪU + tap: chụp `tries` lần, nghỉ `delay` giây sau mỗi lần ----
static int tap_image_common(lua_State *L, const char *name, int tries, double delay,
                            int index, double threshold, int rx, int ry, int rw, int rh) {
    if (tries < 1) tries = 1;
    if (delay < 0) delay = 0;
    if (index < 1) index = 1;
    log_msg("lua: img-match \"%s\" (tries=%d delay=%.2f thr=%.2f)…", name, tries, delay, threshold);
    int cx = 0, cy = 0; double score = 0;
    for (int t = 0; t < tries; t++) {
        if (g_cancel) break;
        if (imgmatch_find(name, rx, ry, rw, rh, index, threshold, &cx, &cy, &score)) {
            char err[128] = {0};
            touch_tap(cx, cy, err, sizeof(err));
            lua_pushboolean(L, 1); lua_pushinteger(L, cx); lua_pushinteger(L, cy); lua_pushnumber(L, score);
            return 4;
        }
        if (t < tries - 1 && scan_sleep(delay)) break;
    }
    lua_pushboolean(L, 0);
    return 1;
}
// tapImage("ten.jpg" [, tries=1 [, delay [, threshold=0.8]]]) → true,cx,cy,score nếu tap được; false nếu không.
static int l_tapImage(lua_State *L) {
    const char *name = luaL_checkstring(L, 1);
    int tries = (int)luaL_optinteger(L, 2, 1);
    double delay = luaL_optnumber(L, 3, scan_default_delay());
    double threshold = luaL_optnumber(L, 4, 0.8);
    return tap_image_common(L, name, tries, delay, 1, threshold, 0, 0, 0, 0);
}
// tapImageIndex("ten.jpg" [, tries=1 [, index=1 [, delay [, threshold=0.8]]]]) → tap match thứ `index`.
static int l_tapImageIndex(lua_State *L) {
    const char *name = luaL_checkstring(L, 1);
    int tries = (int)luaL_optinteger(L, 2, 1);
    int index = (int)luaL_optinteger(L, 3, 1);
    double delay = luaL_optnumber(L, 4, scan_default_delay());
    double threshold = luaL_optnumber(L, 5, 0.8);
    return tap_image_common(L, name, tries, delay, index, threshold, 0, 0, 0, 0);
}
// tapImageRegion("ten.jpg", x, y, w, h [, tries=1 [, delay [, threshold=0.8]]]) → tìm ảnh TRONG vùng rồi tap.
static int l_tapImageRegion(lua_State *L) {
    const char *name = luaL_checkstring(L, 1);
    int rx = (int)luaL_checkinteger(L, 2), ry = (int)luaL_checkinteger(L, 3);
    int rw = (int)luaL_checkinteger(L, 4), rh = (int)luaL_checkinteger(L, 5);
    int tries = (int)luaL_optinteger(L, 6, 1);
    double delay = luaL_optnumber(L, 7, scan_default_delay());
    double threshold = luaL_optnumber(L, 8, 0.8);
    return tap_image_common(L, name, tries, delay, 1, threshold, rx, ry, rw, rh);
}

// ---- CHỜ xuất hiện (KHÔNG tap): chụp `tries` lần, nghỉ `delay` giây sau mỗi lần ----
// waitForText("chữ" [, tries=1 [, delay [, lang [, x, y, w, h]]]]) → true,cx,cy nếu thấy; false nếu hết tries.
static int l_waitForText(lua_State *L) {
    const char *needle = luaL_checkstring(L, 1);
    int tries = (int)luaL_optinteger(L, 2, 1);
    double delay = luaL_optnumber(L, 3, scan_default_delay());
    const char *lang = lua_isstring(L, 4) ? lua_tostring(L, 4) : NULL;
    int rx = (int)luaL_optinteger(L, 5, 0), ry = (int)luaL_optinteger(L, 6, 0);
    int rw = (int)luaL_optinteger(L, 7, 0), rh = (int)luaL_optinteger(L, 8, 0);
    if (tries < 1) tries = 1;
    if (delay < 0) delay = 0;
    int cx = 0, cy = 0;
    for (int t = 0; t < tries; t++) {
        if (g_cancel) break;
        if (ocr_find_once(needle, 1, &cx, &cy, lang, rx, ry, rw, rh)) {
            lua_pushboolean(L, 1); lua_pushinteger(L, cx); lua_pushinteger(L, cy);
            return 3;
        }
        if (t < tries - 1 && scan_sleep(delay)) break;
    }
    lua_pushboolean(L, 0);
    return 1;
}
// waitForImage("ten.jpg" [, tries=1 [, delay [, threshold=0.8 [, x, y, w, h]]]]) → true,cx,cy,score nếu thấy.
static int l_waitForImage(lua_State *L) {
    const char *name = luaL_checkstring(L, 1);
    int tries = (int)luaL_optinteger(L, 2, 1);
    double delay = luaL_optnumber(L, 3, scan_default_delay());
    double threshold = luaL_optnumber(L, 4, 0.8);
    int rx = (int)luaL_optinteger(L, 5, 0), ry = (int)luaL_optinteger(L, 6, 0);
    int rw = (int)luaL_optinteger(L, 7, 0), rh = (int)luaL_optinteger(L, 8, 0);
    if (tries < 1) tries = 1;
    if (delay < 0) delay = 0;
    log_msg("lua: waitForImage \"%s\" (tries=%d delay=%.2f thr=%.2f)…", name, tries, delay, threshold);
    int cx = 0, cy = 0; double score = 0;
    for (int t = 0; t < tries; t++) {
        if (g_cancel) break;
        if (imgmatch_find(name, rx, ry, rw, rh, 1, threshold, &cx, &cy, &score)) {
            lua_pushboolean(L, 1); lua_pushinteger(L, cx); lua_pushinteger(L, cy); lua_pushnumber(L, score);
            return 4;
        }
        if (t < tries - 1 && scan_sleep(delay)) break;
    }
    lua_pushboolean(L, 0);
    return 1;
}

// ---- Clipboard iPhone (UIPasteboard chung, qua tweak) ----
// copyText("text") — đặt clipboard hệ thống = text. Trả true nếu OK.
static int l_copyText(lua_State *L) {
    const char *t = luaL_checkstring(L, 1);
    char e[256];
    int rc = touch_copy(t, e, sizeof(e));
    lua_pushboolean(L, rc == 0);
    return 1;
}
// clipText() → nội dung clipboard hệ thống (chuỗi) hoặc nil, lỗi.
static int l_clipText(lua_State *L) {
    char reply[800] = {0};
    touch_clip(reply, sizeof(reply));
    return push_result_file(L, reply, "clip ");
}

// safari.fill(field, value) → true/false, diag. Điền `value` vào ô web khớp `field` (CSS selector
// hoặc chuỗi khớp placeholder/name/id/type/aria-label/label) trong WKWebView app foreground.
// TỰ cuộn (scrollIntoView) tới ô trước khi điền — ô ngoài màn (form dài) không cần safari.swipe.
// Hàm ẨN (không có trong gợi ý syntax) — dùng cho Safari khi bàn phím web không bật được.
static int l_safariFill(lua_State *L) {
    const char *field = luaL_checkstring(L, 1);
    const char *value = luaL_optstring(L, 2, "");
    char reply[600] = {0};
    int rc = touch_safari_fill(field, value, reply, sizeof(reply));
    lua_pushboolean(L, rc == 0 && strncmp(reply, "OK", 2) == 0);
    lua_pushstring(L, reply);
    return 2;
}

// safari.type(field, value) → true/false, diag. GÕ từng ký tự (mô phỏng người) vào ô web khớp
// `field` — bắn đủ keydown/keypress/beforeinput/input(InputEvent)/keyup + set value tăng dần, khó bị
// anti-bot phát hiện hơn safari.fill (đặt cả chuỗi 1 phát). Hàm ẨN — dùng cho ô nhạy cảm (login…).
static int l_safariType(lua_State *L) {
    const char *field = luaL_checkstring(L, 1);
    const char *value = luaL_optstring(L, 2, "");
    char reply[600] = {0};
    int rc = touch_safari_type(field, value, reply, sizeof(reply));
    lua_pushboolean(L, rc == 0 && strncmp(reply, "OK", 2) == 0);
    lua_pushstring(L, reply);
    return 2;
}

// safari.clear() → true, số_mục_đã_xoá  ·  hoặc false, lỗi. Xoá LỊCH SỬ + DỮ LIỆU TRANG WEB của Safari
// — ĐÚNG như nút "Xoá Lịch sử và Dữ liệu Trang web" trong Cài đặt → Safari (lịch sử, tab đang mở,
// cookie, cache, WebKit data). Gọi thẳng clearAppData cho com.apple.mobilesafari (tự kill Safari trước;
// dữ liệu Safari nằm ngoài container nên hàm này xoá tận gốc ở /var/mobile/Library/Safari…). KHÔNG cần
// tham số. Sau khi xoá, mở lại Safari sẽ như mới. Muốn dọn 1 Ô nhập web thì dùng safari.fill(field,"").
static int l_safariClear(lua_State *L) {
    (void)L;
    char e[600]; int removed = 0;
    log_msg("lua: safari.clear (xoá lịch sử + dữ liệu Safari) …");
    int rc = appctl_clear_data("com.apple.mobilesafari", &removed, e, sizeof(e));
    log_msg("lua: safari.clear -> %s (%s)", rc == 0 ? "OK" : "lỗi", e);
    lua_pushboolean(L, rc == 0);
    if (rc == 0) lua_pushinteger(L, removed); else lua_pushstring(L, e);
    lua_pushstring(L, e);   // giá trị #3: breakdown chẩn đoán (del/got từng đường dẫn Safari)
    return 3;
}

// safari.swipe(field) → true/false, diag. Cuộn WKWebView app foreground tới element khớp `field`
// (CSS selector hoặc text/placeholder/name/id/aria-label…) — đưa ra giữa màn qua scrollIntoView.
// Hàm ẨN (không có trong gợi ý syntax) — dùng khi element nằm ngoài màn, cần kéo tới mới thao tác.
static int l_safariSwipe(lua_State *L) {
    const char *field = luaL_checkstring(L, 1);
    char reply[600] = {0};
    int rc = touch_safari_swipe(field, reply, sizeof(reply));
    lua_pushboolean(L, rc == 0 && strncmp(reply, "OK", 2) == 0);
    lua_pushstring(L, reply);
    return 2;
}

// safari.click(field) → true/false, diag. Bấm element web khớp `field` (CSS selector hoặc text/
// placeholder/name/id/aria-label/button/link) — TỰ SWIPE tới element + sleep 0.5s + bấm.
// Hàm ẨN (không có trong gợi ý syntax) — bấm nút/link web khi HID không tới WebContent.
static int l_safariClick(lua_State *L) {
    if (g_cancel) return luaL_error(L, "đã dừng");
    const char *field = luaL_checkstring(L, 1);
    char reply[600] = {0};

    // 1. Swipe tới element trước
    int swipe_rc = touch_safari_swipe(field, reply, sizeof(reply));
    if (g_cancel) return luaL_error(L, "đã dừng");
    if (swipe_rc != 0 || strncmp(reply, "OK", 2) != 0) {
        // Swipe thất bại → trả lỗi
        lua_pushboolean(L, 0);
        lua_pushstring(L, reply);
        return 2;
    }

    // 2. Sleep 0.5s để element ổn định sau scroll (chia nhỏ để dừng được)
    for (int i = 0; i < 10; i++) {
        if (g_cancel) return luaL_error(L, "đã dừng");
        usleep(50000);  // 50ms x 10 = 500ms
    }

    // 3. Click element
    if (g_cancel) return luaL_error(L, "đã dừng");
    memset(reply, 0, sizeof(reply));
    int rc = touch_safari_click(field, reply, sizeof(reply));
    lua_pushboolean(L, rc == 0 && strncmp(reply, "OK", 2) == 0);
    lua_pushstring(L, reply);
    return 2;
}

// safari.checkbox(field) → true/false, diag. TICK checkbox/radio web khớp `field` CHO CHẮC — khác
// safari.click: tìm ĐÚNG <input> (dù field trỏ vào label), tap vào LABEL hiển thị nếu input bị ẩn
// (form Nhật hay style label đè lên input opacity:0), rồi VERIFY .checked + .click() JS bù nếu tap
// trượt. Ô đã tick sẵn coi như thành công (không bấm lại để khỏi bỏ tick). Hàm ẨN — dùng cho các ô
// "đồng ý" (利用規約 / プライバシーポリシー…) cần tick chắc chắn.
static int l_safariCheckbox(lua_State *L) {
    if (g_cancel) return luaL_error(L, "đã dừng");
    const char *field = luaL_checkstring(L, 1);
    char reply[600] = {0};
    int rc = touch_safari_checkbox(field, reply, sizeof(reply));
    if (g_cancel) return luaL_error(L, "đã dừng");
    lua_pushboolean(L, rc == 0 && strncmp(reply, "OK", 2) == 0);
    lua_pushstring(L, reply);
    return 2;
}

// safari.load([giây]) → true/false, diag. Chờ trang web app foreground load XONG
// (document.readyState == 'complete'). Mặc định tối đa 60 giây (trần 600). Trả true nếu load xong,
// false nếu hết giờ / không có trang web foreground. Hàm ẨN (không có trong gợi ý syntax).
static int l_safariLoad(lua_State *L) {
    if (g_cancel) return luaL_error(L, "đã dừng");
    int timeout = (int)luaL_optinteger(L, 1, 60);
    char reply[600] = {0};
    int rc = touch_safari_load(timeout, reply, sizeof(reply));
    if (g_cancel) return luaL_error(L, "đã dừng");
    lua_pushboolean(L, rc == 0);
    lua_pushstring(L, reply);
    return 2;
}

// safari.eval(js) → chuỗi kết quả, hoặc nil+diag. Chạy JS TUỲ Ý trong WKWebView app foreground —
// DÙNG ĐỂ SOI DOM (outerHTML, querySelectorAll…) và viết selector chuẩn. `js` PHẢI `return` giá trị;
// object/mảng tự JSON.stringify. Kết quả đọc từ FILE nên KHÔNG bị giới hạn 1KB. Hàm ẨN.
//   VD: local html = safari.eval('return document.querySelector("#applyBtn").outerHTML')
static int l_safariEval(lua_State *L) {
    if (g_cancel) return luaL_error(L, "đã dừng");
    const char *js = luaL_checkstring(L, 1);
    char reply[800] = {0};
    int rc = touch_safari_eval(js, reply, sizeof(reply));
    if (g_cancel) return luaL_error(L, "đã dừng");
    if (rc != 0 || strncmp(reply, "OK", 2) != 0) {
        lua_pushnil(L);
        lua_pushstring(L, reply[0] ? reply : "safari.eval lỗi");
        return 2;
    }
    return push_result_file(L, reply, "webeval ");
}

// safari.dom(selector[, max=20]) → chuỗi JSON {count, items:[{i,tag,id,cls,rect:[x,y,w,h],html}]} của
// các element khớp `selector` (outerHTML cắt 2000 ký tự), hoặc nil+diag. Tiện ích soi DOM nhanh.
// LƯU Ý: selector nhúng trong nháy ĐƠN JS (CSS thường dùng nháy kép cho [attr="…"] nên OK); TRÁNH
// selector chứa dấu nháy đơn — trường hợp đó dùng safari.eval tự viết JS. Hàm ẨN.
static int l_safariDom(lua_State *L) {
    if (g_cancel) return luaL_error(L, "đã dừng");
    const char *sel = luaL_checkstring(L, 1);
    int maxn = (int)luaL_optinteger(L, 2, 20);
    if (maxn < 1) maxn = 1;
    if (maxn > 200) maxn = 200;
    char *js = malloc(strlen(sel) + 900);
    if (!js) return luaL_error(L, "oom");
    sprintf(js,
        "var L=document.querySelectorAll('%s'),o=[],n=Math.min(L.length,%d);"
        "for(var i=0;i<n;i++){var e=L[i],r=e.getBoundingClientRect();"
        "o.push({i:i,tag:e.tagName,id:e.id||'',cls:(e.className&&e.className.baseVal!==undefined?e.className.baseVal:e.className)||'',"
        "rect:[Math.round(r.left),Math.round(r.top),Math.round(r.width),Math.round(r.height)],"
        "html:(e.outerHTML||'').slice(0,2000)});}"
        "return JSON.stringify({count:L.length,items:o});",
        sel, maxn);
    char reply[800] = {0};
    int rc = touch_safari_eval(js, reply, sizeof(reply));
    free(js);
    if (g_cancel) return luaL_error(L, "đã dừng");
    if (rc != 0 || strncmp(reply, "OK", 2) != 0) {
        lua_pushnil(L);
        lua_pushstring(L, reply[0] ? reply : "safari.dom lỗi");
        return 2;
    }
    return push_result_file(L, reply, "webeval ");
}

// getSN() → serial number thiết bị (chuỗi) hoặc "" nếu không lấy được.
static int l_getSN(lua_State *L) {
    char sn[64] = {0};
    appctl_serial(sn, sizeof(sn));
    lua_pushstring(L, sn);
    return 1;
}

// setCaptureDelay(giây) — đặt khoảng nghỉ GIỮA mỗi lần chụp+so khớp trong waitForImage/
// tapImage/tapText/... Giãn nhịp để giảm tải GPU (tránh bị kill khi chụp liên tục).
// Ví dụ setCaptureDelay(0.5) = mỗi 0.5s mới chụp lại 1 lần. Giới hạn [0, 10]s. Trả delay đã đặt (giây).
static int l_setCaptureDelay(lua_State *L) {
    double sec = luaL_checknumber(L, 1);
    if (sec < 0) sec = 0;
    if (sec > 10) sec = 10;
    g_scan_delay_us = (long)(sec * 1e6);
    log_msg("lua: setCaptureDelay = %.0f ms", sec * 1000.0);
    lua_pushnumber(L, (double)g_scan_delay_us / 1e6);
    return 1;
}

// setCaptureInterval(minGiây [, ttlGiây]) — CỔNG CAPTURE TOÀN CỤC (chống quá tải render-server):
//   minGiây = tối thiểu giữa 2 lần CHỤP THẬT bất kỳ (kể cả stream) khi automation đang chạy.
//   ttlGiây = frame vừa chụp còn "mới" bao lâu → nhiều lời gọi image trong khoảng này DÙNG LẠI 1 frame.
static int l_setCaptureInterval(lua_State *L) {
    double minS = luaL_checknumber(L, 1);
    double ttlS = luaL_optnumber(L, 2, -1);
    fbcap_set_capture_interval(minS, ttlS);
    log_msg("lua: setCaptureInterval min=%.2fs ttl=%.2fs", minS, ttlS);
    lua_pushboolean(L, 1);
    return 1;
}

// spoof.app(bundle)            → random profile cho app.
// spoof.app(bundle, ios, model)→ set cụ thể iOS + model. Trả true,jsonProfile | false,err.
static int l_spoof_app(lua_State *L) {
    const char *bundle = luaL_checkstring(L, 1);
    char err[128] = {0}, prof[512] = {0};
    int rc;
    if (lua_isstring(L, 2) && lua_isstring(L, 3))
        rc = profilestore_apply_spec(bundle, lua_tostring(L, 2), lua_tostring(L, 3), prof, sizeof(prof), err, sizeof(err));
    else
        rc = profilestore_random_apply(bundle, prof, sizeof(prof), err, sizeof(err));
    if (rc != 0) { lua_pushboolean(L, 0); lua_pushstring(L, err[0] ? err : "spoof lỗi"); return 2; }
    lua_pushboolean(L, 1); lua_pushstring(L, prof); return 2;
}
// Các global setter đơn giản (áp cho app trong target list).
static int l_spoof_global(lua_State *L, const char *key) {
    const char *v = luaL_checkstring(L, 1);
    lua_pushboolean(L, profilestore_global_set(key, v) == 0); return 1;
}
static int l_spoof_name(lua_State *L)     { return l_spoof_global(L, "deviceName"); }
static int l_spoof_version(lua_State *L)  { return l_spoof_global(L, "systemVersion"); }
static int l_spoof_timezone(lua_State *L) { return l_spoof_global(L, "timezoneIdentifier"); }
static int l_spoof_region(lua_State *L)   { return l_spoof_global(L, "regionCode"); }
// spoof.carrier("Tên") hoặc spoof.carrier{name=..,mcc=..,mnc=..}. CHỈ lưu config (chưa enforce).
static int l_spoof_carrier(lua_State *L) {
    char nameb[64] = {0}, mccb[16] = {0}, mncb[16] = {0};
    if (lua_istable(L, 1)) {
        lua_getfield(L, 1, "name"); if (lua_tostring(L, -1)) strlcpy(nameb, lua_tostring(L, -1), sizeof(nameb)); lua_pop(L, 1);
        lua_getfield(L, 1, "mcc");  if (lua_tostring(L, -1)) strlcpy(mccb,  lua_tostring(L, -1), sizeof(mccb));  lua_pop(L, 1);
        lua_getfield(L, 1, "mnc");  if (lua_tostring(L, -1)) strlcpy(mncb,  lua_tostring(L, -1), sizeof(mncb));  lua_pop(L, 1);
    } else {
        strlcpy(nameb, luaL_checkstring(L, 1), sizeof(nameb));
    }
    int rc = profilestore_global_set_carrier(nameb[0] ? nameb : NULL, mccb[0] ? mccb : NULL, mncb[0] ? mncb : NULL);
    lua_pushboolean(L, rc == 0); return 1;
}
// spoof.random()       → random TOÀN BỘ identity chung (_global) cho mọi app trong target.
// spoof.random(bundle) → random profile riêng cho 1 app (= spoof.app(bundle)).
static int l_spoof_random(lua_State *L) {
    char err[128] = {0}, prof[512] = {0};
    int rc;
    if (lua_isstring(L, 1))
        rc = profilestore_random_apply(lua_tostring(L, 1), prof, sizeof(prof), err, sizeof(err));
    else
        rc = profilestore_random_global(prof, sizeof(prof));
    if (rc != 0) { lua_pushboolean(L, 0); lua_pushstring(L, err[0] ? err : "random lỗi"); return 2; }
    lua_pushboolean(L, 1); lua_pushstring(L, prof); return 2;
}
// spoof.target(bundle) → thêm app vào danh sách được spoof.
static int l_spoof_target(lua_State *L) {
    lua_pushboolean(L, profilestore_target_add(luaL_checkstring(L, 1)) == 0); return 1;
}
// spoof.clear([bundle]) → xoá gán 1 app (không bundle → xoá tất cả).
static int l_spoof_clear(lua_State *L) {
    const char *bundle = luaL_optstring(L, 1, NULL);
    lua_pushboolean(L, profilestore_clear((bundle && bundle[0]) ? bundle : NULL) == 0); return 1;
}
// spoof.reset() → xoá toàn bộ config (global + targets + per-app).
static int l_spoof_reset(lua_State *L) {
    (void)L; lua_pushboolean(L, profilestore_reset() == 0); return 1;
}
static void spoof_register(lua_State *L) {
    static const luaL_Reg fns[] = {
        {"app",      l_spoof_app},
        {"random",   l_spoof_random},      // spoof.random() = global; spoof.random(bundle) = per-app
        {"name",     l_spoof_name},
        {"version",  l_spoof_version},
        {"carrier",  l_spoof_carrier},
        {"timezone", l_spoof_timezone},
        {"region",   l_spoof_region},
        {"target",   l_spoof_target},
        {"clear",    l_spoof_clear},
        {"reset",    l_spoof_reset},
        {NULL, NULL},
    };
    luaL_newlib(L, fns);
    lua_setglobal(L, "spoof");
}

static void register_funcs(lua_State *L) {
    lua_register(L, "print", l_print);
    lua_register(L, "getSN", l_getSN);
    lua_register(L, "setCaptureDelay", l_setCaptureDelay);
    lua_register(L, "setCaptureInterval", l_setCaptureInterval);
    lua_register(L, "tap", l_tap);
    lua_register(L, "swipe", l_swipe);
    lua_register(L, "input", l_input);
    lua_register(L, "launch", l_launch);
    lua_register(L, "appRun", l_launch);   // alias tiện dùng (giống launch)
    lua_register(L, "kill", l_kill);
    lua_register(L, "clearAppData", l_clearAppData);
    lua_register(L, "sleep", l_sleep);
    lua_register(L, "home", l_home);
    lua_register(L, "wake", l_wake);
    lua_register(L, "setAirplane", l_setAirplane);
    lua_register(L, "log", l_log);
    lua_register(L, "toast", l_toast);
    lua_register(L, "dump", l_dump);
    lua_register(L, "tapDump", l_tapDump);   // hàm ẨN: tap theo text lấy từ dump (không có trong gợi ý)
    lua_register(L, "ocr", l_ocr);
    lua_register(L, "tapText", l_tapText);
    lua_register(L, "tapTextIndex", l_tapTextIndex);
    lua_register(L, "tapTextRegion", l_tapTextRegion);
    lua_register(L, "tapImage", l_tapImage);
    lua_register(L, "tapImageIndex", l_tapImageIndex);
    lua_register(L, "tapImageRegion", l_tapImageRegion);
    lua_register(L, "ocrTextRegion", l_ocrTextRegion);
    lua_register(L, "waitForText", l_waitForText);
    lua_register(L, "waitForImage", l_waitForImage);
    lua_register(L, "copyText", l_copyText);
    lua_register(L, "clipText", l_clipText);
    // Bảng ẨN `safari.*` (không đưa vào gợi ý syntax) — safari.fill(field, value) điền ô web.
    {
        static const luaL_Reg safariFns[] = { {"fill", l_safariFill}, {"type", l_safariType}, {"clear", l_safariClear}, {"swipe", l_safariSwipe}, {"click", l_safariClick}, {"checkbox", l_safariCheckbox}, {"load", l_safariLoad}, {"eval", l_safariEval}, {"dom", l_safariDom}, {NULL, NULL} };
        luaL_newlib(L, safariFns);
        lua_setglobal(L, "safari");
    }
    luaext_register(L);   // base64/JSON/HTTP/proxy/openUrl/deviceinfo/ip (Foundation, luaext.m)
    crane_register(L);    // bảng crane.* điều khiển tweak Crane (crane.m)
    spoof_register(L);    // bảng spoof.random(bundle) / spoof.clear([bundle])
}

// Hook đếm lệnh: kiểm tra cờ dừng → ném lỗi để thoát script (dừng vòng lặp Lua chặt).
static void cancel_hook(lua_State *L, lua_Debug *ar) {
    (void)ar;
    if (g_cancel) luaL_error(L, "đã dừng bởi người dùng");
}

// Luồng chạy script. arg = strdup(code), tự free.
static void *run_thread(void *arg) {
    char *code = (char *)arg;
    lua_State *L = luaL_newstate();
    if (!L) out_append("Lỗi: không tạo được Lua state\n");
    else {
        luaL_openlibs(L);
        register_funcs(L);
        lua_sethook(L, cancel_hook, LUA_MASKCOUNT, 5000);
        log_msg("lua: chạy script %zu byte (run #%d)", strlen(code), g_runid);
        iosauto_mem_log("run-start");
        if (luaL_dostring(L, code) != LUA_OK) {
            const char *err = lua_tostring(L, -1);
            out_append("Lỗi: "); out_append(err ? err : "?"); out_append("\n");
        }
        lua_close(L);
    }
    free(code);
    pthread_mutex_lock(&g_mu);
    g_busy = 0; g_done = 1;
    pthread_mutex_unlock(&g_mu);
    iosauto_mem_log("run-end");
    log_msg("lua: run #%d xong", g_runid);
    return NULL;
}

// Bắt đầu chạy nền. Trả runid (>0) nếu bắt đầu; 0 nếu ĐANG BẬN.
int lua_run_start(const char *code) {
    pthread_mutex_lock(&g_mu);
    if (g_busy) { pthread_mutex_unlock(&g_mu); return 0; }
    free(g_out); g_out = NULL; g_out_len = 0; g_out_cap = 0;
    g_out_at_bol = 1;
    g_cancel = 0; g_done = 0; g_busy = 1; g_start = time(NULL);
    int rid = ++g_runid;
    pthread_mutex_unlock(&g_mu);

    char *dup = strdup(code ? code : "");
    pthread_t th;
    if (!dup || pthread_create(&th, NULL, run_thread, dup) != 0) {
        free(dup);
        pthread_mutex_lock(&g_mu); g_busy = 0; g_done = 1; pthread_mutex_unlock(&g_mu);
        return 0;
    }
    pthread_detach(th);
    return rid;
}

void lua_run_stop(void) { g_cancel = 1; }

int lua_run_is_busy(void) {
    pthread_mutex_lock(&g_mu);
    int b = g_busy;
    pthread_mutex_unlock(&g_mu);
    return b;
}

int lua_run_cancelled(void) { return g_cancel; }

size_t lua_run_snapshot(int *busy, int *runid, long *elapsed, int *done,
                        char *out, size_t cap, size_t offset) {
    pthread_mutex_lock(&g_mu);
    if (busy) *busy = g_busy;
    if (runid) *runid = g_runid;
    if (elapsed) *elapsed = g_start ? (long)(time(NULL) - g_start) : 0;
    if (done) *done = g_done;
    size_t total = g_out_len;
    if (out && cap) {
        size_t st = offset < total ? offset : total;
        size_t n = total - st; if (n >= cap) n = cap - 1;
        if (n && g_out) memcpy(out, g_out + st, n);
        out[n] = '\0';
    }
    pthread_mutex_unlock(&g_mu);
    return total;
}
