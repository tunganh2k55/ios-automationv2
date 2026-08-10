#include "httpd.h"
#include "video.h"
#include "license.h"
#include "log.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <sys/time.h>       // struct timeval cho SO_RCVTIMEO
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#define REQ_MAX (6 * 1024 * 1024)   // đủ cho POST /api/script và /api/image_save (ảnh cắt base64)

static char g_web_dir[512];

static const char *mime_for(const char *path) {
    const char *dot = strrchr(path, '.');
    if (!dot) return "application/octet-stream";
    if (!strcmp(dot, ".html")) return "text/html; charset=utf-8";
    if (!strcmp(dot, ".js"))   return "application/javascript; charset=utf-8";
    if (!strcmp(dot, ".css"))  return "text/css; charset=utf-8";
    if (!strcmp(dot, ".json")) return "application/json";
    if (!strcmp(dot, ".png"))  return "image/png";
    if (!strcmp(dot, ".ico"))  return "image/x-icon";
    if (!strcmp(dot, ".svg"))  return "image/svg+xml";
    if (!strcmp(dot, ".woff")) return "font/woff";
    if (!strcmp(dot, ".ttf"))  return "font/ttf";
    if (!strcmp(dot, ".mp3"))  return "audio/mpeg";
    if (!strcmp(dot, ".oga"))  return "audio/ogg";
    return "application/octet-stream";
}

static void send_all(int fd, const char *buf, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, buf + off, len - off);
        if (n <= 0) { if (errno == EINTR) continue; break; }
        off += (size_t)n;
    }
}

static void send_headers(int fd, int status, const char *ctype, size_t clen) {
    const char *txt = status == 200 ? "OK" : status == 404 ? "Not Found"
                    : status == 400 ? "Bad Request" : "Error";
    char h[512];
    int n = snprintf(h, sizeof(h),
        "HTTP/1.1 %d %s\r\n"
        "Content-Type: %s\r\n"
        "Content-Length: %zu\r\n"
        "Cache-Control: no-cache, no-store, must-revalidate\r\n"
        "Pragma: no-cache\r\n"
        "Expires: 0\r\n"
        "Access-Control-Allow-Origin: *\r\n"
        "Access-Control-Allow-Headers: Content-Type\r\n"
        "Connection: close\r\n\r\n",
        status, txt, ctype, clen);
    send_all(fd, h, (size_t)n);
}

static void reply(int fd, int status, const char *ctype, const char *body, size_t len) {
    send_headers(fd, status, ctype, len);
    if (len) send_all(fd, body, len);
}

// Chống path traversal: không cho ".." trong path.
static void serve_static(int fd, const char *path) {
    if (!g_web_dir[0]) { reply(fd, 404, "text/plain", "no web dir", 10); return; }
    const char *rel = (!strcmp(path, "/") ) ? "index.html" : path + 1;
    if (strstr(rel, "..")) { reply(fd, 400, "text/plain", "bad path", 8); return; }

    char full[1024];
    snprintf(full, sizeof(full), "%s/%s", g_web_dir, rel);
    FILE *f = fopen(full, "rb");
    if (!f) { reply(fd, 404, "text/plain", "not found", 9); return; }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz < 0) sz = 0;
    char *buf = malloc((size_t)sz);
    size_t rd = buf ? fread(buf, 1, (size_t)sz, f) : 0;
    fclose(f);
    if (!buf) { reply(fd, 500, "text/plain", "oom", 3); return; }
    reply(fd, 200, mime_for(full), buf, rd);
    free(buf);
}

static void handle_conn(int fd) {
    // Timeout đọc: client gửi header dở dang rồi treo (slowloris) sẽ chiếm 1 thread + 6MB mãi mãi
    // → dồn thread/RAM → jetsam kill daemon. 15s không có byte nào → bỏ kết nối.
    struct timeval rcv_to = { 15, 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &rcv_to, sizeof(rcv_to));

    char *req = malloc(REQ_MAX);
    if (!req) { close(fd); return; }

    size_t total = 0;
    size_t header_end = 0;     // vị trí ngay sau "\r\n\r\n"
    size_t content_len = 0;
    int have_headers = 0;

    // Đọc tới khi đủ header + body (theo Content-Length).
    for (;;) {
        if (total >= REQ_MAX - 1) break;
        ssize_t n = read(fd, req + total, REQ_MAX - 1 - total);
        if (n <= 0) { if (n < 0 && errno == EINTR) continue; break; }
        total += (size_t)n;
        req[total] = '\0';

        if (!have_headers) {
            char *e = strstr(req, "\r\n\r\n");
            if (e) {
                have_headers = 1;
                header_end = (size_t)(e - req) + 4;
                char *cl = strcasestr(req, "Content-Length:");
                if (cl) content_len = (size_t)strtoul(cl + 15, NULL, 10);
            }
        }
        // header_end + content_len có thể TRÀN nếu content_len ~ SIZE_MAX (client xấu) → so sánh an
        // toàn: chỉ dừng khi đã nhận đủ body thực (không để phép cộng wrap khiến dừng sớm).
        if (have_headers && content_len <= total - header_end) break;
    }

    if (!have_headers) { free(req); close(fd); return; }

    // CHỐT: body_len KHÔNG được vượt số byte THỰC nhận được. Content-Length do client khai (có thể
    // gian/lớn hơn thực) — nếu tin nguyên si thì api.c memmem/json_get_str duyệt len=content_len sẽ
    // đọc VĂNG khỏi buffer 6MB → SIGSEGV (crash từ xa chỉ với 1 dòng POST). Kẹp về đúng phần đã nhận.
    size_t avail = (total > header_end) ? total - header_end : 0;
    if (content_len > avail) content_len = avail;

    http_req r;
    memset(&r, 0, sizeof(r));
    sscanf(req, "%7s %511s", r.method, r.path);

    // Bỏ query string.
    char *q = strchr(r.path, '?');
    if (q) *q = '\0';

    r.body = req + header_end;
    r.body_len = content_len;

    // Preflight CORS.
    if (!strcmp(r.method, "OPTIONS")) {
        reply(fd, 200, "text/plain", "", 0);
        free(req); close(fd); return;
    }

    // ===== CỔNG LICENSE PHÂN TẦNG (Nhóm 1) =====
    // Mỗi route cần một BẬC tối thiểu; tier hiện tại < bậc cần → chặn 403.
    //   always : file tĩnh + /api/status + /api/license* → luôn cho (hiện overlay & kích hoạt).
    //   VIEW   : route "xem" (log/apps/device/screenshot/dump/run log/scripts/images…) + dừng task.
    //   FULL   : tạo task mới (script/run) + điều khiển (tap/swipe/launch/…) + stream/ws.
    // Task ĐANG chạy tiếp tục ở thread Lua riêng (không qua HTTP) nên bậc CONTINUE vẫn "tiếp tục
    // task đã bắt đầu", chỉ chặn TẠO MỚI.
    {
        int tier = license_tier();
        int always = 0, need = LIC_FULL;
        if (!strncmp(r.path, "/api/", 5)) {
            const char *rt = r.path + 5;
            if (!strcmp(rt, "status") || !strncmp(rt, "license", 7)) always = 1;
            else if (!strcmp(rt, "log") || !strcmp(rt, "apps") || !strcmp(rt, "apps_all")
                  || !strcmp(rt, "device")
                  || !strcmp(rt, "screenshot") || !strcmp(rt, "dump")
                  || !strcmp(rt, "run") || !strcmp(rt, "run/log") || !strcmp(rt, "run/stop")
                  || !strcmp(rt, "scripts") || !strcmp(rt, "script_read")
                  || !strcmp(rt, "images") || !strcmp(rt, "image_read")
                  || !strncmp(rt, "profile", 7))   // profile/list|apply|clear: gán device profile cho app
                need = LIC_VIEW;   // xem trạng thái/log + theo dõi/dừng task đang chạy + gán profile
            else
                need = LIC_FULL;   // /api/script (tạo task) + tap/swipe/launch/type/ocr/… = điều khiển
        } else if (!strncmp(r.path, "/ws/", 4)) {
            need = LIC_FULL;       // websocket video/điều khiển
        } else {
            always = 1;            // file tĩnh
        }
        if (!always && tier < need) {
            const char *nl = (tier <= LIC_LOCKED)
                ? "{\"ok\":false,\"need_license\":true,\"msg\":\"Thiết bị chưa kích hoạt bản quyền\"}"
                : "{\"ok\":false,\"need_license\":true,\"degraded\":true,\"msg\":\"Mất kết nối máy chủ bản quyền — tính năng tạm hạn chế cho tới khi kết nối lại\"}";
            reply(fd, 403, "application/json", nl, strlen(nl));
            free(req); close(fd); return;
        }
    }

    // WebSocket video: nâng cấp + phục vụ 1 client (chiếm riêng kết nối tới khi rớt).
    if (video_is_ws_path(r.path)) {
        video_handle_ws(fd, req);
        free(req); close(fd); return;
    }
    // WebSocket điều khiển realtime.
    if (video_is_control_path(r.path)) {
        control_handle_ws(fd, req);
        free(req); close(fd); return;
    }

    // Stream MJPEG: chiếm riêng kết nối, ghi khung liên tục tới khi client rớt.
    if (!strcmp(r.path, "/api/stream")) {
        api_stream_mjpeg(fd);
        free(req); close(fd); return;
    }

    if (!strncmp(r.path, "/api/", 5)) {
        http_resp resp;
        memset(&resp, 0, sizeof(resp));
        resp.status = 404;
        resp.content_type = "application/json";
        if (api_handle(&r, &resp) && resp.body) {
            reply(fd, resp.status, resp.content_type, resp.body, resp.body_len);
            if (resp.body_owned) free(resp.body);
        } else {
            const char *nf = "{\"ok\":false,\"msg\":\"route không tồn tại\"}";
            reply(fd, 404, "application/json", nf, strlen(nf));
        }
    } else {
        serve_static(fd, r.path);
    }

    free(req);
    close(fd);
}

static void *conn_thread(void *arg) {
    int fd = (int)(long)arg;
    handle_conn(fd);
    return NULL;
}

// Tạo 1 socket nghe TCP. host_be = địa chỉ bind (network byte order):
//   htonl(INADDR_ANY)      → 0.0.0.0 (mọi interface, LAN/WiFi).
//   htonl(INADDR_LOOPBACK) → 127.0.0.1 (chỉ nội bộ máy → chỉ vào được qua usbmuxd/USB).
// Trả fd đang listen, hoặc -1 nếu lỗi.
static int make_listener(uint32_t host_be, int port) {
    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) { log_msg("socket() lỗi: %s", strerror(errno)); return -1; }
    int one = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = host_be;
    addr.sin_port = htons((unsigned short)port);

    if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        log_msg("bind(:%d) lỗi: %s", port, strerror(errno));
        close(srv); return -1;
    }
    if (listen(srv, 16) < 0) {
        log_msg("listen(:%d) lỗi: %s", port, strerror(errno));
        close(srv); return -1;
    }
    return srv;
}

// Vòng lặp accept trên 1 socket nghe: mỗi kết nối 1 thread (conn_thread). Chạy tới khi accept lỗi.
static void accept_loop(int srv) {
    for (;;) {
        int fd = accept(srv, NULL, NULL);
        if (fd < 0) { if (errno == EINTR) continue; break; }
        pthread_t th;
        if (pthread_create(&th, NULL, conn_thread, (void *)(long)fd) == 0) {
            pthread_detach(th);
        } else {
            handle_conn(fd);
        }
    }
    close(srv);
}

// Thread bọc cho listener phụ (USB/loopback).
static void *accept_loop_thread(void *arg) {
    accept_loop((int)(long)arg);
    return NULL;
}

int httpd_run(int port, int usb_port, const char *web_dir) {
    signal(SIGPIPE, SIG_IGN);   // ngừng crash khi client đóng sớm (bài học cũ)
    if (web_dir) { strncpy(g_web_dir, web_dir, sizeof(g_web_dir) - 1); }

    int srv = make_listener(htonl(INADDR_ANY), port);
    if (srv < 0) return 1;
    log_msg("HTTP server (LAN/WiFi) lắng nghe 0.0.0.0:%d", port);

    // Listener phụ CHỈ loopback → chỉ vào được qua USB (usbmuxd/iproxy chuyển tiếp tới 127.0.0.1).
    // Không lộ ra WiFi/LAN; vẫn hoạt động khi bật chế độ máy bay (WiFi tắt).
    if (usb_port > 0 && usb_port != port) {
        int usb = make_listener(htonl(INADDR_LOOPBACK), usb_port);
        if (usb >= 0) {
            log_msg("HTTP server (USB) lắng nghe 127.0.0.1:%d", usb_port);
            pthread_t th;
            if (pthread_create(&th, NULL, accept_loop_thread, (void *)(long)usb) == 0) pthread_detach(th);
            else { log_msg("không tạo được thread USB listener"); close(usb); }
        }
    }

    accept_loop(srv);   // vòng lặp chính (LAN) — blocking, chạy mãi
    return 0;
}
