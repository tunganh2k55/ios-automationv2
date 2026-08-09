#include "lslock.h"
#include <pthread.h>

// 1 mutex DÙNG CHUNG cho MỌI truy cập LaunchServices trong daemon (xem lslock.h). Không đệ quy —
// người gọi KHÔNG được giữ khoá này rồi gọi tiếp 1 hàm LS khác cũng khoá (tránh deadlock).
static pthread_mutex_t g_ls = PTHREAD_MUTEX_INITIALIZER;

void ia_ls_lock(void)   { pthread_mutex_lock(&g_ls); }
void ia_ls_unlock(void) { pthread_mutex_unlock(&g_ls); }
