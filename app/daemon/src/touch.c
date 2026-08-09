#include "touch.h"
#include "fbcap.h"
#include "log.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <sys/select.h>
#include <sys/time.h>
#include <sys/sysctl.h>

// IPC daemon <-> tweak (UIKit user-mode). Daemon = SERVER, giữ NHIỀU client
// (mỗi app foreground inject tweak là 1 client + SpringBoard). Khi TAP: ưu tiên
// app foreground (non-SpringBoard, mới nhất) hơn SpringBoard. Có timeout.
//
// Kênh dùng TCP LOOPBACK 127.0.0.1 (KHÔNG Unix socket) — sandbox App Store/Telegram
// chặn Unix socket `/var/jb/...` nhưng cho phép kết nối localhost.
#define TOUCH_PORT 8399
#define MAX_CLIENTS 8
#define REPLY_TIMEOUT_MS 900

static int g_clients[MAX_CLIENTS];
static char g_bundle[MAX_CLIENTS][128];
static int g_nclients = 0;
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;

static int g_screen_w = 0, g_screen_h = 0;   // set từ device model fallback hoặc handshake INFO

// Fallback screen size dựa trên device model (hw.machine) khi tweak chưa kết nối.
// Point size (không phải pixel): iOS dùng point cho tọa độ UI.
static struct { const char *model; int w; int h; } g_model_screen[] = {
    // iPhone 6/6s/7/8/SE2/SE3 (4.7")
    {"iPhone7,2",  375, 667},   // iPhone 6
    {"iPhone8,1",  375, 667},   // iPhone 6s
    {"iPhone9,1",  375, 667},   // iPhone 7 (CDMA)
    {"iPhone9,3",  375, 667},   // iPhone 7 (GSM)
    {"iPhone10,1", 375, 667},   // iPhone 8 (CDMA)
    {"iPhone10,4", 375, 667},   // iPhone 8 (GSM)
    {"iPhone12,8", 375, 667},   // iPhone SE 2nd
    {"iPhone14,6", 375, 667},   // iPhone SE 3rd
    // iPhone 6+/6s+/7+/8+ (5.5")
    {"iPhone7,1",  414, 736},   // iPhone 6 Plus
    {"iPhone8,2",  414, 736},   // iPhone 6s Plus
    {"iPhone9,2",  414, 736},   // iPhone 7 Plus (CDMA)
    {"iPhone9,4",  414, 736},   // iPhone 7 Plus (GSM)
    {"iPhone10,2", 414, 736},   // iPhone 8 Plus (CDMA)
    {"iPhone10,5", 414, 736},   // iPhone 8 Plus (GSM)
    // iPhone X/Xs/11 Pro (5.8")
    {"iPhone10,3", 375, 812},   // iPhone X (CDMA)
    {"iPhone10,6", 375, 812},   // iPhone X (GSM)
    {"iPhone11,2", 375, 812},   // iPhone Xs
    {"iPhone12,3", 375, 812},   // iPhone 11 Pro
    // iPhone Xr/11 (6.1" LCD)
    {"iPhone11,8", 414, 896},   // iPhone Xr
    {"iPhone12,1", 414, 896},   // iPhone 11
    // iPhone Xs Max/11 Pro Max (6.5")
    {"iPhone11,4", 414, 896},   // iPhone Xs Max (China)
    {"iPhone11,6", 414, 896},   // iPhone Xs Max (Global)
    {"iPhone12,5", 414, 896},   // iPhone 11 Pro Max
    // iPhone 12 mini/13 mini (5.4")
    {"iPhone13,1", 375, 812},   // iPhone 12 mini
    {"iPhone14,4", 375, 812},   // iPhone 13 mini
    // iPhone 12/12 Pro/13/13 Pro/14 (6.1" OLED)
    {"iPhone13,2", 390, 844},   // iPhone 12
    {"iPhone13,3", 390, 844},   // iPhone 12 Pro
    {"iPhone14,5", 390, 844},   // iPhone 13
    {"iPhone14,2", 390, 844},   // iPhone 13 Pro
    {"iPhone14,7", 390, 844},   // iPhone 14
    // iPhone 12 Pro Max/13 Pro Max/14 Plus (6.7")
    {"iPhone13,4", 428, 926},   // iPhone 12 Pro Max
    {"iPhone14,3", 428, 926},   // iPhone 13 Pro Max
    {"iPhone14,8", 428, 926},   // iPhone 14 Plus
    // iPhone 14 Pro/15/15 Pro (6.1" Dynamic Island)
    {"iPhone15,2", 393, 852},   // iPhone 14 Pro
    {"iPhone15,4", 393, 852},   // iPhone 15
    {"iPhone16,1", 393, 852},   // iPhone 15 Pro
    // iPhone 14 Pro Max/15 Plus/15 Pro Max (6.7" Dynamic Island)
    {"iPhone15,3", 430, 932},   // iPhone 14 Pro Max
    {"iPhone15,5", 430, 932},   // iPhone 15 Plus
    {"iPhone16,2", 430, 932},   // iPhone 15 Pro Max
    // iPhone 16
    {"iPhone17,3", 393, 852},   // iPhone 16
    {"iPhone17,4", 393, 852},   // iPhone 16 Pro
    {"iPhone17,1", 430, 932},   // iPhone 16 Plus
    {"iPhone17,2", 430, 932},   // iPhone 16 Pro Max
    {NULL, 0, 0}
};

static void init_screen_from_model(void) {
    char machine[64] = {0};
    size_t sz = sizeof(machine);
    if (sysctlbyname("hw.machine", machine, &sz, NULL, 0) != 0) {
        g_screen_w = 390; g_screen_h = 844;   // fallback mặc định
        log_msg("touch: không đọc được hw.machine, dùng default %dx%d", g_screen_w, g_screen_h);
        return;
    }
    for (int i = 0; g_model_screen[i].model; i++) {
        if (strcmp(machine, g_model_screen[i].model) == 0) {
            g_screen_w = g_model_screen[i].w;
            g_screen_h = g_model_screen[i].h;
            log_msg("touch: model %s → màn %dx%d (fallback)", machine, g_screen_w, g_screen_h);
            return;
        }
    }
    g_screen_w = 390; g_screen_h = 844;
    log_msg("touch: model %s không trong bảng, dùng default %dx%d", machine, g_screen_w, g_screen_h);
}

static void remove_client_locked(int idx) {
    close(g_clients[idx]);
    g_nclients--;
    g_clients[idx] = g_clients[g_nclients];
    memcpy(g_bundle[idx], g_bundle[g_nclients], sizeof(g_bundle[0]));
}

// Đọc 1 dòng trả lời từ fd (timeout ms). >0 số byte, <=0 lỗi/đóng.
static int read_line_to(int fd, char *buf, size_t cap, int timeout_ms) {
    // fd_set là bitmap CỐ ĐỊNH FD_SETSIZE (1024) bit trên stack. FD_SET với fd>=1024 GHI VĂNG khỏi
    // bitmap → hỏng stack → crash. Daemon sống lâu + nhiều kết nối (HTTP keep-alive, stream MJPEG/WS,
    // tối đa 8 client tweak) có thể đẩy 1 fd lên >=1024. Chặn trước, coi như đọc lỗi.
    if (fd < 0 || fd >= FD_SETSIZE) return -1;
    fd_set rf; FD_ZERO(&rf); FD_SET(fd, &rf);
    struct timeval tv = { timeout_ms / 1000, (timeout_ms % 1000) * 1000 };
    if (select(fd + 1, &rf, NULL, NULL, &tv) <= 0) return 0;
    ssize_t n = read(fd, buf, cap - 1);
    if (n <= 0) return -1;
    buf[n] = '\0';
    char *nl = strchr(buf, '\n'); if (nl) *nl = '\0';
    return (int)n;
}
static int read_line(int fd, char *buf, size_t cap) {
    return read_line_to(fd, buf, cap, REPLY_TIMEOUT_MS);
}

// Handshake: hỏi client là app nào + kích thước màn.
// RETRY: nếu client trả 0x0 (cache chưa sẵn sàng trên iOS 15.x), thử lại vài lần.
static void query_info(int fd, char *bundle_out, size_t bundle_len) {
    bundle_out[0] = '\0';
    char drain[256];
    while (recv(fd, drain, sizeof(drain), MSG_DONTWAIT) > 0) { /* xả reply cũ */ }

    // Thử tối đa 3 lần, mỗi lần cách 300ms (cho main thread kịp điền cache screen size).
    for (int attempt = 0; attempt < 3; attempt++) {
        if (attempt > 0) usleep(300 * 1000);   // đợi 300ms trước khi thử lại
        if (write(fd, "INFO\n", 5) <= 0) return;
        char buf[256];
        // Timeout DÀI (2.5s): lúc SpringBoard boot nó bận nên INFO về chậm; nếu timeout ngắn →
        // bundle "?" → prefer_sb không nhận ra SpringBoard.
        if (read_line_to(fd, buf, sizeof(buf), 2500) <= 0) return;
        // "OK <bundle> <w> <h>"
        char bid[128]; int w = 0, h = 0;
        if (sscanf(buf, "OK %127s %d %d", bid, &w, &h) >= 1) {
            snprintf(bundle_out, bundle_len, "%s", bid);
            if (w > 0 && h > 0) {
                g_screen_w = w; g_screen_h = h;
                return;   // thành công, có screen size
            }
            // w=0 hoặc h=0: client chưa sẵn sàng, thử lại
            if (attempt < 2) {
                log_msg("touch: INFO từ %s trả 0x0, thử lại (%d/3)", bid, attempt + 2);
            }
        }
    }
}

static void *accept_loop(void *arg) {
    (void)arg;
    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) { log_msg("touch: socket() lỗi %s", strerror(errno)); return NULL; }
    int one = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);   // chỉ 127.0.0.1
    a.sin_port = htons(TOUCH_PORT);

    if (bind(srv, (struct sockaddr *)&a, sizeof(a)) < 0) {
        log_msg("touch: bind(127.0.0.1:%d) lỗi %s", TOUCH_PORT, strerror(errno));
        close(srv); return NULL;
    }
    if (listen(srv, 8) < 0) {
        log_msg("touch: listen lỗi %s", strerror(errno));
        close(srv); return NULL;
    }
    log_msg("touch: TCP relay sẵn sàng (127.0.0.1:%d)", TOUCH_PORT);

    for (;;) {
        int fd = accept(srv, NULL, NULL);
        if (fd < 0) { if (errno == EINTR) continue; break; }

        char bundle[128] = {0};
        query_info(fd, bundle, sizeof(bundle));   // hỏi ngoài lock (blocking ngắn)

        // Bật chấm đỏ/mũi tên (FX) cho MỌI client khi kết nối — kể cả app đang chạy tweak CŨ
        // (gFxEnabled=NO mặc định) → tap/tapText luôn hiện chấm đỏ, không cần relaunch app.
        if (write(fd, "FX 1\n", 5) > 0) { char tmp[128]; read_line_to(fd, tmp, sizeof(tmp), 600); }

        pthread_mutex_lock(&g_mu);
        if (g_nclients >= MAX_CLIENTS) remove_client_locked(0);
        g_clients[g_nclients] = fd;
        snprintf(g_bundle[g_nclients], sizeof(g_bundle[0]), "%s", bundle);
        g_nclients++;
        int n = g_nclients;
        pthread_mutex_unlock(&g_mu);
        log_msg("touch: client kết nối (fd=%d, %s, tổng=%d, màn %dx%d)",
                fd, bundle[0] ? bundle : "?", n, g_screen_w, g_screen_h);
    }
    close(srv);
    return NULL;
}

void touch_init(void) {
    init_screen_from_model();   // fallback screen size từ device model trước khi tweak kết nối
    pthread_t th;
    if (pthread_create(&th, NULL, accept_loop, NULL) == 0)
        pthread_detach(th);
    else
        log_msg("touch: không tạo được accept thread");
}

void touch_screen_size(int *w, int *h) {
    if (w) *w = g_screen_w;
    if (h) *h = g_screen_h;
}

static int is_springboard(const char *b) {
    return b && strcmp(b, "com.apple.springboard") == 0;
}

// Gửi verb tới 1 client (theo index), đọc trả lời (timeout ms). 1=OK, 0=reply khác, -1=chết.
static int query_at_to(int idx, const char *verb, char *reply, size_t rlen, int timeout_ms) {
    int fd = g_clients[idx];
    // DRAIN dữ liệu tồn (reply của lệnh trước đến MUỘN sau khi đã timeout) → tránh lệnh này
    // đọc nhầm reply cũ (desync: OCR nhận "OK shot", INFO nhận "OK wake"…). Request-reply 1-1
    // nên trước khi gửi, xả sạch buffer là an toàn.
    char drain[512];
    while (recv(fd, drain, sizeof(drain), MSG_DONTWAIT) > 0) { /* bỏ reply cũ */ }
    // Ghi ĐẦY ĐỦ verb (OCRIMG mang ảnh base64 ~40KB — 1 write có thể ghi thiếu).
    size_t vl = strlen(verb), voff = 0;
    while (voff < vl) {
        ssize_t wn = write(fd, verb + voff, vl - voff);
        if (wn <= 0) return -1;
        voff += (size_t)wn;
    }
    int r = read_line_to(fd, reply, rlen, timeout_ms);
    if (r < 0) return -1;
    if (r == 0) { snprintf(reply, rlen, "timeout"); return 0; }
    return (strncmp(reply, "OK", 2) == 0) ? 1 : 0;
}
static int query_at(int idx, const char *verb, char *reply, size_t rlen) {
    return query_at_to(idx, verb, reply, rlen, REPLY_TIMEOUT_MS);
}

// Dọn client đã chết (peer đóng socket) — MSG_PEEK non-blocking: recv==0 => EOF.
static void reap_dead_locked(void) {
    for (int i = g_nclients - 1; i >= 0; i--) {
        char b;
        ssize_t r = recv(g_clients[i], &b, 1, MSG_PEEK | MSG_DONTWAIT);
        if (r == 0) { log_msg("touch: dọn client chết (%s)", g_bundle[i][0] ? g_bundle[i] : "?"); remove_client_locked(i); }
    }
}

// Lõi gửi verb. do_log=0 để vòng lặp stream không spam log.
// prefer_sb=1: ưu tiên SpringBoard (SHOT — CARenderServer từ SpringBoard chụp cả màn,
//              kể cả app foreground). prefer_sb=0: ưu tiên app foreground (TAP/SWIPE/TYPE).
// Trả 0=OK, 1=reply khác/không nhận, 2=không có client.
// Client có bundle "?" (handshake INFO lúc trước bị timeout) → hỏi lại INFO để nhận diện,
// nếu không prefer_sb sẽ không thấy SpringBoard. Gọi trong lock.
static void refresh_unknown_locked(void) {
    for (int i = 0; i < g_nclients; i++) {
        if (g_bundle[i][0] && g_bundle[i][0] != '?') continue;
        char b[128] = {0};
        query_info(g_clients[i], b, sizeof(b));
        if (b[0]) snprintf(g_bundle[i], sizeof(g_bundle[0]), "%s", b);
    }
}

static int send_verb_core_to(const char *verb, char *err, size_t err_len, int do_log, int prefer_sb, int timeout_ms) {
    pthread_mutex_lock(&g_mu);
    reap_dead_locked();
    if (prefer_sb) refresh_unknown_locked();   // đảm bảo nhận diện được SpringBoard trước khi route
    if (g_nclients == 0) {
        pthread_mutex_unlock(&g_mu);
        snprintf(err, err_len, "chưa có app foreground kết nối (mở khoá + mở 1 app)");
        return 2;
    }

    char reply[1024], last[1024] = "no-reply";
    int ok = 0;

    // Vòng 0 = nhóm ưu tiên, vòng 1 = nhóm còn lại; trong mỗi nhóm lấy client mới nhất trước.
    for (int pass = 0; pass < 2 && !ok; pass++) {
        int want_sb = (pass == 0) ? prefer_sb : !prefer_sb;
        for (int i = g_nclients - 1; i >= 0; i--) {
            if (is_springboard(g_bundle[i]) != want_sb) continue;
            int rc = query_at_to(i, verb, reply, sizeof(reply), timeout_ms);
            if (do_log) log_msg("  thử %s → rc=%d reply=%.70s", g_bundle[i][0] ? g_bundle[i] : "?", rc, rc < 0 ? "(chết)" : reply);
            if (rc < 0) { remove_client_locked(i); continue; }
            // "SKIP …" = client TỪ CHỐI xử lý (app nền, hoặc SpringBoard không có WKWebView cho web
            // verb) → KHÔNG ghi đè `last` để giữ câu trả lời THẬT của client đã xử lý (vd Safari trả
            // "ERR webclick: không thấy element" — đừng để SpringBoard che bằng "cần app foreground").
            if (strncmp(reply, "SKIP", 4) == 0) continue;
            snprintf(last, sizeof(last), "%s", reply);
            if (rc == 1) { ok = 1; break; }
        }
    }
    int n = g_nclients;
    pthread_mutex_unlock(&g_mu);

    if (do_log) log_msg("touch reply: %s (clients=%d)", last, n);
    snprintf(err, err_len, "%s", last);
    return ok ? 0 : 1;
}

static int send_verb_core(const char *verb, char *err, size_t err_len, int do_log, int prefer_sb) {
    return send_verb_core_to(verb, err, err_len, do_log, prefer_sb, REPLY_TIMEOUT_MS);
}

static int send_verb(const char *verb, char *err, size_t err_len) {
    return send_verb_core(verb, err, err_len, 1, 0);   // tap/swipe: ưu tiên app foreground
}

// Dùng cho vòng lặp stream: gửi SHOT lấy đường dẫn ảnh, KHÔNG ghi log, ưu tiên SpringBoard.
int touch_shot(char *reply, size_t rlen) {
    return send_verb_core("SHOT\n", reply, rlen, 0, 1);
}

int touch_tap(int x, int y, char *err, size_t err_len) {
    char verb[64];
    snprintf(verb, sizeof(verb), "TAP %d %d\n", x, y);
    log_msg("tap (%d, %d) → tweak", x, y);
    return send_verb(verb, err, err_len);
}

int touch_swipe(int x1, int y1, int x2, int y2, double duration, char *err, size_t err_len) {
    char verb[96];
    snprintf(verb, sizeof(verb), "SWIPE %d %d %d %d %.3f\n", x1, y1, x2, y2, duration);
    log_msg("swipe (%d,%d → %d,%d) → tweak", x1, y1, x2, y2);
    return send_verb(verb, err, err_len);
}

// Điều khiển realtime — gửi PTR (không log: moves ~60/s). Prefer app foreground.
int touch_pointer(char phase, int x, int y, char *err, size_t err_len) {
    char verb[48];
    snprintf(verb, sizeof(verb), "PTR %c %d %d\n", phase, x, y);
    return send_verb_core(verb, err, err_len, 0, 0);
}

int touch_appearance(int mode, char *err, size_t err_len) {
    if (mode < 0 || mode > 2) mode = 0;
    char verb[32];
    snprintf(verb, sizeof(verb), "APPEAR %d\n", mode);
    log_msg("appearance mode=%d → tweak (ưu tiên SpringBoard)", mode);
    return send_verb_core(verb, err, err_len, 1, 1);   // prefer_sb=1: chỉ SpringBoard đổi được cả máy
}

int touch_raw(const char *line, char *err, size_t err_len) {
    char verb[256];
    snprintf(verb, sizeof(verb), "%s\n", line ? line : "");
    log_msg("raw → tweak: %s", line ? line : "");
    return send_verb(verb, err, err_len);
}

// App Switcher → SpringBoard (prefer_sb=1: chỉ SpringBoard mở được switcher).
int touch_switcher(char *err, size_t err_len) {
    log_msg("switcher → SpringBoard");
    return send_verb_core("SWITCHER\n", err, err_len, 1, 1);
}

// WAKE → SpringBoard (prefer_sb=1): unblank + mở khoá (unlock chỉ chạy trong SpringBoard).
// Ưu tiên SpringBoard để (1) mở khoá chắc chắn, (2) trả đúng diag "OK wake+unlock" (đang khoá)
// hay "OK wake (đã mở khoá)" — web UI dựa vào đó để bấm-đúp-Home phân biệt màn tắt/bật.
int touch_wake(char *err, size_t err_len) {
    log_msg("wake → SpringBoard");
    return send_verb_core("WAKE\n", err, err_len, 1, 1);
}

// AIRPLANE on/off → SpringBoard (prefer_sb=1). Bật/tắt sóng THẬT phải chạy trong SpringBoard
// (RadiosPreferences là chủ radio ở tiến trình đó); daemon root chỉ ghi plist, KHÔNG cắt sóng.
// Trả 0 nếu tweak trả "OK …"; khác 0 (diag/lỗi vào err) nếu SpringBoard chưa inject tweak / lỗi.
int touch_airplane(int on, char *err, size_t err_len) {
    char verb[24];
    snprintf(verb, sizeof(verb), "AIRPLANE %d\n", on ? 1 : 0);
    log_msg("airplane %s → SpringBoard", on ? "ON" : "OFF");
    return send_verb_core(verb, err, err_len, 1, 1);
}

// DUMP cây UIView của app foreground → reply "OK dump <path>". Ưu tiên app foreground
// (prefer_sb=0) để lấy XML của chính app đang mở (màn chính → SpringBoard). Trả 0 nếu OK.
int touch_dump(char *reply, size_t rlen) {
    log_msg("dump → tweak (ưu tiên app foreground)");
    return send_verb_core_to("DUMP\n", reply, rlen, 1, 0, 6000);
}

// base64-encode (không xuống dòng) → chuỗi malloc NUL-terminated.
static char *b64_encode(const unsigned char *in, size_t len, size_t *out_len) {
    static const char t[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t olen = 4 * ((len + 2) / 3);
    char *out = malloc(olen + 1);
    if (!out) return NULL;
    size_t i, o = 0;
    for (i = 0; i + 3 <= len; i += 3) {
        out[o++] = t[in[i] >> 2];
        out[o++] = t[((in[i] & 3) << 4) | (in[i + 1] >> 4)];
        out[o++] = t[((in[i + 1] & 15) << 2) | (in[i + 2] >> 6)];
        out[o++] = t[in[i + 2] & 63];
    }
    if (i < len) {
        out[o++] = t[in[i] >> 2];
        if (i + 1 < len) {
            out[o++] = t[((in[i] & 3) << 4) | (in[i + 1] >> 4)];
            out[o++] = t[(in[i + 1] & 15) << 2];
        } else {
            out[o++] = t[(in[i] & 3) << 4];
            out[o++] = '=';
        }
        out[o++] = '=';
    }
    out[o] = '\0';
    if (out_len) *out_len = o;
    return out;
}

// OCR: SHOT từ SpringBoard (chụp CẢ MÀN kể cả app SwiftUI/Metal) → gửi ảnh (base64) vào APP
// foreground để Vision (ANE của app chạy được; SpringBoard thì crash). Reply "OK ocr <path>"
// với path là file JSON trong container app — daemon (root) đọc được. Trả 0 nếu OK.
// SPIKE VideoToolbox: quay H.264 trong SpringBoard (prefer_sb=1). Block ~seconds giây → timeout dài.

int touch_toast(const char *text, double duration, char *err, size_t err_len) {
    if (!text) text = "";
    if (duration <= 0) duration = 2.0;
    if (duration > 30) duration = 30.0;
    size_t b64len = 0;
    char *b64 = b64_encode((const unsigned char *)text, strlen(text), &b64len);
    if (!b64) { snprintf(err, err_len, "oom base64"); return 1; }
    size_t vlen = 16 + 32 + b64len + 2;
    char *verb = malloc(vlen);
    if (!verb) { free(b64); snprintf(err, err_len, "oom verb"); return 1; }
    snprintf(verb, vlen, "TOASTB64 %.3f %s\n", duration, b64);
    free(b64);
    log_msg("toast %.1fs: %.80s", duration, text);
    int r = send_verb_core(verb, err, err_len, 1, 0);
    free(verb);
    return r;
}

int touch_vtrec(char *reply, size_t rlen, int seconds) {
    if (seconds < 1) seconds = 1; if (seconds > 15) seconds = 15;
    char verb[32];
    snprintf(verb, sizeof(verb), "VTREC %d\n", seconds);
    log_msg("vtrec %ds → SpringBoard (spike VideoToolbox H.264)", seconds);
    return send_verb_core_to(verb, reply, rlen, 1, 1, seconds * 1000 + 8000);
}

// Bật/tắt stream video liên tục — gửi VTSTART/VTSTOP tới SpringBoard (prefer_sb=1).
int touch_video_stream(int on, char *reply, size_t rlen) {
    return send_verb_core_to(on ? "VTSTART\n" : "VTSTOP\n", reply, rlen, 1, 1, 1500);
}

// Bật/tắt stream JPEG (SHOTSTART/SHOTSTOP) tới SpringBoard (prefer_sb=1).
int touch_shot_stream(int on, char *reply, size_t rlen) {
    return send_verb_core_to(on ? "SHOTSTART\n" : "SHOTSTOP\n", reply, rlen, 1, 1, 1500);
}

// Đặt clipboard = text. Gửi "COPYB64 <base64(text)>" (base64 → chuỗi có dấu cách/xuống dòng vẫn
// nằm gọn 1 dòng verb). Ưu tiên app foreground (pasteboard chung nên app nào ghi cũng như nhau).
int touch_copy(const char *text, char *err, size_t err_len) {
    if (!text) text = "";
    size_t b64len = 0;
    char *b64 = b64_encode((const unsigned char *)text, strlen(text), &b64len);
    if (!b64) { snprintf(err, err_len, "oom base64"); return 1; }
    size_t vlen = 8 + b64len + 2;                     // "COPYB64 " + b64 + "\n"
    char *verb = malloc(vlen);
    if (!verb) { free(b64); snprintf(err, err_len, "oom verb"); return 1; }
    snprintf(verb, vlen, "COPYB64 %s\n", b64);
    free(b64);
    log_msg("copy: %zu byte → clipboard (COPYB64)", strlen(text));
    int r = send_verb_core(verb, err, err_len, 1, 0);
    free(verb);
    return r;
}

// Lấy clipboard → reply "OK clip <path>" (file text). Ưu tiên app foreground; timeout 3s.
int touch_clip(char *reply, size_t rlen) {
    log_msg("clip → tweak (đọc clipboard)");
    return send_verb_core_to("CLIP\n", reply, rlen, 1, 0, 3000);
}

// safari.fill (ẨN): "WEBFILL <b64field> <b64value>" — cả 2 base64 (mang được tiếng Nhật/ký tự đặc
// biệt gọn 1 dòng). Ưu tiên app foreground (webview nằm trong app đang mở); timeout 4.5s (chờ
// evaluateJavaScript của WebKit xong). reply nhận diag từ tweak.
int touch_safari_fill(const char *field, const char *value, char *reply, size_t rlen) {
    if (!field) field = "";
    if (!value) value = "";
    size_t fl = 0, vl = 0;
    char *bf = b64_encode((const unsigned char *)field, strlen(field), &fl);
    char *bv = b64_encode((const unsigned char *)value, strlen(value), &vl);
    if (!bf || !bv) { free(bf); free(bv); snprintf(reply, rlen, "oom base64"); return 1; }
    size_t vlen = 10 + fl + 1 + vl + 2;               // "WEBFILL " + bf + ' ' + bv + "\n"
    char *verb = malloc(vlen);
    if (!verb) { free(bf); free(bv); snprintf(reply, rlen, "oom verb"); return 1; }
    snprintf(verb, vlen, "WEBFILL %s %s\n", bf, bv);
    free(bf); free(bv);
    log_msg("safari.fill: field=%.40s (%zu byte value) → app foreground", field, strlen(value));
    int r = send_verb_core_to(verb, reply, rlen, 1, 0, 4500);
    free(verb);
    return r;
}

// safari.type (ẨN): "WEBTYPE <b64field> <b64value>" — GÕ từng ký tự (mô phỏng người) vào ô web khớp
// field. Giống cấu trúc safari.fill (field/value base64), chỉ khác verb WEBTYPE → tweak bắn đủ chuỗi
// phím cho mỗi ký tự VÀ ngủ ngẫu nhiên giữa các phím (mô phỏng người). Timeout 25s (chuỗi dài + nhịp
// gõ thật mất vài giây; tweak chặn trần 120 ký tự). App foreground.
int touch_safari_type(const char *field, const char *value, char *reply, size_t rlen) {
    if (!field) field = "";
    if (!value) value = "";
    size_t fl = 0, vl = 0;
    char *bf = b64_encode((const unsigned char *)field, strlen(field), &fl);
    char *bv = b64_encode((const unsigned char *)value, strlen(value), &vl);
    if (!bf || !bv) { free(bf); free(bv); snprintf(reply, rlen, "oom base64"); return 1; }
    size_t vlen = 10 + fl + 1 + vl + 2;               // "WEBTYPE " + bf + ' ' + bv + "\n"
    char *verb = malloc(vlen);
    if (!verb) { free(bf); free(bv); snprintf(reply, rlen, "oom verb"); return 1; }
    snprintf(verb, vlen, "WEBTYPE %s %s\n", bf, bv);
    free(bf); free(bv);
    log_msg("safari.type: field=%.40s (%zu byte value) → app foreground", field, strlen(value));
    // Timeout LỚN (25s): tweak gõ TỪNG ký tự có ngủ ngẫu nhiên giữa các phím (mô phỏng người, chống
    // anti-bot) → chuỗi dài mất vài giây; 8s cũ sẽ hết giờ trước khi tweak trả lời. Trần 120 ký tự
    // phía tweak giữ tổng thời gian (~165ms/phím) < 25s ngay cả trường hợp xấu nhất.
    int r = send_verb_core_to(verb, reply, rlen, 1, 0, 25000);
    free(verb);
    return r;
}

// safari.swipe (ẨN): "WEBSWIPE <b64field>" — cuộn tới element web khớp field (scrollIntoView).
// field base64 (mang được tiếng Nhật/ký tự đặc biệt gọn 1 dòng). App foreground; timeout 4.5s.
int touch_safari_swipe(const char *field, char *reply, size_t rlen) {
    if (!field) field = "";
    size_t fl = 0;
    char *bf = b64_encode((const unsigned char *)field, strlen(field), &fl);
    if (!bf) { snprintf(reply, rlen, "oom base64"); return 1; }
    size_t vlen = 9 + fl + 2;                          // "WEBSWIPE " + bf + "\n"
    char *verb = malloc(vlen);
    if (!verb) { free(bf); snprintf(reply, rlen, "oom verb"); return 1; }
    snprintf(verb, vlen, "WEBSWIPE %s\n", bf);
    free(bf);
    log_msg("safari.swipe: field=%.40s → app foreground", field);
    int r = send_verb_core_to(verb, reply, rlen, 1, 0, 4500);
    free(verb);
    return r;
}

// safari.click (ẨN): "WEBCLICK <b64field>" — bấm element web khớp field (cuộn tới + pointer/mouse +
// el.click()). field base64. App foreground; timeout 4.5s.
int touch_safari_click(const char *field, char *reply, size_t rlen) {
    if (!field) field = "";
    size_t fl = 0;
    char *bf = b64_encode((const unsigned char *)field, strlen(field), &fl);
    if (!bf) { snprintf(reply, rlen, "oom base64"); return 1; }
    size_t vlen = 9 + fl + 2;                          // "WEBCLICK " + bf + "\n"
    char *verb = malloc(vlen);
    if (!verb) { free(bf); snprintf(reply, rlen, "oom verb"); return 1; }
    snprintf(verb, vlen, "WEBCLICK %s\n", bf);
    free(bf);
    log_msg("safari.click: field=%.40s → app foreground", field);
    int r = send_verb_core_to(verb, reply, rlen, 1, 0, 4500);
    free(verb);
    return r;
}

// safari.load (ẨN): chờ trang web app foreground load XONG (document.readyState == 'complete').
// LẶP gọi verb "WEBSTATE" (mỗi lần nhanh) — nghỉ 350ms giữa các lần — tới khi 'complete' hoặc hết
// `timeout_sec` giây (mặc định 60, trần 600). Không giữ 1 socket mở suốt 60s (tránh chẹn IPC/watchdog).
// Trả 0 = đã load xong; khác 0 = timeout / không phải trang web foreground / lỗi mạng.
int touch_safari_load(int timeout_sec, char *reply, size_t rlen) {
    if (timeout_sec <= 0) timeout_sec = 60;
    if (timeout_sec > 600) timeout_sec = 600;                    // trần an toàn
    struct timeval tv; gettimeofday(&tv, NULL);
    long deadline_ms = (long)tv.tv_sec * 1000 + tv.tv_usec / 1000 + (long)timeout_sec * 1000;
    log_msg("safari.load: chờ trang load xong, tối đa %ds", timeout_sec);
    char last[600] = {0};
    int polls = 0, noweb = 0;
    for (;;) {
        char r[600] = {0};
        int rc = send_verb_core_to("WEBSTATE\n", r, sizeof(r), 0, 0, 4500);   // do_log=0: tránh spam ~170 dòng
        polls++;
        if (rc == 0 && r[0]) snprintf(last, sizeof(last), "%s", r);
        if (rc == 0 && strstr(r, "complete")) {                 // "OK state complete"
            snprintf(reply, rlen, "OK loaded (%d lần hỏi) %s", polls, r);
            return 0;
        }
        // Không phải trang web foreground (no-webview/SKIP) — chịu vài lần đầu (chuyển app còn chớp),
        // nhưng nếu kéo dài thì dừng sớm, đừng chờ vô ích hết timeout.
        if (rc == 0 && (strstr(r, "no-webview") || strncmp(r, "SKIP", 4) == 0)) {
            if (++noweb >= 6) { snprintf(reply, rlen, "%s (không có trang web foreground)", r); return 1; }
        } else {
            noweb = 0;
        }
        gettimeofday(&tv, NULL);
        long now_ms = (long)tv.tv_sec * 1000 + tv.tv_usec / 1000;
        if (now_ms >= deadline_ms) {
            snprintf(reply, rlen, "TIMEOUT sau %ds (trạng thái cuối: %s)", timeout_sec, last[0] ? last : "?");
            return 1;
        }
        usleep(350 * 1000);                                     // nghỉ 350ms giữa mỗi lần hỏi readyState
    }
}

int touch_ocr(char *reply, size_t rlen, const char *lang) {
    return touch_ocr_region(reply, rlen, lang, 0, 0, 0, 0);
}

// Mốc ms đơn điệu — đo thời từng khâu OCR (gate+chụp / gửi+Vision) để soi nghẽn qua log.
static long ocr_now_ms(void) {
    struct timeval tv; gettimeofday(&tv, NULL);
    return (long)(tv.tv_sec * 1000L + tv.tv_usec / 1000);
}

int touch_ocr_region(char *reply, size_t rlen, const char *lang, int rx, int ry, int rw, int rh) {
    if (!lang || !lang[0]) lang = "en-US,vi-VN";
    // 1) Chụp framebuffer ĐỘ PHÂN GIẢI CAO (fbcap: native, quality 80) cho OCR chính xác —
    //    thay ảnh SHOT thu nhỏ 0.7× cũ (chữ nhỏ như "No SIM" bị mờ).
    long t0 = ocr_now_ms();
    unsigned char *img = NULL; size_t sz = 0;
    int rc = fbcap_jpeg(&img, &sz, 1.0, 80);
    long t1 = ocr_now_ms();
    if (rc != 0 || !img) { free(img); snprintf(reply, rlen, "fbcap OCR lỗi rc=%d", rc); return 1; }
    // 2) base64 → verb "OCRIMG <lang> <b64>[ rx ry rw rh]\n" — vùng (point) đặt SAU b64 để
    //    giữ tương thích format cũ; tweak dùng Vision regionOfInterest chỉ nhận dạng trong vùng.
    size_t b64len = 0; char *b64 = b64_encode(img, sz, &b64len); free(img);
    if (!b64) { snprintf(reply, rlen, "oom base64"); return 1; }
    size_t vlen = 8 + strlen(lang) + 1 + b64len + 4 * 13 + 2;
    char *verb = malloc(vlen);
    if (!verb) { free(b64); snprintf(reply, rlen, "oom verb"); return 1; }
    if (rw > 0 && rh > 0)
        snprintf(verb, vlen, "OCRIMG %s %s %d %d %d %d\n", lang, b64, rx, ry, rw, rh);
    else
        snprintf(verb, vlen, "OCRIMG %s %s\n", lang, b64);
    free(b64);
    // 3) gửi app foreground (prefer_sb=0); ảnh lớn + Vision accurate → timeout 12s
    int r = send_verb_core_to(verb, reply, rlen, 1, 0, 12000);
    // Mọi client SKIP (chỉ còn SpringBoard — không app foreground chạy được Vision) → last="no-reply".
    if (r != 0 && strcmp(reply, "no-reply") == 0)
        snprintf(reply, rlen, "cần app foreground (mở khoá + mở 1 app để chạy Vision/ANE)");
    long t2 = ocr_now_ms();
    log_msg("ocr: %zuKB lang=%s vùng=[%d,%d,%d,%d] · gate+chụp=%ldms gửi+vision=%ldms",
            sz / 1024, lang, rx, ry, rw, rh, t1 - t0, t2 - t1);
    free(verb);
    return r;
}
