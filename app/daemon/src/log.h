#ifndef IOSAUTO_LOG_H
#define IOSAUTO_LOG_H
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

void log_init(void);
void log_msg(const char *fmt, ...);

// Ghi các dòng log gần đây thành JSON array vào `out` (an toàn theo mutex).
// Trả về số byte đã ghi (không kể '\0').
size_t log_json(char *out, size_t out_len);

#ifdef __cplusplus
}
#endif

#endif
