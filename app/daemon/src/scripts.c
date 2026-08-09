#include "scripts.h"
#include "log.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>

#define SCRIPTS_DIR "/var/jb/usr/local/iosauto/scripts"

void scripts_init(void) {
    // mkdir -p (chỉ cần 1 cấp cuối; các cấp trên do .deb tạo).
    if (mkdir(SCRIPTS_DIR, 0755) != 0 && errno != EEXIST)
        log_msg("scripts: mkdir %s lỗi: %s", SCRIPTS_DIR, strerror(errno));
}

int scripts_valid_name(const char *name) {
    if (!name || !*name) return 0;
    size_t n = strlen(name);
    if (n > 64) return 0;
    if (name[0] == '.') return 0;                 // không ẩn / không ".."
    if (strstr(name, "..")) return 0;
    for (size_t i = 0; i < n; i++) {
        char c = name[i];
        int ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                 (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-';
        if (!ok) return 0;
    }
    return 1;
}

static void path_for(const char *name, char *out, size_t cap) {
    snprintf(out, cap, "%s/%s", SCRIPTS_DIR, name);
}

// Nối JSON-escaped string vào buffer (theo con trỏ offset). Trả offset mới.
static size_t json_str(char *out, size_t cap, size_t o, const char *s) {
    for (; *s && o + 2 < cap; s++) {
        unsigned char c = (unsigned char)*s;
        if (c == '"' || c == '\\') { out[o++] = '\\'; out[o++] = c; }
        else if (c == '\n') { if (o + 2 < cap) { out[o++] = '\\'; out[o++] = 'n'; } }
        else if (c == '\t') { if (o + 2 < cap) { out[o++] = '\\'; out[o++] = 't'; } }
        else if (c >= 0x20) out[o++] = c;
    }
    return o;
}

void scripts_list_json(char *out, size_t cap) {
    size_t o = 0;
    out[o++] = '[';
    DIR *d = opendir(SCRIPTS_DIR);
    if (d) {
        struct dirent *e;
        int first = 1;
        while ((e = readdir(d)) != NULL) {
            if (e->d_name[0] == '.') continue;
            if (!scripts_valid_name(e->d_name)) continue;
            char path[512]; path_for(e->d_name, path, sizeof(path));
            struct stat st;
            if (stat(path, &st) != 0 || !S_ISREG(st.st_mode)) continue;
            if (o + 128 + strlen(e->d_name) * 2 >= cap) break;
            if (!first) out[o++] = ',';
            first = 0;
            o += (size_t)snprintf(out + o, cap - o, "{\"name\":\"");
            o = json_str(out, cap, o, e->d_name);
            o += (size_t)snprintf(out + o, cap - o, "\",\"size\":%lld,\"mtime\":%ld}",
                                  (long long)st.st_size, (long)st.st_mtime);
        }
        closedir(d);
    }
    if (o + 2 < cap) out[o++] = ']';
    out[o] = '\0';
}

long scripts_read(const char *name, char *out, size_t cap) {
    if (!scripts_valid_name(name)) return -1;
    char path[512]; path_for(name, path, sizeof(path));
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    size_t rd = fread(out, 1, cap - 1, f);
    fclose(f);
    out[rd] = '\0';
    return (long)rd;
}

int scripts_save(const char *name, const char *content, size_t len) {
    if (!scripts_valid_name(name)) return -1;
    char path[512]; path_for(name, path, sizeof(path));
    FILE *f = fopen(path, "wb");
    if (!f) { log_msg("scripts: ghi %s lỗi: %s", path, strerror(errno)); return -1; }
    size_t wr = content && len ? fwrite(content, 1, len, f) : 0;
    fclose(f);
    log_msg("scripts: lưu %s (%zu byte)", name, wr);
    return (wr == len) ? 0 : -1;
}

int scripts_delete(const char *name) {
    if (!scripts_valid_name(name)) return -1;
    char path[512]; path_for(name, path, sizeof(path));
    if (unlink(path) != 0) return -1;
    log_msg("scripts: xoá %s", name);
    return 0;
}
