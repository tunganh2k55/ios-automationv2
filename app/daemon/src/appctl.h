#ifndef IOSAUTO_APPCTL_H
#define IOSAUTO_APPCTL_H
#include <stddef.h>

// Mở app theo bundle id. Trả 0 nếu OK, khác 0 nếu lỗi (ghi mô tả vào err).
int appctl_launch(const char *bundle_id, char *err, size_t err_len);

// Đóng app theo bundle id. Trả 0 nếu OK.
int appctl_kill(const char *bundle_id, char *err, size_t err_len);

// Xoá TOÀN BỘ dữ liệu app (reset về như mới cài): kill app rồi xoá sạch data-container
// (Documents/Library/tmp… gồm cả Preferences = đăng nhập), giữ metadata container + tạo lại thư mục
// chuẩn. Ghi số mục đã xoá vào *removed (có thể NULL). Trả 0 nếu OK; diag/lỗi vào err.
int appctl_clear_data(const char *bundle_id, int *removed, char *err, size_t err_len);

// Ghi danh sách app đã cài dạng JSON array [{"bundleId":..,"name":..}] vào out.
// appctl_list_json: CHỈ app "User". appctl_list_all_json: thêm app "System" (Safari…).
size_t appctl_list_json(char *out, size_t out_len);
size_t appctl_list_all_json(char *out, size_t out_len);

// Thông tin thiết bị (best-effort). Ghi vào các buffer truyền vào.
void appctl_device_info(char *name, size_t name_len,
                        char *model, size_t model_len,
                        char *ios, size_t ios_len);

// Đặt tên thiết bị tuỳ chỉnh (rỗng = về mặc định hostname). Trả 0 nếu OK.
int appctl_set_device_name(const char *name);

// Serial number thiết bị (qua MobileGestalt). Ghi vào out (rỗng nếu không lấy được).
void appctl_serial(char *out, size_t out_len);

// Bật/tắt Airplane Mode (dùng để TẮT/BẬT sóng di động → xin IP 4G mới). on != 0 = BẬT airplane
// (ngắt sóng); on == 0 = TẮT airplane (bật lại sóng). Trả 0 nếu OK; mô tả lỗi vào err.
int appctl_set_airplane(int on, char *err, size_t err_len);

#endif
