#ifndef IOSAUTO_IMAGES_H
#define IOSAUTO_IMAGES_H
#include <stddef.h>

// Thư mục ảnh người dùng cắt & lưu: /var/jb/usr/local/iosauto/images
void images_init(void);
int  images_valid_name(const char *name);                 // chỉ chữ/số . _ - , <=80, không ".." / ẩn
void images_list_json(char *out, size_t cap);             // [{"name","size","mtime"}]
int  images_save_b64(const char *name, const char *b64, size_t b64len);  // decode base64 → ghi. 0=OK
char *images_read_b64(const char *name, size_t *outlen);  // đọc file → base64 (malloc, tự free). NULL nếu lỗi
int  images_delete(const char *name);                     // 0=OK

#endif
