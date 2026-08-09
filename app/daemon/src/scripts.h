#ifndef IOSAUTO_SCRIPTS_H
#define IOSAUTO_SCRIPTS_H
#include <stddef.h>

// Quản lý file script Lua trên đĩa (/var/jb/usr/local/iosauto/scripts).

// Tạo thư mục scripts nếu chưa có. Gọi 1 lần lúc khởi động.
void scripts_init(void);

// Tên hợp lệ: [A-Za-z0-9._-], 1..64 ký tự, không "..", không bắt đầu bằng '.'. 1=hợp lệ.
int scripts_valid_name(const char *name);

// JSON mảng [{"name":..,"size":..,"mtime":..}, ...] vào out.
void scripts_list_json(char *out, size_t cap);

// Đọc nội dung file → out (NUL-terminated). Trả số byte đọc, -1 nếu lỗi/tên sai.
long scripts_read(const char *name, char *out, size_t cap);

// Ghi nội dung (len byte) vào file. Trả 0 nếu OK, -1 nếu lỗi/tên sai.
int scripts_save(const char *name, const char *content, size_t len);

// Xoá file. Trả 0 nếu OK, -1 nếu lỗi/tên sai.
int scripts_delete(const char *name);

#endif
