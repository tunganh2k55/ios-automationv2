#ifndef IOSAUTO_PROFILESTORE_H
#define IOSAUTO_PROFILESTORE_H
#include <stddef.h>

// Kho gán "device profile → app". Daemon GHI, tweak spoof (Tweak.mm) ĐỌC để giả lập
// định danh thiết bị trong tiến trình app đích.
// Plist dùng chung: /var/jb/var/mobile/Library/Preferences/com.iosauto.deviceprofiles.plist
//   { "<bundleId>" = { deviceModel, hardwareIdentifier, systemName, systemVersion,
//                      deviceName, localeIdentifier, languageCode, timezoneIdentifier,
//                      screenWidth, screenHeight, screenScale }, ... }

#ifdef __cplusplus
extern "C" {
#endif

// Gán profile cho 1 app. Trả 0 nếu OK, khác 0 nếu lỗi (mô tả vào err).
int profilestore_apply(const char *bundle_id,
                       const char *device_model, const char *hardware_id,
                       const char *system_name, const char *system_version,
                       const char *device_name, const char *locale_id,
                       const char *language_code, const char *timezone_id,
                       int screen_w, int screen_h, double screen_scale,
                       char *err, size_t err_len);

// Xoá gán 1 app (bundle_id NULL/rỗng → xoá TẤT CẢ). Trả 0 nếu OK.
int profilestore_clear(const char *bundle_id);

// Chọn NGẪU NHIÊN 1 profile hợp lệ (catalog nhúng sẵn) rồi gán cho bundle_id.
// out_json (tuỳ chọn): ghi profile đã chọn dạng JSON để trả về. Trả 0 nếu OK, khác 0 + err nếu lỗi.
int profilestore_random_apply(const char *bundle_id, char *out_json, size_t out_json_len,
                              char *err, size_t err_len);

// Gán CỤ THỂ iOS + model cho app (tra hardware/màn từ catalog model). Trả 0/OK, khác 0 + err.
int profilestore_apply_spec(const char *bundle_id, const char *ios, const char *model,
                            char *out_json, size_t out_json_len, char *err, size_t err_len);

// Random TOÀN BỘ identity chung (_global): model/iOS/timezone/region/carrier/tên máy.
// Áp cho MỌI app trong target list. out_json: identity đã chọn. Trả 0/OK.
int profilestore_random_global(char *out_json, size_t out_json_len);

// ---- Global spoof config (áp cho MỌI app trong target list; per-app đè global ở field trùng) ----
// key: "deviceName" | "systemVersion" | "timezoneIdentifier" | "regionCode". Trả 0/OK.
int profilestore_global_set(const char *key, const char *value);
// Carrier (chỉ LƯU config — tweak chưa enforce). name/mcc/mnc: NULL = giữ nguyên.
int profilestore_global_set_carrier(const char *name, const char *mcc, const char *mnc);
// Thêm bundle vào target list (chỉ app trong list được spoof). Trả 0/OK.
int profilestore_target_add(const char *bundle_id);
// Xoá TOÀN BỘ config spoof (global + targets + per-app). Trả 0/OK.
int profilestore_reset(void);

// Ghi JSON {"<bundleId>":{...}, ...} (rỗng → "{}") vào out. Trả số byte đã ghi.
size_t profilestore_list_json(char *out, size_t out_len);

#ifdef __cplusplus
}
#endif

#endif
