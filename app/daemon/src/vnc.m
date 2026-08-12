#import <Foundation/Foundation.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <math.h>
#include <time.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#include "vnc.h"
#include "touch.h"
#include "fbcap.h"
#include "log.h"

#ifdef HAVE_LIBVNCSERVER
#include <rfb/rfb.h>
#include <rfb/keysym.h>
#endif

// ===== GLOBAL STATE =====
static pthread_mutex_t g_vnc_mu = PTHREAD_MUTEX_INITIALIZER;
static int g_running = 0;
static int g_port = 5900;
static int g_client_count = 0;
static pthread_t g_capture_thread = 0;
static int g_capture_stop = 0;

// VNC pointer state: lưu vị trí + thời điểm DOWN để quyết định tap vs swipe khi UP.
// Đây là fallback test — sau này port TrollVNC input implementation thực sự.
static int g_vnc_down_x = 0, g_vnc_down_y = 0;
static int g_vnc_last_x = 0, g_vnc_last_y = 0;
static uint64_t g_vnc_down_time = 0;   // mach_absolute_time hoặc clock_gettime

// Framebuffer: 1 buffer duy nhất. libvncserver ĐỌC nó (encode gửi client), đồng thời nó là
// THAM CHIẾU KHUNG TRƯỚC cho diff — band nào không đổi thì đã đúng sẵn, khỏi copy/gửi lại.
static void *g_front_buf = NULL;
static int g_fb_w = 0, g_fb_h = 0;
static size_t g_fb_bpr = 0;
static size_t g_fb_size = 0;

// Dirty-rect: chia màn thành các DẢI ngang cao VNC_TILE_H pixel. Mỗi khung chỉ so sánh + copy +
// mark những dải thay đổi → cắt cả CPU encode lẫn băng thông (màn tĩnh ≈ 0 traffic).
#define VNC_TILE_H 32

#ifdef HAVE_LIBVNCSERVER
static rfbScreenInfoPtr g_screen = NULL;
static int g_ptr_mask = 0;   // nút trái RFB lần trước (theo dõi down→up); reset khi client ngắt

// ===== VNC CALLBACKS =====
static void vnc_client_gone(rfbClientPtr cl);   // forward-decl (gắn per-client trong newClientHook)

// Client mới kết nối
static enum rfbNewClientAction vnc_new_client(rfbClientPtr cl) {
    __sync_add_and_fetch(&g_client_count, 1);
    g_ptr_mask = 0;
    // clientGoneHook là hook PER-CLIENT (rfbClientRec), KHÔNG phải per-screen → gắn tại đây.
    cl->clientGoneHook = vnc_client_gone;
    log_msg("vnc: client kết nối, tổng %d", g_client_count);
    return RFB_CLIENT_ACCEPT;
}

// Client ngắt kết nối
static void vnc_client_gone(rfbClientPtr cl) {
    int n = __sync_sub_and_fetch(&g_client_count, 1);
    if (n < 0) __sync_bool_compare_and_swap(&g_client_count, n, 0);
    g_ptr_mask = 0;   // tránh client sau bị kẹt "đang nhấn"
    log_msg("vnc: client ngắt, còn %d", g_client_count);
}

// Lấy timestamp ms hiện tại (monotonic).
static uint64_t vnc_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

// Pointer event (mouse/touch từ VNC client).
// FALLBACK TEST: route sang IATap/IASwipe để chứng minh VNC pipeline hoạt động.
// Sau khi xác nhận tap/swipe chạy, thay lớp này bằng TrollVNC input implementation.
//
// Logic:
//   DOWN → lưu x0,y0,time
//   MOVE → lưu x,y cuối
//   UP   → distance < 8px => IATap(x,y)
//          else           => IASwipe(x0,y0,x,y,duration)
static void vnc_ptr_event(int buttonMask, int x, int y, rfbClientPtr cl) {
    int pw = 0, ph = 0;
    touch_screen_size(&pw, &ph);
    if (pw <= 0 || ph <= 0) { pw = 390; ph = 844; }

    // noVNC gửi toạ độ theo PIXEL của framebuffer (g_fb_w×g_fb_h). Map pixel→point theo TỈ LỆ THỰC
    // (không giả định @2x — máy khác scale khác), rồi kẹp trong màn.
    int fbw = g_fb_w > 0 ? g_fb_w : pw;
    int fbh = g_fb_h > 0 ? g_fb_h : ph;
    int tx = (int)((long long)x * pw / fbw);
    int ty = (int)((long long)y * ph / fbh);
    if (tx < 0) tx = 0; else if (tx > pw - 1) tx = pw - 1;
    if (ty < 0) ty = 0; else if (ty > ph - 1) ty = ph - 1;

    int leftNow = (buttonMask & 1) != 0;
    int leftPrev = (g_ptr_mask & 1) != 0;
    g_ptr_mask = buttonMask;

    char err[128] = {0};
    if (leftNow && !leftPrev) {
        // DOWN: lưu vị trí + thời điểm bắt đầu
        g_vnc_down_x = tx;
        g_vnc_down_y = ty;
        g_vnc_last_x = tx;
        g_vnc_last_y = ty;
        g_vnc_down_time = vnc_now_ms();
        log_msg("vnc: DOWN pt(%d,%d) px(%d,%d) fb=%dx%d", tx, ty, x, y, fbw, fbh);
    } else if (!leftNow && leftPrev) {
        // UP: quyết định tap hay swipe dựa trên distance
        int dx = g_vnc_last_x - g_vnc_down_x;
        int dy = g_vnc_last_y - g_vnc_down_y;
        int dist = (int)sqrt((double)(dx*dx + dy*dy));
        uint64_t dur_ms = vnc_now_ms() - g_vnc_down_time;
        double dur_sec = dur_ms / 1000.0;
        if (dur_sec < 0.1) dur_sec = 0.1;   // tối thiểu 100ms cho swipe
        if (dur_sec > 2.0) dur_sec = 2.0;   // tối đa 2s

        if (dist < 8) {
            // Tap: di chuyển ít, coi như click
            int rc = touch_tap(g_vnc_last_x, g_vnc_last_y, err, sizeof(err));
            log_msg("vnc: UP → TAP pt(%d,%d) dist=%d rc=%d %s", g_vnc_last_x, g_vnc_last_y, dist, rc, err);
        } else {
            // Swipe: di chuyển đủ xa
            int rc = touch_swipe(g_vnc_down_x, g_vnc_down_y, g_vnc_last_x, g_vnc_last_y, dur_sec, err, sizeof(err));
            log_msg("vnc: UP → SWIPE (%d,%d)→(%d,%d) dist=%d dur=%.2fs rc=%d %s",
                    g_vnc_down_x, g_vnc_down_y, g_vnc_last_x, g_vnc_last_y, dist, dur_sec, rc, err);
        }
    } else if (leftNow) {
        // MOVE: cập nhật vị trí cuối (không log để tránh spam)
        g_vnc_last_x = tx;
        g_vnc_last_y = ty;
    }
    // Middle/Right button (power/home) → TODO khi có TrollVNC HID layer.
}

// Keyboard event (từ VNC client)
static void vnc_kbd_event(rfbBool down, rfbKeySym keySym, rfbClientPtr cl) {
    // TODO: map keySym → touch layer hoặc HID keyboard
    // Hiện tại chưa có keyboard injection trong touch.h
    log_msg("vnc: key %s keySym=0x%x", down ? "down" : "up", (unsigned)keySym);
}

#endif // HAVE_LIBVNCSERVER

// ===== CAPTURE THREAD =====
// Thread liên tục capture framebuffer và update VNC khi có client kết nối.
// ADAPTIVE FPS: khi màn hình đang đổi → ~30fps cho mượt; khi tĩnh → giãn dần xuống 10fps rồi 4fps
// để không tốn CPU chụp/so sánh vô ích (dirty-rect báo 0 dải đổi).
static void *vnc_capture_thread(void *arg) {
    (void)arg;
    log_msg("vnc: capture thread started");

    int idle_frames = 0;

    while (!g_capture_stop) {
        // Chỉ capture khi có client
        if (g_client_count > 0) {
            unsigned char *raw = NULL;
            size_t rawlen = 0;
            int w = 0, h = 0;
            size_t bpr = 0;

            int dirty = 0;
            int rc = fbcap_raw(&raw, &rawlen, &w, &h, &bpr);
            if (rc == 0 && raw) {
                dirty = vnc_update_fb(raw, w, h, bpr);  // trả số dải thay đổi (đã tự mark)
                free(raw);
            }

            if (dirty > 0) {
                idle_frames = 0;
                usleep(33000);             // ~30fps khi màn đang đổi
            } else {
                if (idle_frames < 1000) idle_frames++;
                if (idle_frames > 30)      usleep(250000);  // >1s tĩnh → 4fps
                else if (idle_frames > 8)  usleep(100000);  // tĩnh ngắn → 10fps
                else                       usleep(33000);   // vừa mới đổi → vẫn 30fps
            }
        } else {
            // Idle: check mỗi 500ms
            idle_frames = 0;
            usleep(500000);
        }
    }

    log_msg("vnc: capture thread stopped");
    return NULL;
}

// ===== PUBLIC API =====

int vnc_init(int port, const char *password) {
    pthread_mutex_lock(&g_vnc_mu);

    if (g_running) {
        pthread_mutex_unlock(&g_vnc_mu);
        return 0;  // đã chạy
    }

    g_port = port > 0 ? port : 5900;

#ifdef HAVE_LIBVNCSERVER
    // Lấy kích thước màn hình
    int pw = 390, ph = 844;
    touch_screen_size(&pw, &ph);
    int scale = 2;  // @2x
    g_fb_w = pw * scale;
    g_fb_h = ph * scale;
    g_fb_bpr = (size_t)g_fb_w * 4;  // BGRA
    g_fb_size = g_fb_bpr * (size_t)g_fb_h;

    // Alloc framebuffer (khởi tạo 0 → khung đầu tiên full-dirty, gửi trọn màn 1 lần).
    g_front_buf = calloc(1, g_fb_size);
    if (!g_front_buf) {
        log_msg("vnc: không đủ RAM cho framebuffer %dx%d", g_fb_w, g_fb_h);
        pthread_mutex_unlock(&g_vnc_mu);
        return -1;
    }

    // Tạo VNC screen
    int argc = 0;
    g_screen = rfbGetScreen(&argc, NULL, g_fb_w, g_fb_h, 8, 3, 4);
    if (!g_screen) {
        log_msg("vnc: rfbGetScreen thất bại");
        free(g_front_buf); g_front_buf = NULL;
        pthread_mutex_unlock(&g_vnc_mu);
        return -2;
    }

    // Cấu hình pixel format: BGRA (iOS native)
    g_screen->serverFormat.redShift = 16;
    g_screen->serverFormat.greenShift = 8;
    g_screen->serverFormat.blueShift = 0;
    g_screen->paddedWidthInBytes = g_fb_bpr;
    g_screen->frameBuffer = (char *)g_front_buf;

    g_screen->desktopName = "iOSAuto VNC";
    g_screen->port = g_port;
    g_screen->ipv6port = g_port;

    // Callbacks. clientGoneHook gắn per-client trong vnc_new_client (không có ở struct screen).
    g_screen->newClientHook = vnc_new_client;
    g_screen->ptrAddEvent = vnc_ptr_event;
    g_screen->kbdAddEvent = vnc_kbd_event;

    // Password (nếu có)
    if (password && strlen(password) > 0) {
        static char *passwds[2] = { NULL, NULL };
        passwds[0] = strdup(password);
        g_screen->authPasswdData = (void *)passwds;
        g_screen->passwordCheck = rfbCheckPasswordByList;
    }

    // Init & run (background thread)
    rfbInitServer(g_screen);
    rfbRunEventLoop(g_screen, 40000, TRUE);  // 40ms timeout, background

    g_running = 1;
    log_msg("vnc: server khởi động port %d, fb %dx%d", g_port, g_fb_w, g_fb_h);

    // Start capture thread
    g_capture_stop = 0;
    pthread_create(&g_capture_thread, NULL, vnc_capture_thread, NULL);

#else
    // STUB: không có libvncserver
    log_msg("vnc: chưa có libvncserver, stub mode");
    g_running = 1;
#endif

    pthread_mutex_unlock(&g_vnc_mu);
    return 0;
}

void vnc_stop(void) {
    pthread_mutex_lock(&g_vnc_mu);

    if (!g_running) {
        pthread_mutex_unlock(&g_vnc_mu);
        return;
    }

    // Stop capture thread first
    g_capture_stop = 1;
    pthread_mutex_unlock(&g_vnc_mu);

    if (g_capture_thread) {
        pthread_join(g_capture_thread, NULL);
        g_capture_thread = 0;
    }

    pthread_mutex_lock(&g_vnc_mu);

#ifdef HAVE_LIBVNCSERVER
    if (g_screen) {
        rfbShutdownServer(g_screen, TRUE);
        rfbScreenCleanup(g_screen);
        g_screen = NULL;
    }
#endif

    free(g_front_buf); g_front_buf = NULL;
    g_running = 0;
    g_client_count = 0;

    log_msg("vnc: server dừng");
    pthread_mutex_unlock(&g_vnc_mu);
}

int vnc_running(void) {
    return g_running;
}

// Cập nhật framebuffer bằng DIFF theo dải ngang. Trả về SỐ DẢI thay đổi (0 = màn tĩnh, không gửi gì).
// g_front_buf giữ khung ĐÃ gửi (khung trước); ta so từng dải của khung mới với nó, chỉ dải nào khác
// mới copy đè + rfbMarkRectAsModified → libvncserver chỉ encode/gửi đúng vùng đó.
int vnc_update_fb(const void *data, int w, int h, size_t bpr) {
    if (!g_running || !data) return -1;

    int dirty_bands = 0;

#ifdef HAVE_LIBVNCSERVER
    pthread_mutex_lock(&g_vnc_mu);

    // Resize nếu cần → cấp lại buffer, ép khung này full-dirty (memset 0 để mọi dải khác nguồn).
    if (w != g_fb_w || h != g_fb_h) {
        size_t new_bpr = (size_t)w * 4;
        size_t new_size = new_bpr * (size_t)h;
        void *new_front = realloc(g_front_buf, new_size);
        if (new_front) {
            g_front_buf = new_front;
            g_fb_w = w;
            g_fb_h = h;
            g_fb_bpr = new_bpr;
            g_fb_size = new_size;
            memset(g_front_buf, 0, new_size);

            rfbNewFramebuffer(g_screen, (char *)g_front_buf, w, h, 8, 3, 4);
            g_screen->paddedWidthInBytes = new_bpr;
        }
    }

    const unsigned char *src = (const unsigned char *)data;
    unsigned char *front = (unsigned char *)g_front_buf;
    size_t row_bytes = (bpr < g_fb_bpr) ? bpr : g_fb_bpr;  // stride nguồn có thể lớn hơn (padding)
    int same_stride = (bpr == g_fb_bpr);

    for (int y0 = 0; y0 < g_fb_h; y0 += VNC_TILE_H) {
        int y1 = y0 + VNC_TILE_H;
        if (y1 > g_fb_h) y1 = g_fb_h;

        // So sánh dải [y0,y1).
        int changed = 0;
        if (same_stride) {
            size_t off = (size_t)y0 * g_fb_bpr;
            size_t len = (size_t)(y1 - y0) * g_fb_bpr;
            changed = (memcmp(src + off, front + off, len) != 0);
        } else {
            for (int y = y0; y < y1 && !changed; y++) {
                if (memcmp(src + (size_t)y * bpr, front + (size_t)y * g_fb_bpr, row_bytes) != 0)
                    changed = 1;
            }
        }
        if (!changed) continue;

        // Copy dải mới đè lên front rồi mark đúng vùng đó.
        if (same_stride) {
            size_t off = (size_t)y0 * g_fb_bpr;
            memcpy(front + off, src + off, (size_t)(y1 - y0) * g_fb_bpr);
        } else {
            for (int y = y0; y < y1; y++)
                memcpy(front + (size_t)y * g_fb_bpr, src + (size_t)y * bpr, row_bytes);
        }
        rfbMarkRectAsModified(g_screen, 0, y0, g_fb_w, y1);
        dirty_bands++;
    }

    pthread_mutex_unlock(&g_vnc_mu);
#endif

    return dirty_bands;
}

// GIỮ cho tương thích API — mark toàn màn (ép gửi lại trọn khung). Capture loop KHÔNG còn dùng
// (dirty-rect tự mark trong vnc_update_fb); chỉ gọi khi cần buộc refresh thủ công.
void vnc_mark_modified(void) {
#ifdef HAVE_LIBVNCSERVER
    if (g_running && g_screen) {
        rfbMarkRectAsModified(g_screen, 0, 0, g_fb_w, g_fb_h);
    }
#endif
}

int vnc_client_count(void) {
    return g_client_count;
}

// ===== WEBSOCKET PROXY =====
// noVNC kết nối qua WebSocket, cần proxy tới VNC server (TCP localhost:5900).
// Đây là implementation đơn giản, có thể dùng libwebsockets sau.

int vnc_websocket_upgrade(int client_fd, const char *headers) {
    // TODO: implement WebSocket handshake + proxy
    // 1. Parse Sec-WebSocket-Key từ headers
    // 2. Tính Sec-WebSocket-Accept = SHA1(key + magic) base64
    // 3. Gửi 101 Switching Protocols
    // 4. Spawn thread bridge: client_fd <--WebSocket frames--> TCP localhost:5900

    // Hiện tại trả 0 = không phải WS request
    return 0;
}
