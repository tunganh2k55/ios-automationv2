#import <Foundation/Foundation.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
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

// Framebuffer: double-buffer để update không block VNC read
static void *g_front_buf = NULL;   // VNC đọc
static void *g_back_buf = NULL;    // capture ghi
static int g_fb_w = 0, g_fb_h = 0;
static size_t g_fb_bpr = 0;
static size_t g_fb_size = 0;

#ifdef HAVE_LIBVNCSERVER
static rfbScreenInfoPtr g_screen = NULL;

// ===== VNC CALLBACKS =====

// Client mới kết nối
static enum rfbNewClientAction vnc_new_client(rfbClientPtr cl) {
    __sync_add_and_fetch(&g_client_count, 1);
    log_msg("vnc: client kết nối, tổng %d", g_client_count);
    return RFB_CLIENT_ACCEPT;
}

// Client ngắt kết nối
static void vnc_client_gone(rfbClientPtr cl) {
    __sync_sub_and_fetch(&g_client_count, 1);
    log_msg("vnc: client ngắt, còn %d", g_client_count);
}

// Pointer event (mouse/touch từ VNC client)
static void vnc_ptr_event(int buttonMask, int x, int y, rfbClientPtr cl) {
    // Map VNC coordinates → iOS point coordinates
    // VNC coords = pixel, iOS touch = point (divide by scale factor)
    int pw = 0, ph = 0;
    touch_screen_size(&pw, &ph);
    if (pw <= 0 || ph <= 0) { pw = 390; ph = 844; }

    // Giả sử @2x scale
    int scale = 2;
    if (g_fb_w > 0 && pw > 0) {
        scale = g_fb_w / pw;
        if (scale < 1) scale = 1;
        if (scale > 3) scale = 3;
    }

    int tx = x / scale;
    int ty = y / scale;

    // State tracking per-client
    static int lastMask = 0;

    int leftNow = (buttonMask & 1) != 0;
    int leftPrev = (lastMask & 1) != 0;

    char err[128] = {0};

    if (leftNow && !leftPrev) {
        // Touch down
        touch_pointer('d', tx, ty, err, sizeof(err));
    } else if (!leftNow && leftPrev) {
        // Touch up
        touch_pointer('u', tx, ty, err, sizeof(err));
    } else if (leftNow) {
        // Touch move
        touch_pointer('m', tx, ty, err, sizeof(err));
    }

    // Middle button = power (nếu cần)
    // Right button = home (nếu cần)
    // TODO: implement khi có HID layer

    lastMask = buttonMask;
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
static void *vnc_capture_thread(void *arg) {
    (void)arg;
    log_msg("vnc: capture thread started");

    while (!g_capture_stop) {
        // Chỉ capture khi có client
        if (g_client_count > 0) {
            unsigned char *raw = NULL;
            size_t rawlen = 0;
            int w = 0, h = 0;
            size_t bpr = 0;

            int rc = fbcap_raw(&raw, &rawlen, &w, &h, &bpr);
            if (rc == 0 && raw) {
                vnc_update_fb(raw, w, h, bpr);
                vnc_mark_modified();
                free(raw);
            }

            // ~30fps khi có client
            usleep(33000);
        } else {
            // Idle: check mỗi 500ms
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

    // Alloc double buffer
    g_front_buf = calloc(1, g_fb_size);
    g_back_buf = calloc(1, g_fb_size);
    if (!g_front_buf || !g_back_buf) {
        log_msg("vnc: không đủ RAM cho framebuffer %dx%d", g_fb_w, g_fb_h);
        free(g_front_buf); free(g_back_buf);
        g_front_buf = g_back_buf = NULL;
        pthread_mutex_unlock(&g_vnc_mu);
        return -1;
    }

    // Tạo VNC screen
    int argc = 0;
    g_screen = rfbGetScreen(&argc, NULL, g_fb_w, g_fb_h, 8, 3, 4);
    if (!g_screen) {
        log_msg("vnc: rfbGetScreen thất bại");
        free(g_front_buf); free(g_back_buf);
        g_front_buf = g_back_buf = NULL;
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

    // Callbacks
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
    free(g_back_buf); g_back_buf = NULL;
    g_running = 0;
    g_client_count = 0;

    log_msg("vnc: server dừng");
    pthread_mutex_unlock(&g_vnc_mu);
}

int vnc_running(void) {
    return g_running;
}

int vnc_update_fb(const void *data, int w, int h, size_t bpr) {
    if (!g_running || !data) return -1;

#ifdef HAVE_LIBVNCSERVER
    pthread_mutex_lock(&g_vnc_mu);

    // Resize nếu cần
    if (w != g_fb_w || h != g_fb_h) {
        size_t new_bpr = (size_t)w * 4;
        size_t new_size = new_bpr * (size_t)h;
        void *new_front = realloc(g_front_buf, new_size);
        void *new_back = realloc(g_back_buf, new_size);
        if (new_front && new_back) {
            g_front_buf = new_front;
            g_back_buf = new_back;
            g_fb_w = w;
            g_fb_h = h;
            g_fb_bpr = new_bpr;
            g_fb_size = new_size;

            rfbNewFramebuffer(g_screen, (char *)g_front_buf, w, h, 8, 3, 4);
            g_screen->paddedWidthInBytes = new_bpr;
        }
    }

    // Copy vào back buffer
    if (bpr == g_fb_bpr) {
        memcpy(g_back_buf, data, g_fb_size);
    } else {
        // Row-by-row copy (stride khác nhau)
        size_t copy_w = (bpr < g_fb_bpr) ? bpr : g_fb_bpr;
        for (int y = 0; y < h && y < g_fb_h; y++) {
            memcpy((char *)g_back_buf + y * g_fb_bpr,
                   (const char *)data + y * bpr,
                   copy_w);
        }
    }

    // Swap front/back
    void *tmp = g_front_buf;
    g_front_buf = g_back_buf;
    g_back_buf = tmp;
    g_screen->frameBuffer = (char *)g_front_buf;

    pthread_mutex_unlock(&g_vnc_mu);
#endif

    return 0;
}

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
