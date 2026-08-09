#ifndef IOSAUTO_CRASHLOG_H
#define IOSAUTO_CRASHLOG_H

// Cài bắt tín hiệu chết (SIGSEGV/SIGBUS/SIGABRT/SIGILL/SIGFPE/SIGTRAP) → ghi backtrace vào
// log (stderr → /var/jb/var/log/iosautod.log) rồi re-raise để launchd thấy & restart.
// Cài atexit → ghi 1 dòng khi thoát "êm". Nhờ đó phân biệt:
//   - có dòng "FATAL signal" → daemon CRASH do lỗi code (kèm backtrace).
//   - có dòng "atexit"       → thoát bình thường.
//   - KHÔNG có cả hai trước lúc "iosautod khởi động" lại → bị KILL CỨNG (SIGKILL/jetsam/OOM,
//     không bắt được) → nghi bộ nhớ.
void crashlog_install(void);

// Ghi 1 dòng bộ nhớ: RAM trống hệ thống (MB) + RSS của daemon (MB), kèm nhãn tag.
void iosauto_mem_log(const char *tag);

#endif
