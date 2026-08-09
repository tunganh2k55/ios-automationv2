#include "httpd.h"
#include "api.h"
#include "video.h"
#include "appctl.h"
#include "touch.h"
#include "lua_bind.h"
#include "scripts.h"
#include "scriptcrypt.h"
#include "images.h"
#include "fbcap.h"
#include "license.h"
#include "profilestore.h"
#include "log.h"
#include "ocr_direct.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <ifaddrs.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <net/if.h>
#include <unistd.h>
#include <errno.h>

static int g_port = 8080;
static int g_usb_port = 0;      // cổng USB (loopback 127.0.0.1) — 0 = tắt
static time_t g_start = 0;
static char g_running_app[256] = {0};

void api_init(int port, int usb_port) {
    g_port = port;
    g_usb_port = usb_port;
    g_start = time(NULL);
}

// ---- JSON parse tối giản (client do mình kiểm soát) ----
// Tìm "key" rồi trả con trỏ tới ký tự đầu của value (sau dấu ':').
static const char *find_value(const char *body, size_t len, const char *key) {
    char pat[64];
    snprintf(pat, sizeof(pat), "\"%s\"", key);
    if (len == 0) return NULL;
    // Dùng memmem để an toàn với body không NUL-terminated.
    const char *p = memmem(body, len, pat, strlen(pat));
    if (!p) return NULL;
    p += strlen(pat);
    const char *end = body + len;
    while (p < end && (*p == ' ' || *p == ':')) p++;
    return (p < end) ? p : NULL;
}

static int json_get_str(const char *body, size_t len, const char *key, char *out, size_t out_len) {
    const char *p = find_value(body, len, key);
    if (!p || *p != '"') return 0;
    p++;
    size_t o = 0;
    const char *end = body + len;
    while (p < end && *p != '"' && o + 1 < out_len) {
        if (*p == '\\' && p + 1 < end) {
            p++;
            switch (*p) {
                case 'n': out[o++] = '\n'; break;
                case 't': out[o++] = '\t'; break;
                case 'r': out[o++] = '\r'; break;
                case '"': out[o++] = '"'; break;
                case '\\': out[o++] = '\\'; break;
                case '/': out[o++] = '/'; break;
                default: out[o++] = *p; break;
            }
            p++;
        } else out[o++] = *p++;
    }
    out[o] = '\0';
    return 1;
}

static int json_get_double(const char *body, size_t len, const char *key, double *out) {
    const char *p = find_value(body, len, key);
    if (!p) return 0;
    *out = strtod(p, NULL);
    return 1;
}

static int json_get_int(const char *body, size_t len, const char *key, int *out) {
    double d;
    if (!json_get_double(body, len, key, &d)) return 0;
    *out = (int)d;
    return 1;
}

// Đọc cả file vào buffer malloc (NUL-terminated). Trả NULL nếu lỗi; *out_len = số byte.
static char *read_file_alloc(const char *path, long *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    if (sz < 0) sz = 0;
    char *buf = malloc((size_t)sz + 1);
    size_t rd = buf ? fread(buf, 1, (size_t)sz, f) : 0;
    fclose(f);
    if (!buf) return NULL;
    buf[rd] = '\0';
    if (out_len) *out_len = (long)rd;
    return buf;
}

// ---- Helpers response ----
static void resp_json(http_resp *r, int status, char *body_malloced) {
    // malloc hỏng (OOM) → body NULL. KHÔNG strlen(NULL) (crash) — trả 500 tĩnh, không sở hữu buffer.
    if (!body_malloced) {
        r->status = 500;
        r->content_type = "application/json";
        r->body = "{\"ok\":false,\"msg\":\"oom\"}";
        r->body_len = strlen(r->body);
        r->body_owned = 0;
        return;
    }
    r->status = status;
    r->content_type = "application/json";
    r->body = body_malloced;
    r->body_len = strlen(body_malloced);
    r->body_owned = 1;
}

static void resp_ok_msg(http_resp *r, int ok, const char *msg) {
    char *b = malloc(1400);
    if (!b) { resp_json(r, 500, NULL); return; }   // OOM → 500 tĩnh (đừng snprintf vào NULL)
    // escape " trong msg tối thiểu
    char esc[1024]; size_t o = 0;
    for (const char *s = msg; *s && o + 2 < sizeof(esc); s++) {
        if (*s == '"' || *s == '\\') esc[o++] = '\\';
        esc[o++] = *s;
    }
    esc[o] = '\0';
    snprintf(b, 1400, "{\"ok\":%s,\"msg\":\"%s\"}", ok ? "true" : "false", esc);
    resp_json(r, ok ? 200 : 500, b);
}

static void primary_ip(char *out, size_t out_len) {
    if (out_len) out[0] = '\0';
    struct ifaddrs *ifap = NULL;
    if (getifaddrs(&ifap) != 0) return;
    for (struct ifaddrs *ifa = ifap; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) continue;
        if (!(ifa->ifa_flags & IFF_UP)) continue;
        struct sockaddr_in *sa = (struct sockaddr_in *)ifa->ifa_addr;
        char ip[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &sa->sin_addr, ip, sizeof(ip));
        if (!strcmp(ip, "127.0.0.1")) continue;
        // ưu tiên interface wifi en0
        if (strncmp(ifa->ifa_name, "en", 2) == 0) { snprintf(out, out_len, "%s", ip); break; }
        if (out[0] == '\0') snprintf(out, out_len, "%s", ip);
    }
    freeifaddrs(ifap);
}

// ghi hết len byte, trả 0 nếu client rớt (để dừng vòng lặp stream).
static int write_all_ok(int fd, const char *buf, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, buf + off, len - off);
        if (n <= 0) { if (n < 0 && errno == EINTR) continue; return 0; }
        off += (size_t)n;
    }
    return 1;
}

// ---- Stream MJPEG (multipart/x-mixed-replace) ----
// Đẩy khung liên tục qua MỘT kết nối (thay vì web poll từng ảnh). Trình duyệt
// render trong <img> như video. Chiếm riêng 1 thread (httpd thread-per-conn).
#define IA_MAX_JPEG (1024 * 1024)
void api_stream_mjpeg(int fd) {
    const char *hdr =
        "HTTP/1.1 200 OK\r\n"
        "Content-Type: multipart/x-mixed-replace; boundary=iaframe\r\n"
        "Cache-Control: no-cache, no-store, must-revalidate\r\n"
        "Pragma: no-cache\r\n"
        "Connection: close\r\n"
        "Access-Control-Allow-Origin: *\r\n\r\n";
    if (!write_all_ok(fd, hdr, strlen(hdr))) return;

    // Daemon CHỤP THẲNG framebuffer (fbcap: CARenderServer+IOSurfaceAccelerator, có entitlement
    // global/secure-capture → KHÔNG đen kể cả khi SpringBoard chuyển trang). Không cần tweak/SpringBoard.
    int fails = 0;
    for (;;) {
        unsigned char *jpg = NULL; size_t n = 0;
        int rc = fbcap_jpeg(&jpg, &n, 0.7, 45);
        if (rc != 0 || !jpg || n == 0) {
            free(jpg);
            if (++fails > 100) break;   // ~5s liên tục lỗi → đóng
            usleep(50 * 1000);
            continue;
        }
        fails = 0;
        char part[160];
        int pn = snprintf(part, sizeof(part),
            "--iaframe\r\nContent-Type: image/jpeg\r\nContent-Length: %zu\r\n\r\n", n);
        int ok = write_all_ok(fd, part, (size_t)pn) && write_all_ok(fd, (char *)jpg, n) && write_all_ok(fd, "\r\n", 2);
        free(jpg);
        if (!ok) break;
        usleep(20 * 1000);   // nhường CPU; fbcap đã ~60-90ms/khung
    }
}

// ---- Router ----
int api_handle(const http_req *req, http_resp *resp) {
    const char *route = req->path + 5;   // sau "/api/"
    const char *b = req->body;
    size_t bl = req->body_len;

    // GET status
    if (!strcmp(route, "status")) {
        char name[128] = {0}, model[64] = {0}, ios[32] = {0}, ip[64] = {0}, serial[64] = {0};
        appctl_device_info(name, sizeof(name), model, sizeof(model), ios, sizeof(ios));
        appctl_serial(serial, sizeof(serial));
        primary_ip(ip, sizeof(ip));
        int sw = 390, sh = 844;
        touch_screen_size(&sw, &sh);   // kích thước màn thật (từ tweak) → web scale đúng
        char *body = malloc(1024);
        if (!body) { resp_json(resp, 500, NULL); return 1; }
        snprintf(body, 1024,
            "{\"ok\":true,\"device\":{\"name\":\"%s\",\"model\":\"%s\",\"ios\":\"%s\",\"serial\":\"%s\"},"
            "\"ip\":\"%s\",\"port\":%d,\"usbPort\":%d,\"screen\":{\"w\":%d,\"h\":%d},"
            "\"runningApp\":%s%s%s,\"uptime\":%ld}",
            name, model, ios, serial, ip, g_port, g_usb_port, sw, sh,
            g_running_app[0] ? "\"" : "null", g_running_app[0] ? g_running_app : "", g_running_app[0] ? "\"" : "",
            (long)(time(NULL) - g_start));
        resp_json(resp, 200, body);
        return 1;
    }

    // GET license — trạng thái bản quyền thiết bị (app/web/script đều hỏi route này).
    if (!strcmp(route, "license")) {
        char *body = malloc(2048);
        if (!body) { resp_json(resp, 500, NULL); return 1; }
        license_status_json(body, 2048);
        resp_json(resp, 200, body);
        return 1;
    }
    // POST license/activate {key} — lưu key + activate/device + verify.
    if (!strcmp(route, "license/activate")) {
        char key[128] = {0}, msg[256] = {0};
        json_get_str(b, bl, "key", key, sizeof(key));
        int ok = license_activate(key, msg, sizeof(msg));
        resp_ok_msg(resp, ok, msg);
        return 1;
    }
    // POST license/server {url} — đổi URL máy chủ license.
    if (!strcmp(route, "license/server")) {
        char url[256] = {0};
        json_get_str(b, bl, "url", url, sizeof(url));
        int ok = license_set_server(url);
        resp_ok_msg(resp, ok, ok ? "Đã đặt máy chủ" : "URL không hợp lệ");
        return 1;
    }
    // POST license/clear — xoá kích hoạt.
    if (!strcmp(route, "license/clear")) {
        license_clear();
        resp_ok_msg(resp, 1, "Đã xoá kích hoạt");
        return 1;
    }

    // GET apps — chỉ app User (web UI launcher).
    if (!strcmp(route, "apps")) {
        char *arr = malloc(64 * 1024);
        char *body = malloc(64 * 1024 + 32);
        if (!arr || !body) { free(arr); free(body); resp_json(resp, 500, NULL); return 1; }
        appctl_list_json(arr, 64 * 1024);
        snprintf(body, 64 * 1024 + 32, "{\"ok\":true,\"apps\":%s}", arr);
        free(arr);
        resp_json(resp, 200, body);
        return 1;
    }
    // GET apps_all — User + System (tab Profiles: chọn app để spoof, gồm Safari…).
    if (!strcmp(route, "apps_all")) {
        char *arr = malloc(128 * 1024);
        char *body = malloc(128 * 1024 + 32);
        if (!arr || !body) { free(arr); free(body); resp_json(resp, 500, NULL); return 1; }
        appctl_list_all_json(arr, 128 * 1024);
        snprintf(body, 128 * 1024 + 32, "{\"ok\":true,\"apps\":%s}", arr);
        free(arr);
        resp_json(resp, 200, body);
        return 1;
    }

    // GET profile/list — bảng gán bundleId→profile (tweak spoof đọc plist này).
    if (!strcmp(route, "profile/list")) {
        char *arr = malloc(32 * 1024);
        char *body = malloc(32 * 1024 + 32);
        if (!arr || !body) { free(arr); free(body); resp_json(resp, 500, NULL); return 1; }
        profilestore_list_json(arr, 32 * 1024);
        snprintf(body, 32 * 1024 + 32, "{\"ok\":true,\"assignments\":%s}", arr);
        free(arr);
        resp_json(resp, 200, body);
        return 1;
    }
    // POST profile/apply {bundleId, deviceModel, hardwareIdentifier, systemName, systemVersion,
    //   deviceName, localeIdentifier, languageCode, timezoneIdentifier, screenWidth, screenHeight, screenScale}
    if (!strcmp(route, "profile/apply")) {
        char bundle[256] = {0}, model[64] = {0}, hwid[64] = {0}, sysname[32] = {0}, sysver[32] = {0};
        char devname[64] = {0}, locale[32] = {0}, lang[16] = {0}, tz[64] = {0};
        json_get_str(b, bl, "bundleId", bundle, sizeof(bundle));
        json_get_str(b, bl, "deviceModel", model, sizeof(model));
        json_get_str(b, bl, "hardwareIdentifier", hwid, sizeof(hwid));
        json_get_str(b, bl, "systemName", sysname, sizeof(sysname));
        json_get_str(b, bl, "systemVersion", sysver, sizeof(sysver));
        json_get_str(b, bl, "deviceName", devname, sizeof(devname));
        json_get_str(b, bl, "localeIdentifier", locale, sizeof(locale));
        json_get_str(b, bl, "languageCode", lang, sizeof(lang));
        json_get_str(b, bl, "timezoneIdentifier", tz, sizeof(tz));
        int sw = 0, sh = 0; double scale = 0;
        json_get_int(b, bl, "screenWidth", &sw);
        json_get_int(b, bl, "screenHeight", &sh);
        json_get_double(b, bl, "screenScale", &scale);
        char err[128] = {0};
        int rc = profilestore_apply(bundle, model, hwid, sysname, sysver, devname,
                                    locale, lang, tz, sw, sh, scale, err, sizeof(err));
        resp_ok_msg(resp, rc == 0, rc == 0 ? "Đã gán profile cho app (mở lại app để có hiệu lực)" : err);
        return 1;
    }
    // POST profile/random {bundleId?} — có bundleId: random 1 app; không có: random global (mọi target).
    if (!strcmp(route, "profile/random")) {
        char bundle[256] = {0};
        json_get_str(b, bl, "bundleId", bundle, sizeof(bundle));
        char err[128] = {0}, prof[512] = {0};
        int rc = bundle[0] ? profilestore_random_apply(bundle, prof, sizeof(prof), err, sizeof(err))
                           : profilestore_random_global(prof, sizeof(prof));
        if (rc == 0) {
            char *body = malloc(768);
            if (!body) { resp_json(resp, 500, NULL); return 1; }
            snprintf(body, 768, "{\"ok\":true,\"msg\":\"Đã spoof ngẫu nhiên\",\"profile\":%s}", prof);
            resp_json(resp, 200, body);
        } else {
            resp_ok_msg(resp, 0, err[0] ? err : "random lỗi");
        }
        return 1;
    }
    // POST profile/clear {bundleId?} — bundleId rỗng → xoá tất cả gán.
    if (!strcmp(route, "profile/clear")) {
        char bundle[256] = {0};
        json_get_str(b, bl, "bundleId", bundle, sizeof(bundle));
        int rc = profilestore_clear(bundle[0] ? bundle : NULL);
        resp_ok_msg(resp, rc == 0, rc == 0 ? "Đã xoá gán" : "Xoá gán lỗi");
        return 1;
    }

    // GET log
    if (!strcmp(route, "log")) {
        char *arr = malloc(48 * 1024);
        char *body = malloc(48 * 1024 + 32);
        if (!arr || !body) { free(arr); free(body); resp_json(resp, 500, NULL); return 1; }
        log_json(arr, 48 * 1024);
        snprintf(body, 48 * 1024 + 32, "{\"ok\":true,\"lines\":%s}", arr);
        free(arr);
        resp_json(resp, 200, body);
        return 1;
    }

    // GET screenshot — chụp CẢ MÀN qua SpringBoard (touch_shot prefer_sb=1). KHÔNG dùng
    // Daemon chụp thẳng framebuffer (fbcap) — không đen, không cần SpringBoard.
    if (!strcmp(route, "screenshot")) {
        unsigned char *jpg = NULL; size_t n = 0;
        int rc = fbcap_jpeg(&jpg, &n, 0.7, 60);
        if (rc != 0 || !jpg) {
            free(jpg);
            char *m = malloc(64); snprintf(m, 64, "fbcap lỗi rc=%d", rc);
            resp->status = 500; resp->content_type = "text/plain; charset=utf-8";
            resp->body = m; resp->body_len = strlen(m); resp->body_owned = 1;
            return 1;
        }
        resp->status = 200; resp->content_type = "image/jpeg";
        resp->body = (char *)jpg; resp->body_len = n; resp->body_owned = 1;
        return 1;
    }

    // GET dump — xuất cây UIView của app foreground thành XML (page source).
    if (!strcmp(route, "dump")) {
        char reply[800] = {0};
        int rc = touch_dump(reply, sizeof(reply));
        char *path = strstr(reply, "dump ");
        if (rc != 0 || !path) {
            char *m = malloc(256);
            snprintf(m, 256, "dump lỗi: %s", reply[0] ? reply : "no-reply");
            resp->status = 503; resp->content_type = "text/plain; charset=utf-8";
            resp->body = m; resp->body_len = strlen(m); resp->body_owned = 1;
            return 1;
        }
        path += 5;
        char *nl = strpbrk(path, "\r\n"); if (nl) *nl = '\0';
        long n = 0;
        char *buf = read_file_alloc(path, &n);
        if (!buf) {
            const char *msg = "không đọc được file dump";
            resp->status = 500; resp->content_type = "text/plain; charset=utf-8";
            resp->body = (char *)msg; resp->body_len = strlen(msg); resp->body_owned = 0;
            return 1;
        }
        resp->status = 200; resp->content_type = "application/xml; charset=utf-8";
        resp->body = buf; resp->body_len = (size_t)n; resp->body_owned = 1;
        return 1;
    }

    // OCR — nhận dạng chữ qua Vision. Body tuỳ chọn {"lang":"ja,en-US"} (mặc định en-US,vi-VN).
    // Thử tweak trước; nếu không có app foreground thì fallback sang OCR trực tiếp trong daemon.
    if (!strcmp(route, "ocr")) {
        char lang[80] = {0};
        json_get_str(b, bl, "lang", lang, sizeof(lang));
        char reply[900] = {0};
        int rc = touch_ocr(reply, sizeof(reply), lang[0] ? lang : NULL);
        char *path = strstr(reply, "ocr ");
        // Fallback: tweak lỗi hoặc "cần app foreground" → chạy OCR trực tiếp trong daemon
        if (rc != 0 || !path) {
            int sw = 0, sh = 0;
            touch_screen_size(&sw, &sh);
            char err[256] = {0};
            char *json = ocr_direct_run(lang[0] ? lang : NULL, 0, 0, 0, 0, sw, sh, err, sizeof(err));
            if (!json) {
                resp_ok_msg(resp, 0, err[0] ? err : "ocr lỗi (cả tweak lẫn daemon)");
                return 1;
            }
            size_t jlen = strlen(json);
            char *body = malloc(jlen + 32);
            if (!body) { free(json); resp_ok_msg(resp, 0, "oom"); return 1; }
            int hn = snprintf(body, 32, "{\"ok\":true,\"lines\":");
            memcpy(body + hn, json, jlen);
            body[hn + jlen] = '}'; body[hn + jlen + 1] = '\0';
            free(json);
            resp->status = 200; resp->content_type = "application/json";
            resp->body = body; resp->body_len = (size_t)(hn + jlen + 1); resp->body_owned = 1;
            log_msg("ocr: fallback direct (tweak unavailable)");
            return 1;
        }
        path += 4;
        char *nl = strpbrk(path, "\r\n"); if (nl) *nl = '\0';
        long n = 0;
        char *arr = read_file_alloc(path, &n);
        if (!arr) { resp_ok_msg(resp, 0, "không đọc được file ocr"); return 1; }
        // Bọc {"ok":true,"lines":<mảng>}
        char *body = malloc((size_t)n + 64);
        if (!body) { free(arr); resp_ok_msg(resp, 0, "oom"); return 1; }
        int hn = snprintf(body, 64, "{\"ok\":true,\"lines\":");
        memcpy(body + hn, arr, (size_t)n);
        body[hn + n] = '}'; body[hn + n + 1] = '\0';
        free(arr);
        resp->status = 200; resp->content_type = "application/json";
        resp->body = body; resp->body_len = (size_t)(hn + n + 1); resp->body_owned = 1;
        return 1;
    }

    // GET fbshot — TEST chụp framebuffer thật từ daemon (như TrollVNC). Trả JPEG.
    if (!strcmp(route, "fbshot")) {
        unsigned char *buf = NULL; size_t n = 0;
        int rc = fbcap_jpeg(&buf, &n, 0.7, 50);
        if (rc != 0 || !buf) {
            char *m = malloc(80);
            snprintf(m, 80, "fbcap lỗi rc=%d (entitlement/framebuffer?)", rc);
            resp->status = 500; resp->content_type = "text/plain; charset=utf-8";
            resp->body = m; resp->body_len = strlen(m); resp->body_owned = 1;
            return 1;
        }
        resp->status = 200; resp->content_type = "image/jpeg";
        resp->body = (char *)buf; resp->body_len = n; resp->body_owned = 1;
        return 1;
    }

    // OCR trực tiếp trong daemon (không cần tweak) — Body tuỳ chọn {"lang":"en-US,vi-VN"}
    if (!strcmp(route, "ocr2")) {
        char lang[80] = {0};
        json_get_str(b, bl, "lang", lang, sizeof(lang));
        int sw = 0, sh = 0;
        touch_screen_size(&sw, &sh);
        char err[256] = {0};
        char *json = ocr_direct_run(lang[0] ? lang : NULL, 0, 0, 0, 0, sw, sh, err, sizeof(err));
        if (!json) {
            resp_ok_msg(resp, 0, err[0] ? err : "ocr2 lỗi");
            return 1;
        }
        size_t jlen = strlen(json);
        char *body = malloc(jlen + 32);
        if (!body) { free(json); resp_ok_msg(resp, 0, "oom"); return 1; }
        int hn = snprintf(body, 32, "{\"ok\":true,\"lines\":");
        memcpy(body + hn, json, jlen);
        body[hn + jlen] = '}'; body[hn + jlen + 1] = '\0';
        free(json);
        resp->status = 200; resp->content_type = "application/json";
        resp->body = body; resp->body_len = (size_t)(hn + jlen + 1); resp->body_owned = 1;
        log_msg("ocr2: direct vision ocr (screen %dx%d)", sw, sh);
        return 1;
    }

    // GET vtrec — SPIKE VideoToolbox: quay H.264 3s trong SpringBoard, trả stats.
    if (!strcmp(route, "vtrec")) {
        char reply[400] = {0};
        int rc = touch_vtrec(reply, sizeof(reply), 3);
        resp_ok_msg(resp, rc == 0, reply);
        return 1;
    }

    // POST launch
    if (!strcmp(route, "launch")) {
        char bid[256] = {0}, err[256] = {0};
        if (!json_get_str(b, bl, "bundleId", bid, sizeof(bid))) { resp_ok_msg(resp, 0, "thiếu bundleId"); return 1; }
        int rc = appctl_launch(bid, err, sizeof(err));
        if (rc == 0) { strncpy(g_running_app, bid, sizeof(g_running_app) - 1); log_msg("launch %s", bid); }
        resp_ok_msg(resp, rc == 0, err);
        return 1;
    }

    // POST kill
    if (!strcmp(route, "kill")) {
        char bid[256] = {0}, err[256] = {0};
        if (!json_get_str(b, bl, "bundleId", bid, sizeof(bid))) { resp_ok_msg(resp, 0, "thiếu bundleId"); return 1; }
        int rc = appctl_kill(bid, err, sizeof(err));
        if (rc == 0 && !strcmp(g_running_app, bid)) g_running_app[0] = '\0';
        if (rc == 0) log_msg("kill %s", bid);
        resp_ok_msg(resp, rc == 0, err);
        return 1;
    }

    // POST cleardata — xoá toàn bộ dữ liệu app (reset về như mới cài; tự kill app trước).
    if (!strcmp(route, "cleardata")) {
        char bid[256] = {0}, err[256] = {0}; int removed = 0;
        if (!json_get_str(b, bl, "bundleId", bid, sizeof(bid))) { resp_ok_msg(resp, 0, "thiếu bundleId"); return 1; }
        int rc = appctl_clear_data(bid, &removed, err, sizeof(err));
        if (rc == 0 && !strcmp(g_running_app, bid)) g_running_app[0] = '\0';
        if (rc == 0) log_msg("cleardata %s (%d mục)", bid, removed);
        resp_ok_msg(resp, rc == 0, err);
        return 1;
    }

    // POST tap
    if (!strcmp(route, "tap")) {
        int x = 0, y = 0; char err[128] = {0};
        json_get_int(b, bl, "x", &x); json_get_int(b, bl, "y", &y);
        int rc = touch_tap(x, y, err, sizeof(err));
        resp_ok_msg(resp, rc == 0, err);
        return 1;
    }

    // POST swipe
    if (!strcmp(route, "swipe")) {
        int x1 = 0, y1 = 0, x2 = 0, y2 = 0; double dur = 0.3; char err[128] = {0};
        json_get_int(b, bl, "x1", &x1); json_get_int(b, bl, "y1", &y1);
        json_get_int(b, bl, "x2", &x2); json_get_int(b, bl, "y2", &y2);
        json_get_double(b, bl, "duration", &dur);
        int rc = touch_swipe(x1, y1, x2, y2, dur, err, sizeof(err));
        resp_ok_msg(resp, rc == 0, err);
        return 1;
    }

    // POST home — về màn hình chính.
    if (!strcmp(route, "home")) {
        char err[128] = {0};
        int rc = touch_raw("HOME", err, sizeof(err));
        resp_ok_msg(resp, rc == 0, err);
        return 1;
    }

    // POST switcher — Home 2 lần → App Switcher.
    if (!strcmp(route, "switcher")) {
        char err[200] = {0};
        int rc = touch_switcher(err, sizeof(err));
        resp_ok_msg(resp, rc == 0, err);
        return 1;
    }

    // POST appearance — đổi Dark Mode toàn máy {mode:0=theo hệ thống,1=sáng,2=tối}.
    if (!strcmp(route, "appearance")) {
        int mode = 0; char err[600] = {0};
        json_get_int(b, bl, "mode", &mode);
        int rc = touch_appearance(mode, err, sizeof(err));
        resp_ok_msg(resp, rc == 0, err);
        return 1;
    }

    // POST wake — bật màn hình + mở khoá (ưu tiên SpringBoard; msg cho biết trước đó khoá/mở).
    if (!strcmp(route, "wake")) {
        char err[128] = {0};
        int rc = touch_wake(err, sizeof(err));
        resp_ok_msg(resp, rc == 0, err);
        return 1;
    }

    // POST type — gõ chữ vào ô nhập đang focus.
    if (!strcmp(route, "type")) {
        char text[512] = {0}, err[600] = {0}, verb[560];
        json_get_str(b, bl, "text", text, sizeof(text));
        snprintf(verb, sizeof(verb), "TYPE %s", text);
        int rc = touch_raw(verb, err, sizeof(err));
        resp_ok_msg(resp, rc == 0, err);
        return 1;
    }

    // POST touchcmd — gửi verb thô tới tweak (debug: DUMP, PING).
    if (!strcmp(route, "touchcmd")) {
        char cmd[200] = {0}, err[600] = {0};
        if (!json_get_str(b, bl, "cmd", cmd, sizeof(cmd))) { resp_ok_msg(resp, 0, "thiếu cmd"); return 1; }
        int rc = touch_raw(cmd, err, sizeof(err));
        resp_ok_msg(resp, rc == 0, err);
        return 1;
    }

    // POST script — BẮT ĐẦU chạy Lua ở luồng NỀN, trả runid NGAY (không chờ xong).
    // Đang bận (script khác chạy) → ok:false + runid hiện tại. Theo dõi qua /api/run + /api/run/log.
    // TỰ NHẬN DIỆN: nếu `code` là blob .luax đã mã hoá → giải mã + verify trong RAM rồi mới chạy
    // (không bao giờ ghi plaintext ra đĩa). Chữ ký sai / bị sửa → từ chối chạy.
    if (!strcmp(route, "script")) {
        char *code = malloc(128 * 1024);
        if (!code) { resp_ok_msg(resp, 0, "oom"); return 1; }
        if (!json_get_str(b, bl, "code", code, 128 * 1024)) code[0] = '\0';
        if (scriptcrypt_looks_encrypted(code, strlen(code))) {
            char *plain = malloc(128 * 1024);
            if (!plain) { free(code); resp_ok_msg(resp, 0, "oom"); return 1; }
            long m = scriptcrypt_decrypt(code, strlen(code), plain, 128 * 1024);
            if (m < 0) {
                free(plain); free(code);
                resp_ok_msg(resp, 0, "script mã hoá không hợp lệ (sai chữ ký hoặc đã bị sửa)");
                return 1;
            }
            memcpy(code, plain, (size_t)m + 1);
            free(plain);
        }
        int rid = lua_run_start(code);
        free(code);
        char *body = malloc(160);
        if (rid > 0) snprintf(body, 160, "{\"ok\":true,\"running\":true,\"runid\":%d}", rid);
        else {
            int cur = 0; lua_run_snapshot(NULL, &cur, NULL, NULL, NULL, 0, 0);
            snprintf(body, 160, "{\"ok\":false,\"running\":true,\"runid\":%d,\"msg\":\"đang chạy script khác\"}", cur);
        }
        resp_json(resp, 200, body);
        return 1;
    }

    // GET run — thiết bị đang RẢNH hay BẬN? Đang chạy → trả runid (để theo dõi).
    if (!strcmp(route, "run")) {
        int busy = 0, rid = 0, done = 0; long el = 0;
        size_t total = lua_run_snapshot(&busy, &rid, &el, &done, NULL, 0, 0);
        char *body = malloc(220);
        if (!body) { resp_json(resp, 500, NULL); return 1; }
        snprintf(body, 220,
            "{\"ok\":true,\"idle\":%s,\"busy\":%s,\"running\":%s,\"runid\":%d,\"done\":%s,\"elapsed\":%ld,\"logLen\":%zu}",
            busy ? "false" : "true", busy ? "true" : "false", busy ? "true" : "false",
            rid, done ? "true" : "false", el, total);
        resp_json(resp, 200, body);
        return 1;
    }

    // POST run/log {offset?} — đọc log của lần chạy hiện tại/gần nhất từ `offset` (mặc định 0).
    // Trả {runid,running,done,offset,total,log}. Dùng `total` làm offset lần sau để theo dõi tăng dần.
    // (Tiện tích hợp tool khác: gọi lặp với offset=total trước đó.)
    if (!strcmp(route, "run/log")) {
        int offset = 0; json_get_int(b, bl, "offset", &offset);
        if (offset < 0) offset = 0;
        size_t cap = 64 * 1024;
        char *chunk = malloc(cap);
        if (!chunk) { resp_ok_msg(resp, 0, "oom"); return 1; }
        int busy = 0, rid = 0, done = 0; long el = 0;
        size_t total = lua_run_snapshot(&busy, &rid, &el, &done, chunk, cap, (size_t)offset);
        size_t chunkLen = strlen(chunk);               // số byte thực đã lấy (để tính offset kế)
        size_t next = (size_t)offset + chunkLen;
        char *body = malloc(cap * 2 + 512);
        if (!body) { free(chunk); resp_json(resp, 500, NULL); return 1; }
        size_t o = (size_t)snprintf(body, 256,
            "{\"ok\":true,\"runid\":%d,\"running\":%s,\"done\":%s,\"offset\":%d,\"next\":%zu,\"total\":%zu,\"log\":\"",
            rid, busy ? "true" : "false", done ? "true" : "false", offset, next, total);
        for (char *s = chunk; *s; s++) {
            unsigned char c = (unsigned char)*s;
            if (c == '"' || c == '\\') { body[o++] = '\\'; body[o++] = c; }
            else if (c == '\n') { body[o++] = '\\'; body[o++] = 'n'; }
            else if (c == '\t') { body[o++] = '\\'; body[o++] = 't'; }
            else if (c == '\r') { }
            else if (c >= 0x20) body[o++] = c;
        }
        body[o++] = '"'; body[o++] = '}'; body[o] = '\0';
        resp_json(resp, 200, body);
        free(chunk);
        return 1;
    }

    // POST run/stop — yêu cầu dừng script đang chạy. LOG để truy ai gọi (app nền/nút Dừng…).
    if (!strcmp(route, "run/stop")) {
        int cur = 0, busy = 0; lua_run_snapshot(&busy, &cur, NULL, NULL, NULL, 0, 0);
        log_msg("api: /run/stop ĐƯỢC GỌI (busy=%d runid=%d)", busy, cur);
        lua_run_stop();
        resp_ok_msg(resp, 1, "đã yêu cầu dừng");
        return 1;
    }

    // GET scripts — liệt kê file script.
    if (!strcmp(route, "scripts")) {
        char *arr = malloc(32 * 1024);
        char *body = malloc(32 * 1024 + 32);
        if (!arr || !body) { free(arr); free(body); resp_json(resp, 500, NULL); return 1; }
        scripts_list_json(arr, 32 * 1024);
        snprintf(body, 32 * 1024 + 32, "{\"ok\":true,\"files\":%s}", arr);
        free(arr);
        resp_json(resp, 200, body);
        return 1;
    }

    // POST script_read {name} — đọc nội dung 1 file.
    if (!strcmp(route, "script_read")) {
        char name[80] = {0};
        if (!json_get_str(b, bl, "name", name, sizeof(name)) || !scripts_valid_name(name)) {
            resp_ok_msg(resp, 0, "tên file không hợp lệ"); return 1;
        }
        char *buf = malloc(192 * 1024);
        long n = buf ? scripts_read(name, buf, 192 * 1024) : -1;
        if (n < 0) { free(buf); resp_ok_msg(resp, 0, "không đọc được file"); return 1; }
        // Đóng gói {"ok":true,"name":"..","content":"<escaped>"}
        char *body = malloc(192 * 1024 * 2 + 256);
        if (!body) { free(buf); resp_json(resp, 500, NULL); return 1; }
        size_t o = (size_t)snprintf(body, 256, "{\"ok\":true,\"name\":\"%s\",\"content\":\"", name);
        for (char *s = buf; *s; s++) {
            unsigned char c = (unsigned char)*s;
            if (c == '"' || c == '\\') { body[o++] = '\\'; body[o++] = c; }
            else if (c == '\n') { body[o++] = '\\'; body[o++] = 'n'; }
            else if (c == '\r') { body[o++] = '\\'; body[o++] = 'r'; }
            else if (c == '\t') { body[o++] = '\\'; body[o++] = 't'; }
            else if (c >= 0x20) body[o++] = c;
        }
        body[o++] = '"'; body[o++] = '}'; body[o] = '\0';
        free(buf);
        resp_json(resp, 200, body);
        return 1;
    }

    // POST script_save {name, content} — lưu file.
    if (!strcmp(route, "script_save")) {
        char name[80] = {0};
        if (!json_get_str(b, bl, "name", name, sizeof(name)) || !scripts_valid_name(name)) {
            resp_ok_msg(resp, 0, "tên file không hợp lệ (chỉ chữ/số . _ -, tối đa 64)"); return 1;
        }
        char *content = malloc(128 * 1024);
        if (!content) { resp_ok_msg(resp, 0, "oom"); return 1; }
        if (!json_get_str(b, bl, "content", content, 128 * 1024)) content[0] = '\0';
        int rc = scripts_save(name, content, strlen(content));
        free(content);
        resp_ok_msg(resp, rc == 0, rc == 0 ? "đã lưu" : "lưu lỗi");
        return 1;
    }

    // POST script_encrypt {content} — mã hoá + ký plaintext Lua → trả blob .luax (base64).
    // Bảo vệ mã nguồn: khoá nhúng trong app, một chiều (không có khoá thì không giải mã lại được).
    if (!strcmp(route, "script_encrypt")) {
        char *content = malloc(128 * 1024);
        if (!content) { resp_ok_msg(resp, 0, "oom"); return 1; }
        if (!json_get_str(b, bl, "content", content, 128 * 1024)) content[0] = '\0';
        size_t plen = strlen(content);
        if (plen == 0) { free(content); resp_ok_msg(resp, 0, "nội dung rỗng"); return 1; }
        if (scriptcrypt_looks_encrypted(content, plen)) {
            free(content); resp_ok_msg(resp, 0, "nội dung đã được mã hoá rồi"); return 1;
        }
        size_t cap = 192 * 1024;
        char *blob = malloc(cap);
        if (!blob) { free(content); resp_ok_msg(resp, 0, "oom"); return 1; }
        long n = scriptcrypt_encrypt(content, plen, blob, cap);
        free(content);
        if (n < 0) { free(blob); resp_ok_msg(resp, 0, "mã hoá lỗi"); return 1; }
        char *body = malloc(cap + 64);
        if (!body) { free(blob); resp_ok_msg(resp, 0, "oom"); return 1; }
        size_t o = (size_t)snprintf(body, 48, "{\"ok\":true,\"blob\":\"");
        memcpy(body + o, blob, (size_t)n); o += (size_t)n;   // base64 an toàn trong JSON string
        body[o++] = '"'; body[o++] = '}'; body[o] = '\0';
        free(blob);
        resp_json(resp, 200, body);
        return 1;
    }

    // POST script_delete {name} — xoá file.
    if (!strcmp(route, "script_delete")) {
        char name[80] = {0};
        if (!json_get_str(b, bl, "name", name, sizeof(name)) || !scripts_valid_name(name)) {
            resp_ok_msg(resp, 0, "tên file không hợp lệ"); return 1;
        }
        int rc = scripts_delete(name);
        resp_ok_msg(resp, rc == 0, rc == 0 ? "đã xoá" : "xoá lỗi");
        return 1;
    }

    // GET images — liệt kê ảnh đã lưu.
    if (!strcmp(route, "images")) {
        char *arr = malloc(32 * 1024);
        char *body = malloc(32 * 1024 + 32);
        if (!arr || !body) { free(arr); free(body); resp_json(resp, 500, NULL); return 1; }
        images_list_json(arr, 32 * 1024);
        snprintf(body, 32 * 1024 + 32, "{\"ok\":true,\"images\":%s}", arr);
        free(arr);
        resp_json(resp, 200, body);
        return 1;
    }

    // POST image_save {name, data} — data là base64 ảnh (đã cắt) → lưu vào thư mục images.
    if (!strcmp(route, "image_save")) {
        char name[96] = {0};
        if (!json_get_str(b, bl, "name", name, sizeof(name)) || !images_valid_name(name)) {
            resp_ok_msg(resp, 0, "tên ảnh không hợp lệ (chữ/số . _ -)"); return 1;
        }
        size_t dcap = 6 * 1024 * 1024;                 // đủ cho ảnh cắt lớn
        char *data = malloc(dcap);
        if (!data) { resp_ok_msg(resp, 0, "oom"); return 1; }
        if (!json_get_str(b, bl, "data", data, dcap)) { free(data); resp_ok_msg(resp, 0, "thiếu data"); return 1; }
        int rc = images_save_b64(name, data, strlen(data));
        free(data);
        resp_ok_msg(resp, rc == 0, rc == 0 ? "đã lưu ảnh" : "lưu ảnh lỗi");
        return 1;
    }

    // POST image_read {name} — trả base64 để hiển thị trong web.
    if (!strcmp(route, "image_read")) {
        char name[96] = {0};
        if (!json_get_str(b, bl, "name", name, sizeof(name)) || !images_valid_name(name)) {
            resp_ok_msg(resp, 0, "tên ảnh không hợp lệ"); return 1;
        }
        size_t n = 0;
        char *b64 = images_read_b64(name, &n);
        if (!b64) { resp_ok_msg(resp, 0, "không đọc được ảnh"); return 1; }
        size_t bodylen = n + strlen(name) + 64;
        char *body = malloc(bodylen);
        if (!body) { free(b64); resp_json(resp, 500, NULL); return 1; }
        size_t o = (size_t)snprintf(body, bodylen, "{\"ok\":true,\"name\":\"%s\",\"data\":\"", name);
        memcpy(body + o, b64, n); o += n;
        body[o++] = '"'; body[o++] = '}'; body[o] = '\0';
        free(b64);
        resp_json(resp, 200, body);
        return 1;
    }

    // POST image_delete {name} — xoá 1 ảnh.
    if (!strcmp(route, "image_delete")) {
        char name[96] = {0};
        if (!json_get_str(b, bl, "name", name, sizeof(name)) || !images_valid_name(name)) {
            resp_ok_msg(resp, 0, "tên ảnh không hợp lệ"); return 1;
        }
        int rc = images_delete(name);
        resp_ok_msg(resp, rc == 0, rc == 0 ? "đã xoá ảnh" : "xoá ảnh lỗi");
        return 1;
    }

    // POST device {name} — đổi tên thiết bị hiển thị (rỗng = về mặc định hostname, đã bỏ .local).
    if (!strcmp(route, "device")) {
        char name[128] = {0};
        json_get_str(b, bl, "name", name, sizeof(name));
        int rc = appctl_set_device_name(name);
        resp_ok_msg(resp, rc == 0, rc == 0 ? "đã đổi tên thiết bị" : "đổi tên lỗi");
        return 1;
    }

    return 0;   // route không khớp
}
