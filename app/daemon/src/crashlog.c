#include "crashlog.h"
#include "log.h"
#include <signal.h>
#include <execinfo.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <mach/mach.h>

// ---- Bộ xử lý tín hiệu: chỉ dùng hàm async-signal-safe (write, backtrace_symbols_fd) ----
static void sig_handler(int sig) {
    const char *name = "?";
    switch (sig) {
        case SIGSEGV: name = "SIGSEGV"; break;
        case SIGBUS:  name = "SIGBUS";  break;
        case SIGABRT: name = "SIGABRT"; break;
        case SIGILL:  name = "SIGILL";  break;
        case SIGFPE:  name = "SIGFPE";  break;
        case SIGTRAP: name = "SIGTRAP"; break;
    }
    char hdr[160];
    int n = snprintf(hdr, sizeof(hdr),
        "\n[iosauto] ===== FATAL signal %d (%s) — backtrace: =====\n", sig, name);
    if (n > 0) write(STDERR_FILENO, hdr, (size_t)n);

    void *bt[64];
    int frames = backtrace(bt, 64);
    backtrace_symbols_fd(bt, frames, STDERR_FILENO);   // ghi thẳng ra fd (an toàn trong handler)

    const char *tail = "[iosauto] ===== hết backtrace, thoát để launchd restart =====\n";
    write(STDERR_FILENO, tail, strlen(tail));

    // Khôi phục hành vi mặc định + re-raise → tiến trình chết thật → launchd (KeepAlive) restart.
    signal(sig, SIG_DFL);
    raise(sig);
}

static void on_exit_log(void) {
    log_msg("iosautod: THOÁT êm (atexit) — KHÔNG phải bị kill cứng");
}

void crashlog_install(void) {
    int sigs[] = { SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE, SIGTRAP };
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = sig_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_NODEFER | SA_RESETHAND;   // không chặn lồng, tự reset về default sau lần đầu
    for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++)
        sigaction(sigs[i], &sa, NULL);
    atexit(on_exit_log);
    log_msg("crashlog: đã cài signal handler + atexit");
}

void iosauto_mem_log(const char *tag) {
    unsigned long long freeMB = 0, rssMB = 0;

    // RAM trống hệ thống (free + inactive coi như còn dùng được).
    vm_size_t ps = 0;
    if (host_page_size(mach_host_self(), &ps) != KERN_SUCCESS || ps == 0) ps = 16384;
    vm_statistics64_data_t vm;
    mach_msg_type_number_t c = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &c) == KERN_SUCCESS)
        freeMB = ((unsigned long long)(vm.free_count + vm.inactive_count) * (unsigned long long)ps) >> 20;

    // RSS của chính daemon.
    struct task_basic_info ti;
    mach_msg_type_number_t tc = TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)&ti, &tc) == KERN_SUCCESS)
        rssMB = (unsigned long long)ti.resident_size >> 20;

    log_msg("MEM[%s]: free~%lluMB daemonRSS~%lluMB", tag ? tag : "", freeMB, rssMB);
}
