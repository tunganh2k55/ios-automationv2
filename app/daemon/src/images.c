#include "images.h"
#include "log.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>

#define IMAGES_DIR "/var/jb/usr/local/iosauto/images"

void images_init(void) {
    // mkdir -p cấp cuối (các cấp trên /usr/local/iosauto do .deb tạo).
    if (mkdir(IMAGES_DIR, 0755) != 0 && errno != EEXIST)
        log_msg("images: mkdir %s lỗi: %s", IMAGES_DIR, strerror(errno));
}

int images_valid_name(const char *name) {
    if (!name || !*name) return 0;
    size_t n = strlen(name);
    if (n > 80) return 0;
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
    snprintf(out, cap, "%s/%s", IMAGES_DIR, name);
}

static size_t json_str(char *out, size_t cap, size_t o, const char *s) {
    for (; *s && o + 2 < cap; s++) {
        unsigned char c = (unsigned char)*s;
        if (c == '"' || c == '\\') { out[o++] = '\\'; out[o++] = c; }
        else if (c >= 0x20) out[o++] = c;
    }
    return o;
}

void images_list_json(char *out, size_t cap) {
    size_t o = 0;
    out[o++] = '[';
    DIR *d = opendir(IMAGES_DIR);
    if (d) {
        struct dirent *e;
        int first = 1;
        while ((e = readdir(d)) != NULL) {
            if (e->d_name[0] == '.') continue;
            if (!images_valid_name(e->d_name)) continue;
            char path[512]; path_for(e->d_name, path, sizeof(path));
            struct stat st;
            if (stat(path, &st) != 0 || !S_ISREG(st.st_mode)) continue;
            if (o + 160 + strlen(e->d_name) * 2 >= cap) break;
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

// ---- base64 ----
static int b64val(int c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;   // '=', xuống dòng, khoảng trắng… → bỏ qua
}
static long b64_decode(const char *in, size_t inlen, unsigned char **out) {
    unsigned char *buf = malloc(inlen / 4 * 3 + 4);
    if (!buf) return -1;
    size_t o = 0; int quad[4], qi = 0;
    for (size_t i = 0; i < inlen; i++) {
        int v = b64val((unsigned char)in[i]);
        if (v < 0) continue;
        quad[qi++] = v;
        if (qi == 4) {
            buf[o++] = (unsigned char)((quad[0] << 2) | (quad[1] >> 4));
            buf[o++] = (unsigned char)(((quad[1] & 0xF) << 4) | (quad[2] >> 2));
            buf[o++] = (unsigned char)(((quad[2] & 3) << 6) | quad[3]);
            qi = 0;
        }
    }
    if (qi >= 2) {   // phần dư (padding '=' đã bị bỏ)
        buf[o++] = (unsigned char)((quad[0] << 2) | (quad[1] >> 4));
        if (qi >= 3) buf[o++] = (unsigned char)(((quad[1] & 0xF) << 4) | (quad[2] >> 2));
    }
    *out = buf;
    return (long)o;
}
static const char B64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
static char *b64_encode(const unsigned char *in, size_t len, size_t *outlen) {
    size_t ol = ((len + 2) / 3) * 4;
    char *o = malloc(ol + 1);
    if (!o) return NULL;
    size_t j = 0;
    for (size_t i = 0; i < len; i += 3) {
        unsigned v = (unsigned)in[i] << 16;
        if (i + 1 < len) v |= (unsigned)in[i + 1] << 8;
        if (i + 2 < len) v |= (unsigned)in[i + 2];
        o[j++] = B64[(v >> 18) & 63];
        o[j++] = B64[(v >> 12) & 63];
        o[j++] = (i + 1 < len) ? B64[(v >> 6) & 63] : '=';
        o[j++] = (i + 2 < len) ? B64[v & 63] : '=';
    }
    o[j] = '\0';
    if (outlen) *outlen = j;
    return o;
}

int images_save_b64(const char *name, const char *b64, size_t b64len) {
    if (!images_valid_name(name)) return -1;
    unsigned char *data = NULL;
    long n = b64_decode(b64, b64len, &data);
    if (n <= 0 || !data) { free(data); return -1; }
    char path[512]; path_for(name, path, sizeof(path));
    FILE *f = fopen(path, "wb");
    if (!f) { free(data); log_msg("images: ghi %s lỗi: %s", path, strerror(errno)); return -1; }
    size_t wr = fwrite(data, 1, (size_t)n, f);
    fclose(f); free(data);
    log_msg("images: lưu %s (%ld byte)", name, (long)wr);
    return (wr == (size_t)n) ? 0 : -1;
}

char *images_read_b64(const char *name, size_t *outlen) {
    if (!images_valid_name(name)) return NULL;
    char path[512]; path_for(name, path, sizeof(path));
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    if (sz < 0 || sz > 8 * 1024 * 1024) { fclose(f); return NULL; }
    unsigned char *raw = malloc((size_t)sz);
    if (!raw) { fclose(f); return NULL; }
    size_t rd = fread(raw, 1, (size_t)sz, f);
    fclose(f);
    char *b64 = b64_encode(raw, rd, outlen);
    free(raw);
    return b64;
}

int images_delete(const char *name) {
    if (!images_valid_name(name)) return -1;
    char path[512]; path_for(name, path, sizeof(path));
    if (unlink(path) != 0) return -1;
    log_msg("images: xoá %s", name);
    return 0;
}
