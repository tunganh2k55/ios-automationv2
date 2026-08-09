#include "log.h"
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <time.h>
#include <pthread.h>

#define LOG_LINES 400
#define LOG_LINE_MAX 256

static char g_lines[LOG_LINES][LOG_LINE_MAX];
static int g_head = 0;   // vị trí ghi kế tiếp
static int g_count = 0;  // số dòng hiện có
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;

void log_init(void) {
    pthread_mutex_lock(&g_mu);
    g_head = 0;
    g_count = 0;
    pthread_mutex_unlock(&g_mu);
}

void log_msg(const char *fmt, ...) {
    char body[LOG_LINE_MAX];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(body, sizeof(body), fmt, ap);
    va_end(ap);

    time_t t = time(NULL);
    struct tm tm;
    localtime_r(&t, &tm);

    pthread_mutex_lock(&g_mu);
    snprintf(g_lines[g_head], LOG_LINE_MAX, "%02d:%02d:%02d %s",
             tm.tm_hour, tm.tm_min, tm.tm_sec, body);
    g_head = (g_head + 1) % LOG_LINES;
    if (g_count < LOG_LINES) g_count++;
    pthread_mutex_unlock(&g_mu);

    fprintf(stderr, "[iosauto] %s\n", body);
}

// Escape tối thiểu cho JSON string (", \, control).
static size_t json_escape(const char *s, char *out, size_t cap) {
    size_t o = 0;
    for (; *s && o + 2 < cap; s++) {
        unsigned char c = (unsigned char)*s;
        if (c == '"' || c == '\\') { out[o++] = '\\'; out[o++] = c; }
        else if (c == '\n') { out[o++] = '\\'; out[o++] = 'n'; }
        else if (c == '\t') { out[o++] = '\\'; out[o++] = 't'; }
        else if (c < 0x20) { /* bỏ ký tự điều khiển khác */ }
        else out[o++] = c;
    }
    out[o] = '\0';
    return o;
}

size_t log_json(char *out, size_t out_len) {
    if (out_len < 3) { if (out_len) out[0] = '\0'; return 0; }
    size_t o = 0;
    out[o++] = '[';

    pthread_mutex_lock(&g_mu);
    int start = (g_count < LOG_LINES) ? 0 : g_head;
    for (int i = 0; i < g_count; i++) {
        int idx = (start + i) % LOG_LINES;
        char esc[LOG_LINE_MAX * 2];
        json_escape(g_lines[idx], esc, sizeof(esc));
        size_t need = strlen(esc) + 4;
        if (o + need >= out_len) break;
        if (i) out[o++] = ',';
        out[o++] = '"';
        memcpy(out + o, esc, strlen(esc));
        o += strlen(esc);
        out[o++] = '"';
    }
    pthread_mutex_unlock(&g_mu);

    if (o + 1 < out_len) out[o++] = ']';
    out[o] = '\0';
    return o;
}
