#ifndef IOSAUTO_INPUT_MANAGER_H
#define IOSAUTO_INPUT_MANAGER_H

#include <stddef.h>

// ============================================================================
// UNIFIED INPUT MANAGER
// Tất cả input (Web UI, Lua, REST API, WebSocket, VNC) phải đi qua đây.
// Không được để mỗi module tự implement touch riêng.
// ============================================================================

// Touch phase
typedef enum {
    INPUT_PHASE_DOWN = 0,
    INPUT_PHASE_MOVE = 1,
    INPUT_PHASE_UP   = 2,
    INPUT_PHASE_CANCEL = 3
} InputPhase;

// Target type (ai sẽ nhận touch)
typedef enum {
    INPUT_TARGET_NONE = 0,
    INPUT_TARGET_SPRINGBOARD = 1,
    INPUT_TARGET_APP = 2
} InputTargetType;

// Touch session state
typedef struct {
    int active;                     // session đang active?
    int session_id;                 // unique session id
    int touch_index;                // touch index (0 = primary)
    int touch_identity;             // identity không đổi từ DOWN→UP
    InputTargetType target;         // target đã resolve lúc DOWN
    char target_bundle[128];        // bundle id của target
    int start_x, start_y;           // điểm bắt đầu
    int current_x, current_y;       // điểm hiện tại
    long start_time_ms;             // thời điểm DOWN (ms)
    long last_event_ms;             // thời điểm event cuối (ms)
} TouchSession;

// Input status (cho debug API)
typedef struct {
    char foreground_bundle[128];    // app foreground hiện tại
    InputTargetType resolved_target;
    char resolved_bundle[128];      // bundle của target đã resolve
    int springboard_connected;      // SpringBoard tweak có kết nối?
    int client_count;               // số client tweak đang kết nối
    int active_touch;               // có touch đang active?
    TouchSession session;           // session hiện tại
    InputPhase last_phase;          // phase của event cuối
    int last_x, last_y;             // tọa độ event cuối
    long last_event_ms;             // thời điểm event cuối
} InputStatus;

// ============================================================================
// CORE API
// ============================================================================

// Khởi tạo InputManager (gọi 1 lần lúc daemon start, SAU touch_init)
void input_manager_init(void);

// Đặt kích thước màn thật (từ handshake với tweak hoặc device info)
void input_set_screen_size(int w, int h);

// Lấy kích thước màn (points)
void input_get_screen_size(int *w, int *h);

// ============================================================================
// UNIFIED INPUT API - tất cả nguồn input phải gọi qua đây
// ============================================================================

// Touch DOWN - bắt đầu session mới, resolve target, trả session_id (>0) hoặc 0 nếu lỗi
int input_touch_down(int x, int y, char *err, size_t err_len);

// Touch MOVE - di chuyển trong session hiện tại
int input_touch_move(int x, int y, char *err, size_t err_len);

// Touch UP - kết thúc session
int input_touch_up(int x, int y, char *err, size_t err_len);

// Touch CANCEL - hủy session (khi disconnect)
int input_touch_cancel(char *err, size_t err_len);

// ============================================================================
// HIGH-LEVEL GESTURES - dựa trên touch primitives
// ============================================================================

// Tap đơn = DOWN + delay + UP
int input_tap(int x, int y, char *err, size_t err_len);

// Swipe = DOWN + nhiều MOVE + UP
int input_swipe(int x1, int y1, int x2, int y2, double duration_sec, char *err, size_t err_len);

// Long press = DOWN + delay + UP
int input_long_press(int x, int y, double duration_sec, char *err, size_t err_len);

// Drag = DOWN + MOVE liên tục (theo callback) + UP
typedef void (*InputDragCallback)(int x, int y, void *ctx);
int input_drag(int x1, int y1, int x2, int y2, double duration_sec, char *err, size_t err_len);

// ============================================================================
// TARGET RESOLVER
// ============================================================================

// Resolve target tại thời điểm hiện tại (gọi nội bộ khi DOWN)
InputTargetType input_resolve_target(char *bundle_out, size_t bundle_len);

// Query foreground app (không cache, hỏi system)
int input_query_foreground(char *bundle_out, size_t bundle_len);

// ============================================================================
// COORDINATE MAPPER
// ============================================================================

// Map từ web/VNC coords sang iOS screen points
void input_map_coords(int src_x, int src_y, int src_w, int src_h,
                      int *out_x, int *out_y);

// ============================================================================
// SESSION MANAGEMENT
// ============================================================================

// Lấy session hiện tại (readonly)
const TouchSession* input_get_session(void);

// Hủy session bị stuck (timeout) - gọi từ watchdog
void input_force_cancel_stuck(void);

// ============================================================================
// DEBUG / STATUS API
// ============================================================================

// Lấy trạng thái đầy đủ cho /api/input/status
void input_get_status(InputStatus *status);

// Lấy trạng thái JSON (malloc, caller free)
char* input_status_json(void);

// ============================================================================
// CLIENT MANAGEMENT (cho tweak registry)
// ============================================================================

typedef struct {
    char bundle[128];
    int pid;
    int connected;
    int supports_touch;
    int is_springboard;
} InputClient;

// Lấy danh sách client đang kết nối
int input_get_clients(InputClient *clients, int max_clients);

// Check SpringBoard có kết nối không
int input_springboard_connected(void);

#endif // IOSAUTO_INPUT_MANAGER_H
