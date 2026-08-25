#include "input_manager.h"
#include "touch.h"
#include "log.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>
#include <sys/time.h>

// ============================================================================
// UNIFIED INPUT MANAGER - Implementation
// ============================================================================

// Timeout cho stuck touch (ms) - nếu không có event sau khoảng này, tự CANCEL
#define STUCK_TOUCH_TIMEOUT_MS 2000

// Session counter
static int g_session_counter = 0;
static int g_identity_counter = 0;

// Current session
static TouchSession g_session = {0};
static pthread_mutex_t g_session_mu = PTHREAD_MUTEX_INITIALIZER;

// Screen size (points)
static int g_screen_w = 390, g_screen_h = 844;

// Last event tracking (cho debug)
static InputPhase g_last_phase = INPUT_PHASE_UP;
static int g_last_x = 0, g_last_y = 0;
static long g_last_event_ms = 0;

// ============================================================================
// HELPERS
// ============================================================================

static long now_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (long)tv.tv_sec * 1000 + tv.tv_usec / 1000;
}

// ============================================================================
// INIT
// ============================================================================

void input_manager_init(void) {
    pthread_mutex_lock(&g_session_mu);
    memset(&g_session, 0, sizeof(g_session));
    g_session_counter = 0;
    g_identity_counter = 0;
    pthread_mutex_unlock(&g_session_mu);
    log_msg("input_manager: initialized");
}

void input_set_screen_size(int w, int h) {
    if (w > 0 && h > 0) {
        g_screen_w = w;
        g_screen_h = h;
        log_msg("input_manager: screen size %dx%d", w, h);
    }
}

void input_get_screen_size(int *w, int *h) {
    if (w) *w = g_screen_w;
    if (h) *h = g_screen_h;
}

// ============================================================================
// TARGET RESOLVER
// ============================================================================

// Kiểm tra xem SpringBoard có đang hiển thị không
// Logic:
//   - Nếu không có foreground app → SpringBoard
//   - Nếu foreground app là SpringBoard → SpringBoard
//   - Nếu System UI đang hiển thị (Control Center, Notification Center, App Switcher) → SpringBoard
//   - Ngược lại → foreground app
//
// Hiện tại dựa vào danh sách client từ touch.c
// TODO: Hỏi system thực sự qua SBSCopyFrontmostApplicationDisplayIdentifier

InputTargetType input_resolve_target(char *bundle_out, size_t bundle_len) {
    if (bundle_out && bundle_len > 0) bundle_out[0] = '\0';

    // Lấy danh sách client từ touch relay
    InputClient clients[8];
    int n = input_get_clients(clients, 8);

    if (n == 0) {
        // Không có client nào → không thể resolve
        log_msg("input_manager: resolve target - no clients");
        return INPUT_TARGET_NONE;
    }

    // Tìm SpringBoard và app foreground
    int sb_idx = -1;
    int app_idx = -1;

    for (int i = n - 1; i >= 0; i--) {  // ưu tiên client mới nhất
        if (clients[i].is_springboard) {
            sb_idx = i;
        } else if (app_idx < 0) {
            app_idx = i;  // app mới nhất (không phải SpringBoard)
        }
    }

    // Logic resolve:
    // - Nếu có app foreground (không phải SpringBoard) → ưu tiên app
    // - Ngược lại → SpringBoard
    //
    // TODO: Hỏi system thực sự để biết chính xác ai đang foreground
    // Hiện tại giả định: app mới kết nối gần nhất (không phải SB) là foreground

    if (app_idx >= 0) {
        if (bundle_out && bundle_len > 0) {
            snprintf(bundle_out, bundle_len, "%s", clients[app_idx].bundle);
        }
        return INPUT_TARGET_APP;
    }

    if (sb_idx >= 0) {
        if (bundle_out && bundle_len > 0) {
            snprintf(bundle_out, bundle_len, "com.apple.springboard");
        }
        return INPUT_TARGET_SPRINGBOARD;
    }

    return INPUT_TARGET_NONE;
}

int input_query_foreground(char *bundle_out, size_t bundle_len) {
    InputTargetType t = input_resolve_target(bundle_out, bundle_len);
    return (t != INPUT_TARGET_NONE) ? 0 : -1;
}

// ============================================================================
// COORDINATE MAPPER
// ============================================================================

void input_map_coords(int src_x, int src_y, int src_w, int src_h,
                      int *out_x, int *out_y) {
    // Map từ src coordinate space sang iOS screen points
    // Xử lý scale, orientation, viewport

    if (src_w <= 0 || src_h <= 0) {
        // Không cần map, đã là screen points
        *out_x = src_x;
        *out_y = src_y;
        return;
    }

    // Scale theo tỉ lệ
    double sx = (double)g_screen_w / (double)src_w;
    double sy = (double)g_screen_h / (double)src_h;

    *out_x = (int)(src_x * sx);
    *out_y = (int)(src_y * sy);

    // Clamp
    if (*out_x < 0) *out_x = 0;
    if (*out_y < 0) *out_y = 0;
    if (*out_x >= g_screen_w) *out_x = g_screen_w - 1;
    if (*out_y >= g_screen_h) *out_y = g_screen_h - 1;
}

// ============================================================================
// TOUCH SESSION MANAGEMENT
// ============================================================================

const TouchSession* input_get_session(void) {
    return &g_session;
}

void input_force_cancel_stuck(void) {
    pthread_mutex_lock(&g_session_mu);

    if (g_session.active) {
        long now = now_ms();
        long elapsed = now - g_session.last_event_ms;

        if (elapsed > STUCK_TOUCH_TIMEOUT_MS) {
            log_msg("input_manager: FORCE CANCEL stuck session %d (idle %ldms)",
                    g_session.session_id, elapsed);

            // Gửi UP để release
            char err[128];
            touch_pointer('u', g_session.current_x, g_session.current_y, err, sizeof(err));

            // Reset session
            g_session.active = 0;

            g_last_phase = INPUT_PHASE_CANCEL;
            g_last_event_ms = now;
        }
    }

    pthread_mutex_unlock(&g_session_mu);
}

// ============================================================================
// CORE TOUCH API
// ============================================================================

int input_touch_down(int x, int y, char *err, size_t err_len) {
    pthread_mutex_lock(&g_session_mu);

    // Nếu có session đang active, cancel nó trước
    if (g_session.active) {
        log_msg("input_manager: DOWN while session %d active, canceling old",
                g_session.session_id);
        char e[128];
        touch_pointer('u', g_session.current_x, g_session.current_y, e, sizeof(e));
        g_session.active = 0;
    }

    // Resolve target
    char target_bundle[128] = {0};
    InputTargetType target = input_resolve_target(target_bundle, sizeof(target_bundle));

    if (target == INPUT_TARGET_NONE) {
        pthread_mutex_unlock(&g_session_mu);
        snprintf(err, err_len, "no target available (mở khoá + mở app)");
        return 0;
    }

    // Tạo session mới
    long now = now_ms();
    g_session_counter++;
    g_identity_counter++;

    g_session.active = 1;
    g_session.session_id = g_session_counter;
    g_session.touch_index = 0;
    g_session.touch_identity = g_identity_counter;
    g_session.target = target;
    snprintf(g_session.target_bundle, sizeof(g_session.target_bundle), "%s", target_bundle);
    g_session.start_x = x;
    g_session.start_y = y;
    g_session.current_x = x;
    g_session.current_y = y;
    g_session.start_time_ms = now;
    g_session.last_event_ms = now;

    // Update last event tracking
    g_last_phase = INPUT_PHASE_DOWN;
    g_last_x = x;
    g_last_y = y;
    g_last_event_ms = now;

    int sid = g_session.session_id;
    pthread_mutex_unlock(&g_session_mu);

    // Gửi DOWN tới tweak
    int rc = touch_pointer('d', x, y, err, err_len);

    log_msg("INPUT DOWN x=%d y=%d → TARGET %s SESSION id=%d identity=%d",
            x, y,
            target == INPUT_TARGET_SPRINGBOARD ? "SpringBoard" : target_bundle,
            sid, g_identity_counter);

    return rc == 0 ? sid : 0;
}

int input_touch_move(int x, int y, char *err, size_t err_len) {
    pthread_mutex_lock(&g_session_mu);

    if (!g_session.active) {
        pthread_mutex_unlock(&g_session_mu);
        snprintf(err, err_len, "no active session");
        return -1;
    }

    long now = now_ms();
    g_session.current_x = x;
    g_session.current_y = y;
    g_session.last_event_ms = now;

    g_last_phase = INPUT_PHASE_MOVE;
    g_last_x = x;
    g_last_y = y;
    g_last_event_ms = now;

    int sid = g_session.session_id;
    pthread_mutex_unlock(&g_session_mu);

    // Gửi MOVE tới tweak (KHÔNG log để tránh spam)
    int rc = touch_pointer('m', x, y, err, err_len);

    return rc == 0 ? sid : -1;
}

int input_touch_up(int x, int y, char *err, size_t err_len) {
    pthread_mutex_lock(&g_session_mu);

    if (!g_session.active) {
        pthread_mutex_unlock(&g_session_mu);
        snprintf(err, err_len, "no active session");
        return -1;
    }

    long now = now_ms();
    int sid = g_session.session_id;
    long duration = now - g_session.start_time_ms;

    // Log trước khi reset
    log_msg("INPUT UP x=%d y=%d SESSION END id=%d (duration=%ldms)", x, y, sid, duration);

    // Reset session
    g_session.active = 0;

    g_last_phase = INPUT_PHASE_UP;
    g_last_x = x;
    g_last_y = y;
    g_last_event_ms = now;

    pthread_mutex_unlock(&g_session_mu);

    // Gửi UP tới tweak
    int rc = touch_pointer('u', x, y, err, err_len);

    return rc == 0 ? 0 : -1;
}

int input_touch_cancel(char *err, size_t err_len) {
    pthread_mutex_lock(&g_session_mu);

    if (!g_session.active) {
        pthread_mutex_unlock(&g_session_mu);
        snprintf(err, err_len, "no active session");
        return 0;  // OK, không có gì để cancel
    }

    int x = g_session.current_x;
    int y = g_session.current_y;
    int sid = g_session.session_id;

    log_msg("INPUT CANCEL SESSION id=%d at (%d,%d)", sid, x, y);

    // Reset session
    g_session.active = 0;

    long now = now_ms();
    g_last_phase = INPUT_PHASE_CANCEL;
    g_last_x = x;
    g_last_y = y;
    g_last_event_ms = now;

    pthread_mutex_unlock(&g_session_mu);

    // Gửi UP để release
    touch_pointer('u', x, y, err, err_len);

    return 0;
}

// ============================================================================
// HIGH-LEVEL GESTURES
// ============================================================================

int input_tap(int x, int y, char *err, size_t err_len) {
    int sid = input_touch_down(x, y, err, err_len);
    if (sid <= 0) return -1;

    usleep(50 * 1000);  // 50ms delay

    return input_touch_up(x, y, err, err_len);
}

int input_swipe(int x1, int y1, int x2, int y2, double duration_sec, char *err, size_t err_len) {
    if (duration_sec <= 0) duration_sec = 0.3;
    if (duration_sec > 5.0) duration_sec = 5.0;

    int sid = input_touch_down(x1, y1, err, err_len);
    if (sid <= 0) return -1;

    // Chia thành các bước MOVE
    int steps = (int)(duration_sec * 60);  // 60 steps/sec
    if (steps < 5) steps = 5;
    if (steps > 300) steps = 300;

    double dx = (double)(x2 - x1) / steps;
    double dy = (double)(y2 - y1) / steps;
    int step_delay_us = (int)(duration_sec * 1e6 / steps);

    for (int i = 1; i <= steps; i++) {
        int x = x1 + (int)(dx * i);
        int y = y1 + (int)(dy * i);

        int rc = input_touch_move(x, y, err, err_len);
        if (rc < 0) {
            // Session bị cancel
            return -1;
        }

        usleep(step_delay_us);
    }

    return input_touch_up(x2, y2, err, err_len);
}

int input_long_press(int x, int y, double duration_sec, char *err, size_t err_len) {
    if (duration_sec <= 0) duration_sec = 1.0;
    if (duration_sec > 10.0) duration_sec = 10.0;

    int sid = input_touch_down(x, y, err, err_len);
    if (sid <= 0) return -1;

    // Chờ duration (chia nhỏ để có thể cancel)
    long steps = (long)(duration_sec / 0.05);
    for (long i = 0; i < steps; i++) {
        pthread_mutex_lock(&g_session_mu);
        int active = g_session.active;
        pthread_mutex_unlock(&g_session_mu);

        if (!active) {
            // Session bị cancel
            snprintf(err, err_len, "session cancelled");
            return -1;
        }
        usleep(50 * 1000);
    }

    return input_touch_up(x, y, err, err_len);
}

int input_drag(int x1, int y1, int x2, int y2, double duration_sec, char *err, size_t err_len) {
    // Giống swipe
    return input_swipe(x1, y1, x2, y2, duration_sec, err, err_len);
}

// ============================================================================
// CLIENT MANAGEMENT
// ============================================================================

// Extern từ touch.c (sẽ thêm)
extern int touch_get_clients(char bundles[][128], int *is_sb, int max_clients);

int input_get_clients(InputClient *clients, int max_clients) {
    if (!clients || max_clients <= 0) return 0;

    char bundles[8][128];
    int is_sb[8];

    int n = touch_get_clients(bundles, is_sb, max_clients < 8 ? max_clients : 8);

    for (int i = 0; i < n && i < max_clients; i++) {
        memset(&clients[i], 0, sizeof(InputClient));
        snprintf(clients[i].bundle, sizeof(clients[i].bundle), "%s", bundles[i]);
        clients[i].connected = 1;
        clients[i].supports_touch = 1;
        clients[i].is_springboard = is_sb[i];
    }

    return n;
}

int input_springboard_connected(void) {
    InputClient clients[8];
    int n = input_get_clients(clients, 8);

    for (int i = 0; i < n; i++) {
        if (clients[i].is_springboard) return 1;
    }
    return 0;
}

// ============================================================================
// DEBUG / STATUS API
// ============================================================================

void input_get_status(InputStatus *status) {
    if (!status) return;
    memset(status, 0, sizeof(InputStatus));

    pthread_mutex_lock(&g_session_mu);

    // Foreground bundle
    input_resolve_target(status->foreground_bundle, sizeof(status->foreground_bundle));

    // Resolved target
    status->resolved_target = g_session.active ? g_session.target : INPUT_TARGET_NONE;
    if (g_session.active) {
        snprintf(status->resolved_bundle, sizeof(status->resolved_bundle), "%s", g_session.target_bundle);
    }

    // SpringBoard connected
    status->springboard_connected = input_springboard_connected();

    // Client count
    InputClient clients[8];
    status->client_count = input_get_clients(clients, 8);

    // Active touch
    status->active_touch = g_session.active;

    // Session copy
    memcpy(&status->session, &g_session, sizeof(TouchSession));

    // Last event
    status->last_phase = g_last_phase;
    status->last_x = g_last_x;
    status->last_y = g_last_y;
    status->last_event_ms = g_last_event_ms;

    pthread_mutex_unlock(&g_session_mu);
}

char* input_status_json(void) {
    InputStatus s;
    input_get_status(&s);

    const char *phase_str = "UP";
    switch (s.last_phase) {
        case INPUT_PHASE_DOWN: phase_str = "DOWN"; break;
        case INPUT_PHASE_MOVE: phase_str = "MOVE"; break;
        case INPUT_PHASE_UP: phase_str = "UP"; break;
        case INPUT_PHASE_CANCEL: phase_str = "CANCEL"; break;
    }

    const char *target_str = "none";
    switch (s.resolved_target) {
        case INPUT_TARGET_SPRINGBOARD: target_str = "SpringBoard"; break;
        case INPUT_TARGET_APP: target_str = "app"; break;
        default: target_str = "none"; break;
    }

    char *json = malloc(2048);
    if (!json) return NULL;

    snprintf(json, 2048,
        "{"
        "\"foregroundBundle\":\"%s\","
        "\"resolvedTarget\":\"%s\","
        "\"resolvedBundle\":\"%s\","
        "\"springboardConnected\":%s,"
        "\"clientCount\":%d,"
        "\"activeTouch\":%s,"
        "\"session\":{"
            "\"id\":%d,"
            "\"identity\":%d,"
            "\"targetBundle\":\"%s\","
            "\"startX\":%d,\"startY\":%d,"
            "\"currentX\":%d,\"currentY\":%d,"
            "\"durationMs\":%ld"
        "},"
        "\"lastEvent\":{"
            "\"type\":\"%s\","
            "\"x\":%d,\"y\":%d"
        "}"
        "}",
        s.foreground_bundle,
        target_str,
        s.resolved_bundle,
        s.springboard_connected ? "true" : "false",
        s.client_count,
        s.active_touch ? "true" : "false",
        s.session.session_id,
        s.session.touch_identity,
        s.session.target_bundle,
        s.session.start_x, s.session.start_y,
        s.session.current_x, s.session.current_y,
        s.active_touch ? (now_ms() - s.session.start_time_ms) : 0,
        phase_str,
        s.last_x, s.last_y
    );

    return json;
}
